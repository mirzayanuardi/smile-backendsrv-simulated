-- =============================================================================
-- SMILE — Migrasi skema untuk arsitektur ESP32 -> Server Ingest -> Supabase
-- Versi : v7 (pasangan firmware SMILE v7)
--
-- Isi:
--   1. Kolom baru di sensor_raw_readings (timestamp mentah, segmen jam, flags)
--   2. Backfill baris lama sebagai 'legacy'
--   3. Kunci idempotensi + index time-series
--   4. Tabel clock_events (laporan sinkron jam dari node)
--   5. Tabel ingest_rejects (baris yang ditolak server, untuk audit)
--   6. Kolom token & last_seen_at di nodes
--   7. Fungsi koreksi waktu (dipakai server saat ingest DAN saat event datang)
--   8. Role khusus server ingest (least privilege) + RLS policy
--   9. (DIKOMENTARI) Cabut insert anon setelah semua node pindah ke v7
--
-- Jalankan sekali di Supabase SQL Editor. Aman dijalankan ulang (idempotent),
-- kecuali bagian role: ganti password dulu.
--
-- Catatan ukuran tabel: kalau sensor_raw_readings sudah >1 juta baris, jalankan
-- UPDATE backfill secara bertahap dan buat index dengan CREATE INDEX CONCURRENTLY
-- di luar transaksi. Untuk ukuran riset saat ini, versi di bawah sudah cukup.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Kolom baru di sensor_raw_readings
-- -----------------------------------------------------------------------------
-- reading_timestamp       : waktu SETELAH koreksi (dipakai analisis & ML)
-- reading_timestamp_raw   : waktu apa adanya dari RTC node (tidak pernah diubah)
-- clock_segment           : ID segmen jam (8 hex) dari node
-- uptime_s                : uptime node saat baris dicatat (detik)
-- device_flags            : bitmask dari node (lihat dokumentasi di bawah)
-- time_status             : status kepercayaan waktu
-- ingested_at             : kapan baris diterima server
alter table public.sensor_raw_readings
  add column if not exists reading_timestamp_raw timestamptz,
  add column if not exists clock_segment text,
  add column if not exists uptime_s bigint,
  add column if not exists device_flags integer,
  add column if not exists time_status text,
  add column if not exists ingested_at timestamptz not null default now();

-- device_flags (bitmask dari firmware v7):
--   1  = TIME_UNVERIFIED  segmen jam belum pernah diverifikasi NTP/server
--   2  = RTC_JUMP         RTC terdeteksi melompat tepat di baris ini
--   4  = SOIL_FAIL        minimal satu register Modbus gagal dibaca
--   8  = SHT_FAIL         SHT31 gagal / NaN
--   16 = RAIN_FAIL        sensor hujan tidak siap
--   32 = RTC_READ_FAIL    RTC gagal dibaca, waktu dari jam cadangan ESP32
comment on column public.sensor_raw_readings.device_flags is
  'Bitmask firmware: 1 time_unverified, 2 rtc_jump, 4 soil_fail, 8 sht_fail, 16 rain_fail, 32 rtc_read_fail';
comment on column public.sensor_raw_readings.reading_timestamp_raw is
  'Timestamp mentah dari RTC node, tidak pernah diubah. reading_timestamp = hasil koreksi.';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'sensor_raw_readings_time_status_check'
  ) then
    alter table public.sensor_raw_readings
      add constraint sensor_raw_readings_time_status_check
      check (time_status in ('verified', 'corrected_constant', 'corrected_linear', 'unverified', 'legacy'));
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 2. Backfill baris lama (dari firmware v6 dan sebelumnya)
-- -----------------------------------------------------------------------------
-- clock_segment dibiarkan NULL untuk baris legacy. Di unique index, NULL dianggap
-- berbeda satu sama lain, jadi duplikat lama tidak membuat index gagal dibuat.
update public.sensor_raw_readings
   set reading_timestamp_raw = reading_timestamp,
       time_status = 'legacy'
 where time_status is null;

-- -----------------------------------------------------------------------------
-- 3. Kunci idempotensi + index
-- -----------------------------------------------------------------------------
-- Identitas sebuah baris = (node, segmen jam, timestamp mentah).
-- Ketiganya tidak pernah berubah walau reading_timestamp dikoreksi belakangan.
create unique index if not exists sensor_raw_readings_identity_uq
  on public.sensor_raw_readings (node_id, clock_segment, reading_timestamp_raw);

-- Query time-series (dashboard, feature engineering ML)
create index if not exists sensor_raw_readings_node_ts_idx
  on public.sensor_raw_readings (node_id, reading_timestamp);
create index if not exists sensor_raw_readings_plot_ts_idx
  on public.sensor_raw_readings (plot_id, reading_timestamp);

-- -----------------------------------------------------------------------------
-- 4. clock_events — laporan sinkron jam dari node
-- -----------------------------------------------------------------------------
-- Satu baris = satu segmen jam yang DITUTUP oleh sinkron waktu.
--   rtc_before     : waktu RTC tepat sebelum dikoreksi
--   ref_time       : waktu referensi (NTP / server) pada momen yang sama
--   delta_s        : ref_time - rtc_before (detik). Koreksi = menambah delta.
--   start_verified : segmen dimulai dalam keadaan terverifikasi?
--                    false -> koreksi konstan, true -> koreksi linear (drift)
--   segment_start  : waktu RTC saat segmen dimulai (untuk koreksi linear)
create table if not exists public.clock_events (
  id bigint generated always as identity primary key,
  node_id uuid not null references public.nodes (id),
  clock_segment text not null,
  rtc_before timestamptz not null,
  ref_time timestamptz not null,
  delta_s integer not null,
  start_verified boolean not null,
  segment_start timestamptz,
  ref_source text not null check (ref_source in ('ntp', 'server')),
  received_at timestamptz not null default now(),
  constraint clock_events_node_segment_uq unique (node_id, clock_segment)
);

-- -----------------------------------------------------------------------------
-- 5. ingest_rejects — baris yang ditolak server
-- -----------------------------------------------------------------------------
create table if not exists public.ingest_rejects (
  id bigint generated always as identity primary key,
  node_id uuid references public.nodes (id),
  endpoint text not null,
  line_no integer,
  raw_line text,
  reason text not null,
  received_at timestamptz not null default now()
);

create index if not exists ingest_rejects_node_received_idx
  on public.ingest_rejects (node_id, received_at);

-- -----------------------------------------------------------------------------
-- 6. nodes: token per-node + last_seen_at yang bertipe benar
-- -----------------------------------------------------------------------------
-- api_token_hash : SHA-256 (hex) dari token node. Token asli TIDAK disimpan.
-- last_seen_at   : pengganti last_seen (text). Kolom lama dibiarkan supaya
--                  aplikasi yang sudah menulis ke sana tidak rusak.
alter table public.nodes
  add column if not exists api_token_hash text,
  add column if not exists last_seen_at timestamptz;

-- -----------------------------------------------------------------------------
-- 7. Fungsi koreksi waktu
-- -----------------------------------------------------------------------------
-- Satu sumber kebenaran untuk rumus koreksi. Dipakai server di dua tempat:
--   (a) saat ingest baris yang segmennya sudah punya clock_event
--   (b) saat clock_event datang belakangan -> UPDATE baris segmen itu
--
-- Segmen mulai TIDAK terverifikasi -> t_benar = t_raw + delta
-- Segmen mulai terverifikasi       -> t_benar = t_raw + delta * (t_raw - t0)/(t1 - t0)
--   t0 = segment_start, t1 = rtc_before, rasio dibatasi 0..1
create or replace function public.smile_corrected_ts(
  ts_raw timestamptz,
  delta_s integer,
  start_verified boolean,
  seg_start timestamptz,
  rtc_before timestamptz
) returns timestamptz
language sql
immutable
as $$
  select case
    when ts_raw is null then null
    when delta_s is null then ts_raw
    when not start_verified then ts_raw + make_interval(secs => delta_s::double precision)
    when seg_start is null or rtc_before is null or rtc_before <= seg_start
      then ts_raw + make_interval(secs => delta_s::double precision)
    else ts_raw + make_interval(secs => (
      delta_s::double precision * greatest(0::double precision, least(1::double precision,
        extract(epoch from (ts_raw - seg_start))::double precision
        / extract(epoch from (rtc_before - seg_start))::double precision
      ))
    ))
  end
$$;

create or replace function public.smile_time_status(
  delta_s integer,
  start_verified boolean,
  device_flags integer
) returns text
language sql
immutable
as $$
  select case
    when delta_s is null then
      case when (coalesce(device_flags, 0) & 1) = 1 then 'unverified' else 'verified' end
    when not start_verified then 'corrected_constant'
    when delta_s = 0 then 'verified'
    else 'corrected_linear'
  end
$$;

-- -----------------------------------------------------------------------------
-- 8. Role khusus server ingest (least privilege)
-- -----------------------------------------------------------------------------
-- GANTI password sebelum menjalankan. Simpan di .env server, bukan di repo.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'smile_ingest') then
    create role smile_ingest login password '4lw4y55m1l3';
  end if;
end $$;

alter role smile_ingest set statement_timeout = '30s';

grant usage on schema public to smile_ingest;
grant select, insert, update on public.sensor_raw_readings to smile_ingest;
grant select, insert on public.clock_events to smile_ingest;
grant insert on public.ingest_rejects to smile_ingest;
grant select (id, plot_id, api_token_hash) on public.nodes to smile_ingest;
grant update (last_seen_at, firmware_version) on public.nodes to smile_ingest;
-- Tidak perlu grant sequence: kolom id memakai GENERATED ALWAYS AS IDENTITY,
-- dan Postgres tidak meminta hak USAGE sequence untuk insert ke kolom identity.
-- (Versi sebelumnya menulis grant ke sequence_raw_readings_id_seq dan gagal
-- di database yang tabelnya pernah di-rename, karena nama sequence ikut nama lama.)
grant execute on function public.smile_corrected_ts(timestamptz, integer, boolean, timestamptz, timestamptz) to smile_ingest;
grant execute on function public.smile_time_status(integer, boolean, integer) to smile_ingest;

-- RLS: tabel baru dikunci untuk anon/authenticated, hanya smile_ingest yang menulis.
alter table public.clock_events enable row level security;
alter table public.ingest_rejects enable row level security;

drop policy if exists clock_events_ingest_all on public.clock_events;
create policy clock_events_ingest_all on public.clock_events
  for all to smile_ingest using (true) with check (true);

drop policy if exists ingest_rejects_ingest_insert on public.ingest_rejects;
create policy ingest_rejects_ingest_insert on public.ingest_rejects
  for insert to smile_ingest with check (true);

-- Kalau RLS aktif di sensor_raw_readings / nodes, smile_ingest butuh policy juga.
-- Policy di bawah tidak berpengaruh apa-apa kalau RLS di tabel itu nonaktif.
drop policy if exists sensor_raw_readings_ingest_all on public.sensor_raw_readings;
create policy sensor_raw_readings_ingest_all on public.sensor_raw_readings
  for all to smile_ingest using (true) with check (true);

drop policy if exists nodes_ingest_read on public.nodes;
create policy nodes_ingest_read on public.nodes
  for select to smile_ingest using (true);

drop policy if exists nodes_ingest_touch on public.nodes;
create policy nodes_ingest_touch on public.nodes
  for update to smile_ingest using (true) with check (true);

commit;

-- -----------------------------------------------------------------------------
-- 9. SETELAH semua node memakai firmware v7: cabut hak insert langsung dari anon
-- -----------------------------------------------------------------------------
-- Jangan jalankan sebelum firmware v6 berhenti dipakai, karena v6 masih
-- menulis langsung ke PostgREST dengan publishable key.
--
-- Lihat dulu policy yang ada:
--   select policyname, roles, cmd from pg_policies
--   where schemaname = 'public' and tablename = 'sensor_raw_readings';
--
-- Lalu:
--   revoke insert on public.sensor_raw_readings from anon;
--   drop policy if exists "<nama policy insert anon>" on public.sensor_raw_readings;

-- -----------------------------------------------------------------------------
-- Catatan untuk calibrated_sensor_raw_readings (TIDAK diubah di migrasi ini)
-- -----------------------------------------------------------------------------
-- Tabel itu punya reading_timestamp DEFAULT now(). Kalau pipeline kalibrasi
-- tidak menyalin reading_timestamp dari tabel raw secara eksplisit, waktunya
-- akan jadi waktu proses kalibrasi. Pertimbangkan menambah
--   raw_reading_id bigint references public.sensor_raw_readings (id)
-- supaya koreksi waktu di tabel raw bisa diteruskan ke tabel terkalibrasi.
