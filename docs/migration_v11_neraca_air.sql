-- =============================================================================
-- SMILE migrasi v11 — Neraca air FAO-56 (Layer 1, tanpa ML)
-- Dijalankan setelah v10. Aman dijalankan ulang (idempoten). Tidak menghapus data.
--
-- Isi:
--   1. plot_soil_water_params      parameter tanah per plot (berversi)
--   2. plot_water_params_current   view: parameter aktif + TAW, RAW, θ pemicu
--   3. sensor_calibrations         koefisien kalibrasi sensor per node (berversi)
--   4. fungsi kalibrasi            smile_calibrate(), smile_raw_for_calibrated()
--   5. node_actuator_config        + stop_moisture_raw, thresholds_auto
--   6. smile_refresh_node_thresholds()  hitung ambang mentah untuk ESP
--   7. water_balance_ledger        buku besar neraca air per jam
--   8. irrigation_predictions      + kolom Layer 1, model_id boleh NULL
--   9. weather_forecasts           + forecast_eto_mm
--  10. RLS dan grant
--  11. Nilai awal Latosol Darmaga
-- =============================================================================
begin;

-- -----------------------------------------------------------------------------
-- 1. Parameter tanah per plot. Berversi: JANGAN di-update, selalu insert baris
--    baru dengan valid_from baru. Riwayat neraca air menunjuk ke versi yang dipakai.
-- -----------------------------------------------------------------------------
create table if not exists public.plot_soil_water_params (
  id             uuid primary key default gen_random_uuid(),
  plot_id        uuid not null references public.plots(id) on delete cascade,
  theta_fc_pct   double precision not null,          -- kapasitas lapang, % volume (terkalibrasi)
  theta_pwp_pct  double precision not null,          -- titik layu permanen, % volume
  p_frac         double precision not null default 0.40,  -- fraksi TAW yang boleh habis (kopi: FAO-56 Tabel 22)
  zr_mm          double precision not null,          -- kedalaman zona akar efektif, mm
  kc             double precision not null default 1.0,   -- koefisien tanaman kopi
  source         text not null,                      -- asal angka: literatur / lab
  notes          text,
  valid_from     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  constraint pswp_theta_range check (theta_pwp_pct > 0 and theta_fc_pct < 100 and theta_pwp_pct < theta_fc_pct),
  constraint pswp_p_range     check (p_frac > 0 and p_frac < 1),
  constraint pswp_zr_range    check (zr_mm between 50 and 3000),
  constraint pswp_kc_range    check (kc > 0 and kc <= 2)
);
create index if not exists pswp_plot_valid_idx
  on public.plot_soil_water_params (plot_id, valid_from desc);

comment on table public.plot_soil_water_params is
  'Parameter neraca air FAO-56 per plot. Berversi lewat valid_from; jangan di-update, insert baris baru.';

-- -----------------------------------------------------------------------------
-- 2. View parameter aktif. Satu-satunya tempat rumus TAW/RAW/θ pemicu ditulis.
--    Server dan app MEMBACA dari sini, tidak menghitung ulang sendiri.
-- -----------------------------------------------------------------------------
create or replace view public.plot_water_params_current
with (security_invoker = on) as
select distinct on (p.plot_id)
  p.id as params_id,
  p.plot_id,
  p.theta_fc_pct,
  p.theta_pwp_pct,
  p.p_frac,
  p.zr_mm,
  p.kc,
  p.source,
  p.valid_from,
  (p.theta_fc_pct - p.theta_pwp_pct) / 100.0 * p.zr_mm                 as taw_mm,
  p.p_frac * (p.theta_fc_pct - p.theta_pwp_pct) / 100.0 * p.zr_mm      as raw_mm,
  p.theta_fc_pct - p.p_frac * (p.theta_fc_pct - p.theta_pwp_pct)       as theta_trigger_pct
from public.plot_soil_water_params p
where p.valid_from <= now()
order by p.plot_id, p.valid_from desc;

-- -----------------------------------------------------------------------------
-- 3. Kalibrasi sensor per node. Polinomial: terkalibrasi = c0 + c1·x + c2·x² (+ c3·x³),
--    x = bacaan mentah sensor. Berlaku hanya di rentang [raw_min, raw_max] data kalibrasi.
-- -----------------------------------------------------------------------------
create table if not exists public.sensor_calibrations (
  id          uuid primary key default gen_random_uuid(),
  node_id     uuid not null references public.nodes(id) on delete cascade,
  parameter   text not null check (parameter in ('soil_moisture','soil_temperature','soil_ec','soil_ph')),
  coeffs      double precision[] not null check (array_length(coeffs, 1) between 2 and 4),
  raw_min     double precision not null,
  raw_max     double precision not null,
  r2          double precision check (r2 is null or (r2 >= 0 and r2 <= 1)),
  n_points    integer check (n_points is null or n_points >= 2),
  source      text not null,
  notes       text,
  valid_from  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  constraint sc_raw_range check (raw_max > raw_min)
);
create index if not exists sc_node_param_valid_idx
  on public.sensor_calibrations (node_id, parameter, valid_from desc);

-- -----------------------------------------------------------------------------
-- 4. Fungsi kalibrasi
-- -----------------------------------------------------------------------------
create or replace function public.smile_poly(p_coeffs double precision[], p_x double precision)
returns double precision language sql immutable parallel safe as $$
  select sum(c * power(p_x, i - 1))
  from unnest(p_coeffs) with ordinality as t(c, i)
$$;

-- Bacaan mentah → terkalibrasi. Mengembalikan NULL kalau belum ada kalibrasi
-- (pemanggil yang memutuskan perlakuannya; jangan diam-diam pakai identitas).
create or replace function public.smile_calibrate(
  p_node uuid, p_param text, p_raw double precision, p_at timestamptz default now())
returns double precision language sql stable set search_path = public as $$
  select public.smile_poly(c.coeffs, p_raw)
  from public.sensor_calibrations c
  where c.node_id = p_node and c.parameter = p_param and c.valid_from <= p_at
  order by c.valid_from desc
  limit 1
$$;

-- Kebalikan: nilai terkalibrasi target → bacaan mentah yang setara (bisection).
-- Asumsi: polinomial monoton di [raw_min, raw_max]. NULL kalau belum ada kalibrasi,
-- polinomial tidak monoton, atau target di luar rentang yang pernah dikalibrasi.
create or replace function public.smile_raw_for_calibrated(
  p_node uuid, p_param text, p_target double precision)
returns double precision language plpgsql stable set search_path = public as $$
declare
  c  public.sensor_calibrations%rowtype;
  lo double precision; hi double precision; mid double precision;
  flo double precision; fhi double precision; fmid double precision;
  inc boolean; i int; k int;
begin
  if p_target is null then return null; end if;
  select * into c from public.sensor_calibrations
   where node_id = p_node and parameter = p_param and valid_from <= now()
   order by valid_from desc limit 1;
  if not found then return null; end if;

  lo := c.raw_min; hi := c.raw_max;
  flo := public.smile_poly(c.coeffs, lo);
  fhi := public.smile_poly(c.coeffs, hi);
  inc := fhi > flo;

  -- cek monoton secara kasar di 50 titik
  for k in 1..50 loop
    fmid := public.smile_poly(c.coeffs, lo + (hi - lo) * k / 50.0);
    if (inc and fmid < public.smile_poly(c.coeffs, lo + (hi - lo) * (k - 1) / 50.0))
       or (not inc and fmid > public.smile_poly(c.coeffs, lo + (hi - lo) * (k - 1) / 50.0)) then
      return null;
    end if;
  end loop;

  if p_target < least(flo, fhi) or p_target > greatest(flo, fhi) then
    return null;   -- di luar rentang kalibrasi: jangan ekstrapolasi
  end if;

  for i in 1..60 loop
    mid := (lo + hi) / 2;
    fmid := public.smile_poly(c.coeffs, mid);
    if (fmid < p_target) = inc then lo := mid; else hi := mid; end if;
  end loop;
  return (lo + hi) / 2;
end $$;

-- -----------------------------------------------------------------------------
-- 5. Ambang untuk ESP (dalam satuan BACAAN MENTAH sensor)
-- -----------------------------------------------------------------------------
alter table public.node_actuator_config
  add column if not exists stop_moisture_raw double precision,
  add column if not exists thresholds_auto   boolean not null default true;

comment on column public.node_actuator_config.stop_moisture_raw is
  'Rem jenuh: ESP menghentikan IRIGASI bila kelembapan mentah ≥ nilai ini (setara θ_FC). NULL = rem nonaktif.';
comment on column public.node_actuator_config.thresholds_auto is
  'true = fallback_threshold_raw dan stop_moisture_raw dihitung otomatis dari plot_soil_water_params + sensor_calibrations.';

-- -----------------------------------------------------------------------------
-- 6. Hitung ulang ambang mentah satu node. Dipanggil oleh trigger di bawah.
--    Tanpa kalibrasi kelembapan → kedua ambang NULL (fallback & rem nonaktif),
--    sesuai keputusan v8: fallback hanya aktif setelah kalibrasi.
-- -----------------------------------------------------------------------------
create or replace function public.smile_refresh_node_thresholds(p_node uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v public.plot_water_params_current%rowtype;
  fb double precision; st double precision;
begin
  select w.* into v
    from public.nodes n
    join public.plot_water_params_current w on w.plot_id = n.plot_id
   where n.id = p_node;

  if found then
    fb := public.smile_raw_for_calibrated(p_node, 'soil_moisture', v.theta_trigger_pct);
    st := public.smile_raw_for_calibrated(p_node, 'soil_moisture', v.theta_fc_pct);
  end if;

  update public.node_actuator_config
     set fallback_threshold_raw = round(fb::numeric, 1)::double precision,
         stop_moisture_raw      = round(st::numeric, 1)::double precision
   where node_id = p_node
     and thresholds_auto
     and (fallback_threshold_raw is distinct from round(fb::numeric, 1)::double precision
          or stop_moisture_raw  is distinct from round(st::numeric, 1)::double precision);
  -- trigger smile_bump_config_version yang sudah ada menaikkan config_version,
  -- sehingga ESP menerima baris G baru di poll berikutnya.
end $$;

create or replace function public.smile_trg_refresh_from_params()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from public.nodes where plot_id = new.plot_id loop
    perform public.smile_refresh_node_thresholds(r.id);
  end loop;
  return null;
end $$;

create or replace function public.smile_trg_refresh_from_calibration()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.parameter = 'soil_moisture' then
    perform public.smile_refresh_node_thresholds(new.node_id);
  end if;
  return null;
end $$;

create or replace function public.smile_trg_refresh_from_config()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;   -- cegah rekursi
  perform public.smile_refresh_node_thresholds(new.node_id);
  return null;
end $$;

drop trigger if exists trg_pswp_refresh on public.plot_soil_water_params;
create trigger trg_pswp_refresh
  after insert or update on public.plot_soil_water_params
  for each row execute function public.smile_trg_refresh_from_params();

drop trigger if exists trg_sc_refresh on public.sensor_calibrations;
create trigger trg_sc_refresh
  after insert or update on public.sensor_calibrations
  for each row execute function public.smile_trg_refresh_from_calibration();

drop trigger if exists trg_nac_refresh_ins on public.node_actuator_config;
create trigger trg_nac_refresh_ins
  after insert on public.node_actuator_config
  for each row execute function public.smile_trg_refresh_from_config();

drop trigger if exists trg_nac_refresh_auto on public.node_actuator_config;
create trigger trg_nac_refresh_auto
  after update of thresholds_auto on public.node_actuator_config
  for each row when (new.thresholds_auto and not old.thresholds_auto)
  execute function public.smile_trg_refresh_from_config();

-- -----------------------------------------------------------------------------
-- 7. Buku besar neraca air, satu baris per plot per jam.
--    Dr = defisit air zona akar (mm). 0 = kapasitas lapang, TAW = titik layu.
-- -----------------------------------------------------------------------------
create table if not exists public.water_balance_ledger (
  id                 bigint generated always as identity primary key,
  plot_id            uuid not null references public.plots(id) on delete cascade,
  node_id            uuid references public.nodes(id) on delete set null,
  period_start       timestamptz not null,
  period_end         timestamptz not null,
  params_id          uuid references public.plot_soil_water_params(id),
  eto_mm             double precision check (eto_mm is null or eto_mm >= 0),
  eto_source         text not null check (eto_source in ('open_meteo','hargreaves_sht31','none')),
  kc                 double precision,
  etc_mm             double precision not null default 0 check (etc_mm >= 0),
  rain_mm            double precision not null default 0 check (rain_mm >= 0),
  rain_source        text not null check (rain_source in ('sensor','open_meteo','none')),
  irrigation_mm      double precision not null default 0 check (irrigation_mm >= 0),
  dp_mm              double precision not null default 0 check (dp_mm >= 0),  -- perkolasi dalam
  dr_start_mm        double precision not null check (dr_start_mm >= 0),
  dr_model_mm        double precision not null check (dr_model_mm >= 0),      -- setelah fluks, sebelum koreksi sensor
  theta_obs_raw      double precision,
  theta_obs_pct      double precision,                                         -- terkalibrasi
  dr_obs_mm          double precision check (dr_obs_mm is null or dr_obs_mm >= 0),
  dr_end_mm          double precision not null check (dr_end_mm >= 0),        -- nilai yang dipakai
  corrected          boolean not null default false,
  taw_mm             double precision,
  raw_mm             double precision,
  calibration_status text not null check (calibration_status in ('calibrated','uncalibrated')),
  computed_at        timestamptz not null default now(),
  constraint wbl_period_valid check (period_end > period_start),
  constraint wbl_unique_period unique (plot_id, period_end)
);
comment on table public.water_balance_ledger is
  'Neraca air FAO-56 per jam (Layer 1). Ditulis server; 48 jam terakhir dihitung ulang tiap siklus agar data offline yang telat masuk ikut terhitung.';

-- -----------------------------------------------------------------------------
-- 8. irrigation_predictions: kolom Layer 1. Prediksi FAO-56 tidak punya model ML,
--    jadi model_id boleh NULL khusus decision_layer = 'fao56'.
-- -----------------------------------------------------------------------------
alter table public.irrigation_predictions
  add column if not exists decision_layer        text,
  add column if not exists dr_value_fao56        double precision,
  add column if not exists taw_mm                double precision,
  add column if not exists raw_mm                double precision,
  add column if not exists dr_forecast_24h_mm    double precision,
  add column if not exists etc_forecast_24h_mm   double precision,
  add column if not exists rain_forecast_12h_mm  double precision,
  add column if not exists ledger_id             bigint references public.water_balance_ledger(id) on delete set null;

alter table public.irrigation_predictions alter column model_id drop not null;

do $$ begin
  alter table public.irrigation_predictions
    add constraint ip_decision_layer_valid
    check (decision_layer is null or decision_layer in ('fao56','rf','fao56+rf'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.irrigation_predictions
    add constraint ip_model_required_for_ml
    check (model_id is not null or decision_layer = 'fao56');
exception when duplicate_object then null; end $$;

create index if not exists ip_plot_ts_idx
  on public.irrigation_predictions (plot_id, prediction_timestamp desc);

-- -----------------------------------------------------------------------------
-- 9. ETo dari Open-Meteo, ikut disimpan oleh edge function sync-weather-forecast
-- -----------------------------------------------------------------------------
alter table public.weather_forecasts
  add column if not exists forecast_eto_mm double precision;
do $$ begin
  alter table public.weather_forecasts
    add constraint wf_eto_nonneg check (forecast_eto_mm is null or forecast_eto_mm >= 0);
exception when duplicate_object then null; end $$;
create index if not exists wf_plot_valid_issued_idx
  on public.weather_forecasts (plot_id, valid_for_timestamp, forecast_issued_at desc);

-- -----------------------------------------------------------------------------
-- 10. RLS dan grant
-- -----------------------------------------------------------------------------
alter table public.plot_soil_water_params enable row level security;
alter table public.sensor_calibrations    enable row level security;
alter table public.water_balance_ledger   enable row level security;

drop policy if exists pswp_owner_select on public.plot_soil_water_params;
create policy pswp_owner_select on public.plot_soil_water_params for select to authenticated
  using (exists (select 1 from public.plots p where p.id = plot_id and p.user_id = (select auth.uid())));
drop policy if exists pswp_owner_insert on public.plot_soil_water_params;
create policy pswp_owner_insert on public.plot_soil_water_params for insert to authenticated
  with check (exists (select 1 from public.plots p where p.id = plot_id and p.user_id = (select auth.uid())));

drop policy if exists sc_owner_select on public.sensor_calibrations;
create policy sc_owner_select on public.sensor_calibrations for select to authenticated
  using (exists (select 1 from public.nodes n where n.id = node_id and n.user_id = (select auth.uid())));
drop policy if exists sc_owner_insert on public.sensor_calibrations;
create policy sc_owner_insert on public.sensor_calibrations for insert to authenticated
  with check (exists (select 1 from public.nodes n where n.id = node_id and n.user_id = (select auth.uid())));

drop policy if exists wbl_owner_select on public.water_balance_ledger;
create policy wbl_owner_select on public.water_balance_ledger for select to authenticated
  using (exists (select 1 from public.plots p where p.id = plot_id and p.user_id = (select auth.uid())));

grant select, insert on public.plot_soil_water_params to authenticated;
grant select, insert on public.sensor_calibrations    to authenticated;
grant select         on public.water_balance_ledger   to authenticated;
grant select         on public.plot_water_params_current to authenticated;

-- Role server (least privilege). Hanya diberi hak kalau role-nya memang ada.
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'smile_ingest') then
    grant select on public.plot_soil_water_params, public.sensor_calibrations,
                    public.plot_water_params_current to smile_ingest;
    grant select, insert, update, delete on public.water_balance_ledger to smile_ingest;
    grant select on public.weather_forecasts to smile_ingest;
    grant select, insert, update on public.irrigation_predictions to smile_ingest;
    grant execute on function public.smile_calibrate(uuid, text, double precision, timestamptz) to smile_ingest;
    grant execute on function public.smile_raw_for_calibrated(uuid, text, double precision) to smile_ingest;

    execute 'drop policy if exists pswp_ingest_select on public.plot_soil_water_params';
    execute 'create policy pswp_ingest_select on public.plot_soil_water_params for select to smile_ingest using (true)';
    execute 'drop policy if exists sc_ingest_select on public.sensor_calibrations';
    execute 'create policy sc_ingest_select on public.sensor_calibrations for select to smile_ingest using (true)';
    execute 'drop policy if exists wbl_ingest_all on public.water_balance_ledger';
    execute 'create policy wbl_ingest_all on public.water_balance_ledger for all to smile_ingest using (true) with check (true)';
  end if;
end $$;

revoke all on function public.smile_refresh_node_thresholds(uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 11. Nilai awal: Latosol Darmaga, kebun campuran, rata-rata 0–40 cm.
--     Hanya untuk plot yang belum punya parameter. Ganti dengan hasil lab IPB
--     (insert baris baru; jangan update baris ini).
-- -----------------------------------------------------------------------------
insert into public.plot_soil_water_params
  (plot_id, theta_fc_pct, theta_pwp_pct, p_frac, zr_mm, kc, source, notes, created_by)
select p.id, 59.5, 44.5, 0.40, 400, 1.0,
       'literatur_latosol_darmaga',
       'θ_FC pF2,54 & air tersedia: Latosol Darmaga kebun campuran 0–40 cm (FC 60,5/58,5; AW 16,1/14,2 %vol). '
       || 'p=0,40 FAO-56 Tabel 22 (kopi). Zr=400 mm asumsi, revisi bila umur tanaman diketahui. '
       || 'Kc=1,0 Villa Nova et al. 2005.',
       null
from public.plots p
where not exists (select 1 from public.plot_soil_water_params x where x.plot_id = p.id);

-- Segarkan ambang semua node (tetap NULL sampai kalibrasi kelembapan diisi).
do $$ declare r record; begin
  for r in select node_id from public.node_actuator_config loop
    perform public.smile_refresh_node_thresholds(r.node_id);
  end loop;
end $$;

commit;

-- =============================================================================
-- CONTOH (jangan dijalankan apa adanya): mengisi kalibrasi kelembapan hasil lab.
-- Koefisien dari skrip fitting Python: terkalibrasi = c0 + c1·x + c2·x².
-- Setelah insert, fallback_threshold_raw dan stop_moisture_raw terisi otomatis
-- dan config_version naik, jadi ESP menerima ambang baru di poll berikutnya.
--
-- insert into public.sensor_calibrations
--   (node_id, parameter, coeffs, raw_min, raw_max, r2, n_points, source)
-- values ('fe3e0beb-cdd7-43cd-a409-07e474d1518b', 'soil_moisture',
--         array[c0, c1, c2], <raw_min>, <raw_max>, <r2>, 15, 'lab_nature_chem_2026-10');
-- =============================================================================
