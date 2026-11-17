-- Stub minimal skema Supabase SEBELUM migrasi v7 dan v8, hanya untuk pengujian lokal.
-- Kolom dan tipe disalin dari project Supabase (information_schema, 2026-10-08);
-- kolom yang tidak relevan untuk ingest dihilangkan.

create schema if not exists auth;
create table auth.users (
  id uuid primary key default gen_random_uuid()
);
-- Sama dengan Supabase. smile_ingest TIDAK punya USAGE di schema auth.
create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')), '')::uuid
$$;

-- Role bawaan Supabase, supaya RLS diuji dalam kondisi yang mirip.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create table public.plots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id),
  plot_name varchar not null,
  area_m2 double precision,
  location_lat text,
  location_lng text,
  created_at timestamptz not null default now()
);

create type public.node_status as enum ('active', 'retired', 'maintenance');

create table public.nodes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id),
  plot_id uuid not null references public.plots (id),
  firmware_version text,
  last_seen text,
  status public.node_status default 'active',
  created_at timestamptz not null default now(),
  valve_is_on boolean not null default false,
  valve_mode text not null default 'auto' check (valve_mode in ('auto', 'manual')),
  valve_updated_at timestamptz,
  pump_is_on boolean not null default false,
  pump_mode text not null default 'auto' check (pump_mode in ('auto', 'manual')),
  pump_updated_at timestamptz
);

-- Enum, tabel prediksi/rekomendasi, dan tabel aksi persis seperti Supabase
-- sebelum migrasi v8 (katalog, 2026-10-11).
create type public.trigger_type as enum ('rule_engine', 'manual', 'schedule');
create type public.valve_action_status as enum ('open', 'close');
create type public.execution_status as enum ('success', 'failed', 'skipped', 'overridden');
create type public.fertigation_action_type as enum ('auto', 'manual');
create type public.fertigation_recommendation_type as enum ('naikkan', 'normal', 'tunda', 'blokir');

-- Katalog pupuk sebelum migrasi v10 (v10 menambah owner/is_verified/form dan RLS).
create table public.fertilizer_products (
  id uuid primary key default gen_random_uuid(),
  name varchar not null,
  n_pct double precision not null,
  p_pct double precision not null,
  k_pct double precision not null,
  density_g_per_ml double precision not null,
  notes text,
  created_at timestamptz not null default now()
);

create table public.model_registries (
  id uuid primary key default gen_random_uuid()
);

create type public.model_status as enum ('reliable', 'uncertain', 'fallback');
create type public.source_type as enum ('BMKG', 'NASA_POWER', 'ERA5', 'onsite_station', 'open_meteo');

create table public.irrigation_predictions (
  id uuid primary key default gen_random_uuid(),
  plot_id uuid not null references public.plots (id),
  model_id uuid not null references public.model_registries (id),
  prediction_timestamp timestamptz not null,
  predicted_soil_moisture double precision,
  prediction_error_margin double precision,
  status_model public.model_status,
  prediction_dr_value double precision,
  raw_value double precision,
  irrigation_triggered boolean,
  created_at timestamptz not null default now(),
  reason text
);

-- Sama dengan Supabase: RLS aktif, tidak ada policy untuk smile_ingest (lihat schema_pending.sql).
create table public.weather_forecasts (
  id uuid primary key default gen_random_uuid(),
  plot_id uuid references public.plots (id) on update cascade on delete cascade,
  forecast_issued_at timestamptz,
  valid_for_timestamp timestamptz,
  forecast_rainfall_mm double precision,
  forecast_temperature_c double precision,
  forecast_humidity_pct double precision,
  source public.source_type,
  created_at timestamptz not null default now()
);
create unique index weather_forecasts_plot_valid_source_uq
  on public.weather_forecasts (plot_id, valid_for_timestamp, source);
alter table public.weather_forecasts enable row level security;
alter table public.plots enable row level security;

create table public.fertigation_recommendations (
  id uuid primary key default gen_random_uuid(),
  plot_id uuid not null references public.plots (id),
  model_id uuid not null references public.model_registries (id),
  recommendation_timestamp timestamptz not null,
  pump_duration_seconds double precision,
  status public.fertigation_recommendation_type,
  reason text,
  created_at timestamptz not null default now()
);

create table public.irrigation_actions (
  id uuid primary key default gen_random_uuid(),
  plot_id uuid not null references public.plots (id),
  irrigation_prediction_id uuid references public.irrigation_predictions (id),
  action_timestamp timestamptz not null,
  triggered_by public.trigger_type,
  valve_action public.valve_action_status,
  duration_sec bigint,
  estimated_volume_liter double precision,
  execution_status public.execution_status,
  created_at timestamptz not null default now()
);

create table public.fertigation_actions (
  id uuid primary key default gen_random_uuid(),
  recommendation_id uuid references public.fertigation_recommendations (id),
  execution_timestamp timestamptz not null,
  executed_by public.fertigation_action_type,
  actual_volume double precision,
  actual_duration_sec double precision,
  execution_status public.execution_status,
  created_at timestamptz not null default now(),
  plot_id uuid references public.plots (id),
  pump_action text check (pump_action in ('on', 'off'))
);

-- Trigger lama di Supabase (disalin apa adanya): riwayat 'open'/'on' + success
-- ikut menyalakan valve_is_on / pump_is_on semua node aktif di plot itu.
create function public.sync_node_valve_state() returns trigger
language plpgsql security definer as $$
BEGIN
    IF NEW.valve_action IS NOT NULL
       AND COALESCE(NEW.execution_status::text, 'success') = 'success' THEN
        UPDATE public.nodes
        SET valve_is_on = (NEW.valve_action::text = 'open'),
            valve_updated_at = NEW.action_timestamp
        WHERE plot_id = NEW.plot_id
          AND status = 'active'
          AND (valve_updated_at IS NULL OR valve_updated_at <= NEW.action_timestamp);
    END IF;
    RETURN NEW;
END;
$$;
create trigger trg_irrigation_actions_sync_node after insert on public.irrigation_actions
  for each row execute function public.sync_node_valve_state();

create function public.sync_node_pump_state() returns trigger
language plpgsql security definer as $$
BEGIN
    IF NEW.pump_action IS NOT NULL
       AND NEW.plot_id IS NOT NULL
       AND COALESCE(NEW.execution_status::text, 'success') = 'success' THEN
        UPDATE public.nodes
        SET pump_is_on = (NEW.pump_action = 'on'),
            pump_updated_at = NEW.execution_timestamp
        WHERE plot_id = NEW.plot_id
          AND status = 'active'
          AND (pump_updated_at IS NULL OR pump_updated_at <= NEW.execution_timestamp);
    END IF;
    RETURN NEW;
END;
$$;
create trigger trg_fertigation_actions_sync_node after insert on public.fertigation_actions
  for each row execute function public.sync_node_pump_state();

create table public.sensor_raw_readings (
  id bigint generated by default as identity primary key,
  node_id uuid references public.nodes (id),
  plot_id uuid references public.plots (id),
  reading_timestamp timestamptz,
  soil_temperature_c double precision,
  soil_moisture_pct double precision,
  soil_ec_uscm double precision,
  soil_ph real,
  soil_n_mgkg double precision,
  soil_p_mgkg double precision,
  soil_k_mgkg double precision,
  air_temperature_c double precision,
  air_humidity_pct double precision,
  rainfall_mm double precision,
  rainfall_tip_count bigint,
  quality_flag text
);

alter table public.nodes enable row level security;
alter table public.irrigation_actions enable row level security;
alter table public.fertigation_actions enable row level security;
alter table public.irrigation_predictions enable row level security;
alter table public.fertigation_recommendations enable row level security;
-- Di Supabase saat ini RLS sensor_raw_readings NONAKTIF; nodes aktif.

-- Satu baris legacy (firmware v6) untuk memastikan backfill migrasi berjalan.
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000aa');
insert into public.plots (id, user_id, plot_name)
  values ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000aa', 'Plot A');
insert into public.model_registries (id) values ('00000000-0000-0000-0000-0000000000c1');
insert into public.nodes (id, user_id, plot_id)
  values ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000b1'),
         ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000b1');
insert into public.sensor_raw_readings (node_id, plot_id, reading_timestamp, soil_ph)
  values ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-0000000000b1',
          '2026-01-01T00:00:00+07:00', 6.5);

-- Default ACL Supabase: tabel baru (dari migrasi) otomatis memberi SEMUA hak ke anon
-- dan authenticated. Migrasi harus mencabutnya sendiri; test anon menguji itu.
alter default privileges in schema public grant all on tables to anon, authenticated;
