-- =============================================================================
-- SMILE migration v8 — kanal perintah aktuator
-- "Otak di server, rem di ESP, fallback lokal saat offline lama"
--
-- Prasyarat : migrasi v7 sudah jalan (role smile_ingest, clock_events, dst).
-- Sifat     : aditif. Tidak ada kolom/tabel lama yang dihapus atau diganti nama.
--             Aman dijalankan ulang (if not exists / create or replace / guard).
--
-- Istilah kanal (mengikuti nama kolom yang SUDAH ADA di tabel nodes):
--   valve_* = kanal IRIGASI. Fisiknya pompa air + selang (tanpa solenoid).
--   pump_*  = kanal FERTIGASI. Fisiknya pompa peristaltik.
--
-- Aliran data:
--   app (mode manual) ──insert──► actuator_commands ◄──insert── server (mode auto)
--   ESP ──GET /v1/commands──► server ──► status 'sent'
--   ESP ──POST /v1/ingest/actuations──► server ──► irrigation_actions / fertigation_actions
--                                               └► actuator_commands (status akhir)
--                                               └► nodes.valve_is_on / pump_is_on
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 0. Enum: tambahkan 'local_fallback' ke tipe enum irrigation_actions.triggered_by
--    (nilai lama: rule_engine, manual, schedule). Nama tipe dicari otomatis.
-- -----------------------------------------------------------------------------
do $$
declare t regtype;
begin
  select a.atttypid::regtype into t
  from pg_attribute a
  where a.attrelid = 'public.irrigation_actions'::regclass and a.attname = 'triggered_by';
  if t is not null and exists (select 1 from pg_type where oid = t::oid and typtype = 'e') then
    execute format('alter type %s add value if not exists %L', t, 'local_fallback');
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 1. Konfigurasi aktuator per node
--    Server mengirim isi tabel ini ke ESP (baris "G"). Batas keras di firmware
--    tetap menang: nilai di sini hanya bisa MEMPERKETAT.
-- -----------------------------------------------------------------------------
create table if not exists public.node_actuator_config (
  node_id               uuid primary key references public.nodes(id) on delete cascade,
  has_irrigation        boolean not null default true,
  has_fertigation       boolean not null default false,
  water_flow_lpm        double precision check (water_flow_lpm > 0),      -- debit pompa air terukur (L/menit)
  dose_flow_ml_per_s    double precision check (dose_flow_ml_per_s > 0),  -- debit pompa peristaltik (mL/detik)
  wetted_area_m2        double precision check (wetted_area_m2 > 0),      -- A untuk konversi mm <-> liter
  max_run_s             integer not null default 600  check (max_run_s between 1 and 600),
  max_water_day_s       integer not null default 1800 check (max_water_day_s between 1 and 1800),
  max_dose_day_s        integer not null default 300  check (max_dose_day_s between 1 and 300),
  min_gap_s             integer not null default 1800 check (min_gap_s >= 900),
  flush_s               integer not null default 30   check (flush_s >= 30),
  fallback_threshold_raw double precision,           -- NULL = fallback nonaktif (isi setelah kalibrasi)
  fallback_run_s        integer not null default 120 check (fallback_run_s between 1 and 600),
  fallback_offline_h    integer not null default 24  check (fallback_offline_h >= 6),
  morning_start_hour    integer not null default 6   check (morning_start_hour between 0 and 23),
  morning_end_hour      integer not null default 9   check (morning_end_hour between 1 and 24),
  config_version        integer not null default 1,
  updated_at            timestamptz not null default now(),
  constraint morning_window_valid check (morning_end_hour > morning_start_hour)
);

comment on table public.node_actuator_config is
  'Konfigurasi aktuator per node. Dikirim ke ESP saat config_version berubah. Firmware tetap memakai batas kerasnya sendiri.';
comment on column public.node_actuator_config.fallback_threshold_raw is
  'Ambang kelembapan tanah dalam satuan BACAAN SENSOR MENTAH (%). NULL = fallback lokal nonaktif.';

create or replace function public.smile_bump_config_version()
returns trigger language plpgsql as $$
begin
  if row(new.*) is distinct from row(old.*) then
    new.config_version := old.config_version + 1;
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists trg_bump_config_version on public.node_actuator_config;
create trigger trg_bump_config_version
  before update on public.node_actuator_config
  for each row execute function public.smile_bump_config_version();

insert into public.node_actuator_config (node_id)
select id from public.nodes
on conflict (node_id) do nothing;

-- -----------------------------------------------------------------------------
-- 2. Antrean perintah aktuator
-- -----------------------------------------------------------------------------
create table if not exists public.actuator_commands (
  id                  uuid primary key default gen_random_uuid(),
  node_id             uuid not null references public.nodes(id),
  plot_id             uuid not null references public.plots(id),
  command             text not null check (command in ('irrigate', 'fertigate', 'stop')),
  water_s             integer,
  dose_s              integer,
  trigger             text not null check (trigger in ('manual', 'rule_engine', 'schedule')),
  irrigation_prediction_id      uuid references public.irrigation_predictions(id),
  fertigation_recommendation_id uuid references public.fertigation_recommendations(id),
  reason              text,
  status              text not null default 'pending' check (status in (
                        'pending',      -- menunggu diambil ESP
                        'sent',         -- sudah dikirim ke ESP
                        'running',      -- ESP melaporkan sedang berjalan
                        'executed',     -- selesai sesuai durasi
                        'stopped',      -- dihentikan perintah stop
                        'interrupted',  -- terputus (listrik/reset/ember habis)
                        'rejected',     -- ditolak rem ESP (lihat result_detail)
                        'expired',      -- tidak sempat diambil / kedaluwarsa
                        'cancelled')),  -- dibatalkan sebelum terkirim
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  expires_at          timestamptz not null default (now() + interval '10 minutes'),
  sent_at             timestamptz,
  started_at          timestamptz,
  finished_at         timestamptz,
  actual_water_s      integer,
  actual_dose_s       integer,
  result_detail       text,
  constraint actuator_command_shape check (
       (command = 'stop'      and water_s is null and dose_s is null)
    or (command = 'irrigate'  and water_s between 1 and 600 and dose_s is null)
    or (command = 'fertigate' and water_s between 33 and 600 and dose_s between 1 and 300
                              and dose_s <= water_s - 32)   -- 2 s pancingan + 30 s bilas
  )
);

create index if not exists idx_actuator_commands_pending
  on public.actuator_commands (node_id, created_at) where status = 'pending';
create index if not exists idx_actuator_commands_node_time
  on public.actuator_commands (node_id, created_at desc);

comment on table public.actuator_commands is
  'Perintah berdurasi untuk ESP. Ditulis app (manual) atau server (rule_engine/schedule). ESP tidak pernah menerima perintah "nyala" tanpa durasi.';

-- Penjaga: mode, kepemilikan node-plot, kedaluwarsa, dan anti tumpuk.
create or replace function public.smile_guard_actuator_command()
returns trigger language plpgsql security definer set search_path = public as $$
declare n record; cfg record;
begin
  select id, plot_id, valve_mode, pump_mode into n from public.nodes where id = new.node_id;
  if not found then raise exception 'node % tidak ada', new.node_id; end if;
  if n.plot_id <> new.plot_id then raise exception 'node % bukan milik plot %', new.node_id, new.plot_id; end if;

  select has_irrigation, has_fertigation into cfg from public.node_actuator_config where node_id = new.node_id;

  if new.command = 'irrigate' and coalesce(cfg.has_irrigation, true) = false then
    raise exception 'node ini tidak punya aktuator irigasi';
  end if;
  if new.command = 'fertigate' and coalesce(cfg.has_fertigation, false) = false then
    raise exception 'node ini tidak punya pompa fertigasi (node_actuator_config.has_fertigation)';
  end if;

  -- Mode: perintah manual hanya saat mode manual; perintah mesin hanya saat mode auto.
  if new.command = 'irrigate' then
    if new.trigger = 'manual' and n.valve_mode <> 'manual' then
      raise exception 'irigasi sedang mode AUTO; ubah ke manual dulu';
    end if;
    if new.trigger <> 'manual' and n.valve_mode <> 'auto' then
      raise exception 'irigasi sedang mode MANUAL; perintah otomatis ditolak';
    end if;
  elsif new.command = 'fertigate' then
    if new.trigger = 'manual' and n.pump_mode <> 'manual' then
      raise exception 'fertigasi sedang mode AUTO; ubah ke manual dulu';
    end if;
    if new.trigger <> 'manual' and n.pump_mode <> 'auto' then
      raise exception 'fertigasi sedang mode MANUAL; perintah otomatis ditolak';
    end if;
  end if;
  -- 'stop' selalu diizinkan.

  -- Anti tumpuk: satu perintah aksi yang belum diambil per node.
  if new.command <> 'stop' and exists (
       select 1 from public.actuator_commands c
       where c.node_id = new.node_id and c.command <> 'stop'
         and c.status in ('pending', 'sent') and c.expires_at > now()) then
    raise exception 'masih ada perintah yang menunggu dijalankan di node ini';
  end if;

  new.status     := 'pending';
  new.created_at := now();
  if new.trigger = 'manual' then new.created_by := auth.uid(); end if;
  if new.expires_at is null or new.expires_at > now() + interval '15 minutes' then
    new.expires_at := now() + interval '10 minutes';
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_actuator_command on public.actuator_commands;
create trigger trg_guard_actuator_command
  before insert on public.actuator_commands
  for each row execute function public.smile_guard_actuator_command();

-- -----------------------------------------------------------------------------
-- 3. Laporan eksekusi dari ESP masuk ke tabel aksi yang sudah ada
-- -----------------------------------------------------------------------------
alter table public.irrigation_actions
  add column if not exists node_id               uuid references public.nodes(id),
  add column if not exists command_id            uuid references public.actuator_commands(id),
  add column if not exists device_event_id       text,
  add column if not exists clock_segment         text,
  add column if not exists action_timestamp_raw  timestamptz,
  add column if not exists detail                text;

create unique index if not exists uq_irrigation_actions_device_event
  on public.irrigation_actions (node_id, device_event_id) where device_event_id is not null;

alter table public.fertigation_actions
  add column if not exists node_id                  uuid references public.nodes(id),
  add column if not exists command_id               uuid references public.actuator_commands(id),
  add column if not exists device_event_id          text,
  add column if not exists clock_segment            text,
  add column if not exists execution_timestamp_raw  timestamptz,
  add column if not exists detail                   text;

create unique index if not exists uq_fertigation_actions_device_event
  on public.fertigation_actions (node_id, device_event_id) where device_event_id is not null;

comment on column public.irrigation_actions.device_event_id is
  'ID event dari ESP (ev_id). Kunci anti-duplikat upload ulang.';
comment on column public.irrigation_actions.duration_sec is
  'Durasi pompa air AKTUAL yang dilaporkan ESP (bukan durasi yang diminta).';

-- -----------------------------------------------------------------------------
-- 4. Penghubung keluaran ML/rule engine -> perintah (dispatcher di server)
-- -----------------------------------------------------------------------------
alter table public.irrigation_predictions
  add column if not exists recommended_irrigation_mm double precision,
  add column if not exists dispatched_command_id     uuid references public.actuator_commands(id),
  add column if not exists dispatch_note             text;

comment on column public.irrigation_predictions.recommended_irrigation_mm is
  'Irigasi yang disarankan rule engine (mm). Server mengubahnya ke detik: (mm x wetted_area_m2) / water_flow_lpm x 60.';

alter table public.fertigation_recommendations
  add column if not exists dispatched_command_id uuid references public.actuator_commands(id),
  add column if not exists dispatch_note         text;

-- -----------------------------------------------------------------------------
-- 5. Dokumentasi semantik kolom nodes yang sudah ada
-- -----------------------------------------------------------------------------
comment on column public.nodes.valve_mode   is 'Mode kanal irigasi (auto/manual). DITULIS APP.';
comment on column public.nodes.pump_mode    is 'Mode kanal fertigasi (auto/manual). DITULIS APP.';
comment on column public.nodes.valve_is_on  is 'Status pompa air yang DILAPORKAN ESP. Ditulis server, app hanya membaca.';
comment on column public.nodes.pump_is_on   is 'Status pompa peristaltik yang DILAPORKAN ESP. Ditulis server, app hanya membaca.';
comment on column public.nodes.valve_updated_at is 'Kapan valve_is_on terakhir berubah menurut laporan ESP.';
comment on column public.nodes.pump_updated_at  is 'Kapan pump_is_on terakhir berubah menurut laporan ESP.';

-- -----------------------------------------------------------------------------
-- 6. Hak akses
-- -----------------------------------------------------------------------------
-- 6a. Role server ingest (dibuat di v7)
grant select, insert, update on public.actuator_commands to smile_ingest;
grant select on public.node_actuator_config to smile_ingest;
grant select, insert, update on public.irrigation_actions to smile_ingest;
grant select, insert, update on public.fertigation_actions to smile_ingest;
grant select on public.irrigation_predictions to smile_ingest;
grant update (dispatched_command_id, dispatch_note) on public.irrigation_predictions to smile_ingest;
grant select on public.fertigation_recommendations to smile_ingest;
grant update (dispatched_command_id, dispatch_note) on public.fertigation_recommendations to smile_ingest;
grant select (valve_mode, pump_mode, valve_is_on, pump_is_on, user_id) on public.nodes to smile_ingest;
grant update (valve_is_on, pump_is_on, valve_updated_at, pump_updated_at) on public.nodes to smile_ingest;

-- 6b. Pengguna aplikasi
revoke all on public.actuator_commands from anon;
revoke all on public.node_actuator_config from anon;
grant select, insert on public.actuator_commands to authenticated;
grant select, update on public.node_actuator_config to authenticated;

-- 6c. RLS tabel baru
alter table public.actuator_commands    enable row level security;
alter table public.node_actuator_config enable row level security;

do $$
begin
  -- actuator_commands: pemilik node boleh membaca dan membuat perintah MANUAL
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'actuator_commands' and policyname = 'owner_select_commands') then
    create policy owner_select_commands on public.actuator_commands for select to authenticated
      using (exists (select 1 from public.nodes n where n.id = node_id and n.user_id = auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'actuator_commands' and policyname = 'owner_insert_manual_commands') then
    create policy owner_insert_manual_commands on public.actuator_commands for insert to authenticated
      with check (trigger = 'manual'
                  and exists (select 1 from public.nodes n where n.id = node_id and n.user_id = auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'actuator_commands' and policyname = 'ingest_all_commands') then
    create policy ingest_all_commands on public.actuator_commands for all to smile_ingest using (true) with check (true);
  end if;

  -- node_actuator_config: pemilik node boleh membaca & mengubah; server membaca
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'node_actuator_config' and policyname = 'owner_rw_config') then
    create policy owner_rw_config on public.node_actuator_config for all to authenticated
      using (exists (select 1 from public.nodes n where n.id = node_id and n.user_id = auth.uid()))
      with check (exists (select 1 from public.nodes n where n.id = node_id and n.user_id = auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'node_actuator_config' and policyname = 'ingest_read_config') then
    create policy ingest_read_config on public.node_actuator_config for select to smile_ingest using (true);
  end if;
end $$;

-- 6d. Kalau RLS aktif di tabel lama, smile_ingest butuh policy juga (tidak berefek bila RLS mati)
do $$
declare tbl text;
begin
  foreach tbl in array array['irrigation_actions', 'fertigation_actions', 'irrigation_predictions',
                             'fertigation_recommendations', 'nodes'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = tbl
                   and policyname = 'ingest_v8_' || tbl) then
      execute format('create policy %I on public.%I for all to smile_ingest using (true) with check (true)',
                     'ingest_v8_' || tbl, tbl);
    end if;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 7. Realtime: app mendengarkan status perintah dan status pompa
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'actuator_commands') then
      alter publication supabase_realtime add table public.actuator_commands;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'nodes') then
      alter publication supabase_realtime add table public.nodes;
    end if;
  end if;
end $$;

commit;

-- =============================================================================
-- SETELAH MIGRASI (isi oleh tim, per node yang punya aktuator)
-- =============================================================================
-- update public.node_actuator_config set
--   water_flow_lpm  = <hasil uji tampung 60 detik, L/menit>,
--   wetted_area_m2  = <luas basah, misal pi * r_tajuk^2>,
--   has_fertigation = true,               -- kalau pompa peristaltik terpasang
--   dose_flow_ml_per_s = <hasil uji peristaltik>
-- where node_id = '<uuid node>';
--
-- Fallback lokal tetap NONAKTIF sampai ambang diisi dari hasil kalibrasi:
-- update public.node_actuator_config set fallback_threshold_raw = <nilai> where node_id = '...';
--
-- OPSIONAL (setelah app versi baru terpasang): cegah app menulis riwayat aksi palsu.
-- revoke insert on public.irrigation_actions, public.fertigation_actions from authenticated;
-- =============================================================================
