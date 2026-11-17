-- =============================================================================
-- SMILE migration v10 — fertigasi tiga fase + pupuk dinamis per petani/node
--
-- Mekanisme yang dikunci:
--   Irigasi   : pompa air saja, selama water_s.
--   Fertigasi : BASAHI (air) -> SUNTIK (air + peristaltik, dose_s) -> BILAS (air).
--               Pupuk disuntikkan ke jalur air lewat T, keluar lewat cincin tetes
--               yang sama dengan air. prewet_s & flush_s diambil dari config node.
--   Dosis     : model merekomendasikan GRAM HARA (N, P2O5, K2O). Durasi pompa
--               dihitung dari larutan AKTIF di tangki node + debit peristaltik.
--
-- Prasyarat: v7, v8, v9. Aman dijalankan ulang. Pasangan firmware: smile-v8.2.
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Config fertigasi tiga fase
-- -----------------------------------------------------------------------------
alter table public.node_actuator_config
  add column if not exists prewet_s integer not null default 30;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'node_actuator_config_prewet_s_check') then
    alter table public.node_actuator_config
      add constraint node_actuator_config_prewet_s_check check (prewet_s between 0 and 300);
  end if;
end $$;

comment on column public.node_actuator_config.prewet_s is
  'Fase BASAHI (detik): pompa air jalan sebelum pupuk disuntik.';
comment on column public.node_actuator_config.flush_s is
  'Fase BILAS (detik) setelah suntik pupuk. Tentukan dengan uji pewarna (waktu sampai penetes terjauh jernih kembali). Minimal 30.';
comment on column public.node_actuator_config.dose_flow_ml_per_s is
  'Debit peristaltik (mL/detik) pada DOSE_DUTY firmware, diukur SAAT POMPA AIR MENYALA (melawan tekanan jalur).';

-- -----------------------------------------------------------------------------
-- 2. Produk pupuk: katalog global (tim) + produk pribadi (petani)
-- -----------------------------------------------------------------------------
alter table public.fertilizer_products
  add column if not exists owner_user_id uuid references auth.users(id) on delete cascade,
  add column if not exists is_verified   boolean not null default false,
  add column if not exists form          text not null default 'solid';

alter table public.fertilizer_products alter column density_g_per_ml drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'fertilizer_products_form_check') then
    alter table public.fertilizer_products
      add constraint fertilizer_products_form_check check (form in ('solid', 'liquid'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fertilizer_products_liquid_density') then
    alter table public.fertilizer_products
      add constraint fertilizer_products_liquid_density check (form <> 'liquid' or density_g_per_ml > 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fertilizer_products_pct_range') then
    alter table public.fertilizer_products
      add constraint fertilizer_products_pct_range check (
        n_pct between 0 and 100 and p_pct between 0 and 100 and k_pct between 0 and 100);
  end if;
end $$;

-- Produk yang sudah ada dibuat tim -> katalog global terverifikasi.
update public.fertilizer_products set is_verified = true
where owner_user_id is null and is_verified = false;

comment on column public.fertilizer_products.n_pct is 'N total (%) sesuai label.';
comment on column public.fertilizer_products.p_pct is 'Fosfor sebagai P2O5 (%) sesuai label.';
comment on column public.fertilizer_products.k_pct is 'Kalium sebagai K2O (%) sesuai label.';
comment on column public.fertilizer_products.owner_user_id is
  'NULL = katalog global (diisi tim). Terisi = produk pribadi petani, hanya terlihat oleh pemiliknya.';

-- Petani tidak bisa membuat produk global atau menandai produknya terverifikasi.
create or replace function public.smile_guard_fertilizer_product()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null then          -- request dari pengguna app (bukan SQL Editor / server)
    new.owner_user_id := auth.uid();
    new.is_verified   := false;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_fertilizer_product on public.fertilizer_products;
create trigger trg_guard_fertilizer_product
  before insert or update on public.fertilizer_products
  for each row execute function public.smile_guard_fertilizer_product();

-- -----------------------------------------------------------------------------
-- 3. Larutan di tangki node (batch) dan isinya
-- -----------------------------------------------------------------------------
create table if not exists public.nutrient_batches (
  id                 uuid primary key default gen_random_uuid(),
  node_id            uuid not null references public.nodes(id) on delete cascade,
  name               text,
  solution_volume_l  double precision not null check (solution_volume_l > 0),
  prepared_at        timestamptz not null default now(),
  measured_ec_uscm   double precision check (measured_ec_uscm >= 0),
  measured_ph        double precision check (measured_ph between 0 and 14),
  notes              text,
  is_active          boolean not null default true,
  deactivated_at     timestamptz,
  created_by         uuid default auth.uid(),
  created_at         timestamptz not null default now()
);

create unique index if not exists uq_nutrient_batches_one_active
  on public.nutrient_batches (node_id) where is_active;

comment on table public.nutrient_batches is
  'Larutan yang sedang/pernah ada di tangki pupuk node. Satu batch aktif per node. Batch baru otomatis menonaktifkan yang lama.';

create or replace function public.smile_activate_nutrient_batch()
returns trigger language plpgsql as $$
begin
  if new.is_active then
    update public.nutrient_batches
       set is_active = false, deactivated_at = now()
     where node_id = new.node_id and is_active and id <> new.id;
    new.deactivated_at := null;
  elsif tg_op = 'UPDATE' and old.is_active and new.deactivated_at is null then
    new.deactivated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists trg_activate_nutrient_batch on public.nutrient_batches;
create trigger trg_activate_nutrient_batch
  before insert or update of is_active on public.nutrient_batches
  for each row execute function public.smile_activate_nutrient_batch();

create table if not exists public.nutrient_batch_items (
  id          uuid primary key default gen_random_uuid(),
  batch_id    uuid not null references public.nutrient_batches(id) on delete cascade,
  product_id  uuid not null references public.fertilizer_products(id),
  amount_g    double precision check (amount_g > 0),    -- untuk pupuk padat
  amount_ml   double precision check (amount_ml > 0),   -- untuk pupuk cair
  constraint nutrient_batch_items_one_amount check (num_nonnulls(amount_g, amount_ml) = 1)
);

create index if not exists idx_nutrient_batch_items_batch on public.nutrient_batch_items (batch_id);

create or replace function public.smile_guard_batch_item()
returns trigger language plpgsql security definer set search_path = public as $$
declare d double precision;
begin
  if new.amount_ml is not null then
    select density_g_per_ml into d from public.fertilizer_products where id = new.product_id;
    if d is null or d <= 0 then
      raise exception 'takaran dalam mL butuh densitas produk (g/mL); isi densitas atau pakai takaran gram';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_batch_item on public.nutrient_batch_items;
create trigger trg_guard_batch_item
  before insert or update on public.nutrient_batch_items
  for each row execute function public.smile_guard_batch_item();

-- Isi tangki secara ATOMIK: batch + semua isinya dalam satu transaksi.
-- p_items: [{"product_id": "...", "amount_g": 20}, {"product_id": "...", "amount_ml": 50}]
create or replace function public.create_nutrient_batch(
  p_node_id uuid, p_solution_volume_l double precision, p_items jsonb,
  p_name text default null, p_measured_ec_uscm double precision default null,
  p_measured_ph double precision default null, p_notes text default null)
returns uuid language plpgsql security invoker set search_path = public as $$
declare b uuid; it jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'larutan harus berisi minimal satu produk';
  end if;
  insert into public.nutrient_batches (node_id, name, solution_volume_l, measured_ec_uscm, measured_ph, notes)
  values (p_node_id, p_name, p_solution_volume_l, p_measured_ec_uscm, p_measured_ph, p_notes)
  returning id into b;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into public.nutrient_batch_items (batch_id, product_id, amount_g, amount_ml)
    values (b, (it->>'product_id')::uuid, (it->>'amount_g')::double precision, (it->>'amount_ml')::double precision);
  end loop;
  return b;
end $$;

-- Konsentrasi hara per batch (g per mL larutan)
create or replace view public.nutrient_batch_concentration
with (security_invoker = true) as
select b.id                as batch_id,
       b.node_id,
       b.is_active,
       b.solution_volume_l,
       coalesce(sum(m.mass_g * p.n_pct / 100), 0) / (b.solution_volume_l * 1000) as n_g_per_ml,
       coalesce(sum(m.mass_g * p.p_pct / 100), 0) / (b.solution_volume_l * 1000) as p2o5_g_per_ml,
       coalesce(sum(m.mass_g * p.k_pct / 100), 0) / (b.solution_volume_l * 1000) as k2o_g_per_ml,
       count(i.id)                                    as item_count,
       coalesce(bool_and(p.is_verified), false)       as all_products_verified,
       b.measured_ec_uscm is not null                 as ec_measured
from public.nutrient_batches b
left join public.nutrient_batch_items i on i.batch_id = b.id
left join public.fertilizer_products p  on p.id = i.product_id
left join lateral (select coalesce(i.amount_g, i.amount_ml * p.density_g_per_ml) as mass_g) m on true
group by b.id;

comment on view public.nutrient_batch_concentration is
  'Konsentrasi N, P2O5, K2O (g/mL) tiap batch. Untuk analisis riset, pakai batch dengan all_products_verified dan ec_measured.';

-- -----------------------------------------------------------------------------
-- 4. Rekomendasi dalam gram hara, dan jejak batch di perintah & aksi
-- -----------------------------------------------------------------------------
alter table public.fertigation_recommendations
  add column if not exists target_n_g        double precision check (target_n_g >= 0),
  add column if not exists target_p2o5_g     double precision check (target_p2o5_g >= 0),
  add column if not exists target_k2o_g      double precision check (target_k2o_g >= 0),
  add column if not exists nutrient_batch_id uuid references public.nutrient_batches(id);

comment on column public.fertigation_recommendations.target_n_g is
  'Target hara per aplikasi (gram N). Model merekomendasikan gram hara, bukan gram produk.';

alter table public.actuator_commands
  add column if not exists nutrient_batch_id uuid references public.nutrient_batches(id);

alter table public.fertigation_actions
  add column if not exists nutrient_batch_id uuid references public.nutrient_batches(id);

comment on column public.fertigation_actions.nutrient_batch_id is
  'Larutan yang benar-benar dipompa. Gram hara terkirim = actual_volume (L) x 1000 x konsentrasi batch.';

-- Durasi pompa dari target gram hara. Dipakai server (dispatcher) dan app (manual).
-- Unsur yang paling cepat terpenuhi menentukan durasi, supaya TIDAK ADA unsur yang melebihi target.
create or replace function public.smile_dose_seconds(
  p_batch_id uuid, p_n_g double precision, p_p2o5_g double precision, p_k2o_g double precision,
  p_flow_ml_per_s double precision)
returns integer language sql stable as $$
  select case
    when p_flow_ml_per_s is null or p_flow_ml_per_s <= 0 then null
    else (select ceil(min(t))::integer from (values
            (case when coalesce(p_n_g, 0)    > 0 and c.n_g_per_ml    > 0 then p_n_g    / c.n_g_per_ml    / p_flow_ml_per_s end),
            (case when coalesce(p_p2o5_g, 0) > 0 and c.p2o5_g_per_ml > 0 then p_p2o5_g / c.p2o5_g_per_ml / p_flow_ml_per_s end),
            (case when coalesce(p_k2o_g, 0)  > 0 and c.k2o_g_per_ml  > 0 then p_k2o_g  / c.k2o_g_per_ml  / p_flow_ml_per_s end)
          ) v(t) where t is not null)
  end
  from public.nutrient_batch_concentration c
  where c.batch_id = p_batch_id;
$$;

comment on function public.smile_dose_seconds is
  'detik = gram_hara / (konsentrasi g/mL x debit mL/s); diambil yang terkecil antar-unsur. NULL kalau tidak bisa dihitung.';

-- Hara yang benar-benar terkirim per aksi fertigasi
create or replace view public.fertigation_delivered
with (security_invoker = true) as
select a.id as fertigation_action_id, a.plot_id, a.node_id, a.execution_timestamp,
       a.nutrient_batch_id, a.actual_volume as solution_l,
       a.actual_volume * 1000 * c.n_g_per_ml    as n_g,
       a.actual_volume * 1000 * c.p2o5_g_per_ml as p2o5_g,
       a.actual_volume * 1000 * c.k2o_g_per_ml  as k2o_g
from public.fertigation_actions a
left join public.nutrient_batch_concentration c on c.batch_id = a.nutrient_batch_id;

-- -----------------------------------------------------------------------------
-- 5. Penjaga perintah: fertigasi wajib punya larutan aktif (isi ulang v8 + tambahan)
-- -----------------------------------------------------------------------------
create or replace function public.smile_guard_actuator_command()
returns trigger language plpgsql security definer set search_path = public as $$
declare n record; cfg record; b uuid;
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
    -- v10: wajib ada larutan aktif; dicatat di perintah supaya jejaknya tidak hilang
    select id into b from public.nutrient_batches where node_id = new.node_id and is_active;
    if b is null then
      raise exception 'belum ada larutan aktif di tangki node ini; isi tangki dulu';
    end if;
    if new.nutrient_batch_id is null then
      new.nutrient_batch_id := b;
    elsif not exists (select 1 from public.nutrient_batches
                      where id = new.nutrient_batch_id and node_id = new.node_id) then
      raise exception 'larutan % bukan milik node ini', new.nutrient_batch_id;
    end if;
  end if;

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

-- -----------------------------------------------------------------------------
-- 6. Hak akses dan RLS
-- -----------------------------------------------------------------------------
alter table public.fertilizer_products  enable row level security;
alter table public.nutrient_batches     enable row level security;
alter table public.nutrient_batch_items enable row level security;

revoke all on public.nutrient_batches, public.nutrient_batch_items from anon;
grant select, insert, update, delete on public.fertilizer_products  to authenticated;
grant select, insert, update, delete on public.nutrient_batches     to authenticated;
grant select, insert, update, delete on public.nutrient_batch_items to authenticated;
grant select on public.nutrient_batch_concentration, public.fertigation_delivered to authenticated;
grant execute on function public.create_nutrient_batch(uuid, double precision, jsonb, text, double precision, double precision, text) to authenticated;
grant execute on function public.smile_dose_seconds(uuid, double precision, double precision, double precision, double precision)
  to authenticated, smile_ingest;

grant select on public.fertilizer_products, public.nutrient_batches, public.nutrient_batch_items,
                public.nutrient_batch_concentration, public.fertigation_delivered to smile_ingest;

do $$
begin
  -- Produk: katalog global terbaca semua pengguna login; produk pribadi hanya pemiliknya
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='fertilizer_products' and policyname='read_global_or_own_products') then
    create policy read_global_or_own_products on public.fertilizer_products for select to authenticated
      using (owner_user_id is null or owner_user_id = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='fertilizer_products' and policyname='write_own_products') then
    create policy write_own_products on public.fertilizer_products for all to authenticated
      using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='fertilizer_products' and policyname='ingest_read_products') then
    create policy ingest_read_products on public.fertilizer_products for select to smile_ingest using (true);
  end if;

  -- Batch & isinya: pemilik node
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='nutrient_batches' and policyname='owner_batches') then
    create policy owner_batches on public.nutrient_batches for all to authenticated
      using (exists (select 1 from public.nodes n where n.id = node_id and n.user_id = auth.uid()))
      with check (exists (select 1 from public.nodes n where n.id = node_id and n.user_id = auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='nutrient_batch_items' and policyname='owner_batch_items') then
    create policy owner_batch_items on public.nutrient_batch_items for all to authenticated
      using (exists (select 1 from public.nutrient_batches b join public.nodes n on n.id = b.node_id
                     where b.id = batch_id and n.user_id = auth.uid()))
      with check (exists (select 1 from public.nutrient_batches b join public.nodes n on n.id = b.node_id
                          where b.id = batch_id and n.user_id = auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='nutrient_batches' and policyname='ingest_read_batches') then
    create policy ingest_read_batches on public.nutrient_batches for select to smile_ingest using (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='nutrient_batch_items' and policyname='ingest_read_batch_items') then
    create policy ingest_read_batch_items on public.nutrient_batch_items for select to smile_ingest using (true);
  end if;
end $$;

commit;

-- =============================================================================
-- CATATAN
-- * RLS di fertilizer_products sekarang AKTIF. Pipeline ML yang membaca tabel ini
--   harus memakai role yang punya akses (service role / smile_ingest), bukan anon key.
-- * Setelah instalasi cincin tetes:
--   update public.node_actuator_config
--     set prewet_s = <detik>, flush_s = <hasil uji pewarna, min 30>,
--         water_flow_lpm = <debit total cincin>, dose_flow_ml_per_s = <debit peristaltik saat pompa air jalan>
--   where node_id = '<uuid node>';
-- =============================================================================
