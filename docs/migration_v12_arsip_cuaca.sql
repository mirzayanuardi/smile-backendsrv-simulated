-- =============================================================================
-- SMILE migrasi v12 — Arsip cuaca untuk ML + fallback ETo + faktor tipping bucket
-- Dijalankan setelah v11. Aman dijalankan ulang (idempoten). Tidak menghapus data.
--
-- Isi:
--   1. weather_forecast_snapshots  arsip prakiraan Open-Meteo apa adanya tiap jam (append-only)
--   2. weather_observed_hourly     cuaca reanalisis Open-Meteo archive per jam (boleh direvisi)
--   3. nodes.rain_mm_per_tip       faktor mm/tip tipping bucket per node
--   4. water_balance_ledger        eto_source + open_meteo_cached, open_meteo_archive
--   5. RLS dan grant (termasuk hak tulis weather_forecasts untuk server, yang
--      sebelumnya diisi edge function sync-weather-forecast)
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Snapshot prakiraan. Satu baris = nilai untuk valid_time sebagaimana terlihat
--    saat fetch issued_at. Tidak pernah di-update (ON CONFLICT DO NOTHING).
-- -----------------------------------------------------------------------------
create table if not exists public.weather_forecast_snapshots (
  id                        bigint generated always as identity primary key,
  plot_id                   uuid not null references public.plots(id) on delete cascade,
  source                    text not null default 'open_meteo',
  model                     text not null default 'best_match',
  issued_at                 timestamptz not null,
  valid_time                timestamptz not null,
  lead_hours                integer not null check (lead_hours between 1 and 48),
  precipitation_mm          double precision check (precipitation_mm is null or precipitation_mm >= 0),
  precipitation_probability double precision check (precipitation_probability is null
                                                    or precipitation_probability between 0 and 100),
  et0_fao_mm                double precision check (et0_fao_mm is null or et0_fao_mm >= 0),
  temperature_2m            double precision,
  relative_humidity_2m      double precision,
  wind_speed_10m            double precision,
  shortwave_radiation       double precision,
  fetched_at                timestamptz not null default now(),
  constraint wfs_lead_matches check (valid_time = issued_at + make_interval(hours => lead_hours)),
  constraint wfs_unique unique (plot_id, source, issued_at, valid_time)
);
create index if not exists wfs_plot_valid_idx on public.weather_forecast_snapshots (plot_id, valid_time);
create index if not exists wfs_fetched_idx    on public.weather_forecast_snapshots (fetched_at desc);

comment on table public.weather_forecast_snapshots is
  'Arsip prakiraan Open-Meteo per jam untuk ML. Append-only: satu set baris per fetch (issued_at).';
comment on column public.weather_forecast_snapshots.issued_at is
  'Waktu fetch dibulatkan ke bawah ke jam penuh (UTC). BUKAN waktu run model: Open-Meteo tidak mengembalikannya.';
comment on column public.weather_forecast_snapshots.model is
  'Model yang DIMINTA (parameter models). Open-Meteo tidak mengembalikan model yang dipakai; best_match = pilihan otomatis.';
comment on column public.weather_forecast_snapshots.valid_time is
  'Stempel jam Open-Meteo (UTC). Nilai akumulasi/rata-rata (hujan, ET0, radiasi) berlaku untuk satu jam SEBELUM stempel.';
comment on column public.weather_forecast_snapshots.wind_speed_10m is 'm/s';
comment on column public.weather_forecast_snapshots.shortwave_radiation is 'W/m², rata-rata satu jam sebelum valid_time';

-- -----------------------------------------------------------------------------
-- 2. Cuaca observasi/reanalisis. ERA5 tertunda ±5 hari dan hari-hari terakhir
--    diisi IFS lalu direvisi, jadi upsert memakai ON CONFLICT DO UPDATE.
-- -----------------------------------------------------------------------------
create table if not exists public.weather_observed_hourly (
  id                   bigint generated always as identity primary key,
  plot_id              uuid not null references public.plots(id) on delete cascade,
  source               text not null default 'open_meteo_archive',
  time                 timestamptz not null,
  precipitation_mm     double precision check (precipitation_mm is null or precipitation_mm >= 0),
  temperature_2m       double precision,
  relative_humidity_2m double precision,
  wind_speed_10m       double precision,
  shortwave_radiation  double precision,
  et0_fao_mm           double precision check (et0_fao_mm is null or et0_fao_mm >= 0),
  updated_at           timestamptz not null default now(),
  constraint woh_unique unique (plot_id, source, time)
);
create index if not exists woh_updated_idx on public.weather_observed_hourly (updated_at desc);

comment on table public.weather_observed_hourly is
  'Cuaca reanalisis Open-Meteo archive per jam (UTC). Nilai hari-hari terakhir bisa direvisi oleh job harian.';
comment on column public.weather_observed_hourly.time is
  'Stempel jam (UTC). Hujan, ET0, radiasi = jumlah/rata-rata satu jam SEBELUM stempel.';
comment on column public.weather_observed_hourly.wind_speed_10m is 'm/s';

-- -----------------------------------------------------------------------------
-- 3. Faktor tipping bucket per node. NULL = nominal 0,28 mm/tip (konstanta firmware).
--    Disimpan di nodes, BUKAN node_actuator_config: trigger smile_bump_config_version
--    di tabel itu akan mengirim ulang baris G ke ESP untuk nilai yang tidak dipakai ESP.
--    rainfall_tip_count mentah tidak diubah; konversi hanya di neraca air.
-- -----------------------------------------------------------------------------
alter table public.nodes add column if not exists rain_mm_per_tip double precision;
do $$ begin
  alter table public.nodes
    add constraint nodes_rain_mm_per_tip_range check (rain_mm_per_tip is null or (rain_mm_per_tip > 0 and rain_mm_per_tip < 1));
exception when duplicate_object then null; end $$;
comment on column public.nodes.rain_mm_per_tip is
  'mm hujan per tip tipping bucket (hasil kalibrasi). NULL = 0,28 (nominal). Dipakai neraca air, bukan firmware.';

-- Kalibrasi berbasis berat air: 0,289 mm/tip. Hanya diisi kalau masih kosong.
update public.nodes set rain_mm_per_tip = 0.289
 where id = 'fe3e0beb-cdd7-43cd-a409-07e474d1518b' and rain_mm_per_tip is null;

-- -----------------------------------------------------------------------------
-- 4. Sumber ETo baru di ledger
-- -----------------------------------------------------------------------------
alter table public.water_balance_ledger drop constraint if exists water_balance_ledger_eto_source_check;
alter table public.water_balance_ledger add constraint water_balance_ledger_eto_source_check
  check (eto_source in ('open_meteo', 'open_meteo_cached', 'open_meteo_archive', 'hargreaves_sht31', 'none'));

-- -----------------------------------------------------------------------------
-- 5. RLS dan grant. Default ACL Supabase memberi anon/authenticated SEMUA hak di
--    tabel baru, jadi dicabut dulu lalu diberi ulang seperlunya.
-- -----------------------------------------------------------------------------
alter table public.weather_forecast_snapshots enable row level security;
alter table public.weather_observed_hourly    enable row level security;

revoke all on public.weather_forecast_snapshots, public.weather_observed_hourly from anon, authenticated;
grant select on public.weather_forecast_snapshots, public.weather_observed_hourly to authenticated;

drop policy if exists wfs_owner_select on public.weather_forecast_snapshots;
create policy wfs_owner_select on public.weather_forecast_snapshots for select to authenticated
  using (exists (select 1 from public.plots p where p.id = plot_id and p.user_id = (select auth.uid())));
drop policy if exists woh_owner_select on public.weather_observed_hourly;
create policy woh_owner_select on public.weather_observed_hourly for select to authenticated
  using (exists (select 1 from public.plots p where p.id = plot_id and p.user_id = (select auth.uid())));

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'smile_ingest') then
    -- Snapshot append-only: tanpa UPDATE/DELETE.
    grant select, insert on public.weather_forecast_snapshots to smile_ingest;
    grant select, insert, update on public.weather_observed_hourly to smile_ingest;
    execute 'drop policy if exists wfs_ingest_select on public.weather_forecast_snapshots';
    execute 'create policy wfs_ingest_select on public.weather_forecast_snapshots for select to smile_ingest using (true)';
    execute 'drop policy if exists wfs_ingest_insert on public.weather_forecast_snapshots';
    execute 'create policy wfs_ingest_insert on public.weather_forecast_snapshots for insert to smile_ingest with check (true)';
    execute 'drop policy if exists woh_ingest_all on public.weather_observed_hourly';
    execute 'create policy woh_ingest_all on public.weather_observed_hourly for all to smile_ingest using (true) with check (true)';

    -- Server kini yang mengisi weather_forecasts (sebelumnya edge function).
    grant select, insert, update on public.weather_forecasts to smile_ingest;
    execute 'drop policy if exists wf_ingest_select on public.weather_forecasts';
    execute 'create policy wf_ingest_select on public.weather_forecasts for select to smile_ingest using (true)';
    execute 'drop policy if exists wf_ingest_insert on public.weather_forecasts';
    execute 'create policy wf_ingest_insert on public.weather_forecasts for insert to smile_ingest with check (true)';
    execute 'drop policy if exists wf_ingest_update on public.weather_forecasts';
    execute 'create policy wf_ingest_update on public.weather_forecasts for update to smile_ingest using (true) with check (true)';

    -- Koordinat plot dan meta node (sebelumnya "hak akses yang belum ada di v11").
    grant select (id, location_lat, location_lng) on public.plots to smile_ingest;
    execute 'drop policy if exists plots_ingest_select on public.plots';
    execute 'create policy plots_ingest_select on public.plots for select to smile_ingest using (true)';
    grant select (status, created_at, rain_mm_per_tip) on public.nodes to smile_ingest;
  end if;
end $$;

commit;
