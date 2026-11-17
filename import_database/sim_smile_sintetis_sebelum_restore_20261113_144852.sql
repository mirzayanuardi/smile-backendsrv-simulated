--
-- PostgreSQL database dump
--

\restrict UhFnfirdUMWJx4x8qEsn40Y2hVKGvSf7gypVyuLCgKOuAF4AYvh5SwxieycCQVU

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA auth;


ALTER SCHEMA auth OWNER TO postgres;

--
-- Name: execution_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.execution_status AS ENUM (
    'success',
    'failed',
    'skipped',
    'overridden'
);


ALTER TYPE public.execution_status OWNER TO postgres;

--
-- Name: fertigation_action_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.fertigation_action_type AS ENUM (
    'auto',
    'manual'
);


ALTER TYPE public.fertigation_action_type OWNER TO postgres;

--
-- Name: fertigation_recommendation_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.fertigation_recommendation_type AS ENUM (
    'naikkan',
    'normal',
    'tunda',
    'blokir'
);


ALTER TYPE public.fertigation_recommendation_type OWNER TO postgres;

--
-- Name: model_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.model_status AS ENUM (
    'reliable',
    'uncertain',
    'fallback'
);


ALTER TYPE public.model_status OWNER TO postgres;

--
-- Name: node_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.node_status AS ENUM (
    'active',
    'retired',
    'maintenance'
);


ALTER TYPE public.node_status OWNER TO postgres;

--
-- Name: source_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.source_type AS ENUM (
    'BMKG',
    'NASA_POWER',
    'ERA5',
    'onsite_station',
    'open_meteo'
);


ALTER TYPE public.source_type OWNER TO postgres;

--
-- Name: trigger_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.trigger_type AS ENUM (
    'rule_engine',
    'manual',
    'schedule',
    'local_fallback'
);


ALTER TYPE public.trigger_type OWNER TO postgres;

--
-- Name: valve_action_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.valve_action_status AS ENUM (
    'open',
    'close'
);


ALTER TYPE public.valve_action_status OWNER TO postgres;

--
-- Name: uid(); Type: FUNCTION; Schema: auth; Owner: postgres
--

CREATE FUNCTION auth.uid() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')), '')::uuid
$$;


ALTER FUNCTION auth.uid() OWNER TO postgres;

--
-- Name: create_nutrient_batch(uuid, double precision, jsonb, text, double precision, double precision, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_nutrient_batch(p_node_id uuid, p_solution_volume_l double precision, p_items jsonb, p_name text DEFAULT NULL::text, p_measured_ec_uscm double precision DEFAULT NULL::double precision, p_measured_ph double precision DEFAULT NULL::double precision, p_notes text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
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


ALTER FUNCTION public.create_nutrient_batch(p_node_id uuid, p_solution_volume_l double precision, p_items jsonb, p_name text, p_measured_ec_uscm double precision, p_measured_ph double precision, p_notes text) OWNER TO postgres;

--
-- Name: smile_activate_nutrient_batch(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_activate_nutrient_batch() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.smile_activate_nutrient_batch() OWNER TO postgres;

--
-- Name: smile_bump_config_version(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_bump_config_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if row(new.*) is distinct from row(old.*) then
    new.config_version := old.config_version + 1;
    new.updated_at := now();
  end if;
  return new;
end $$;


ALTER FUNCTION public.smile_bump_config_version() OWNER TO postgres;

--
-- Name: smile_calibrate(uuid, text, double precision, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_calibrate(p_node uuid, p_param text, p_raw double precision, p_at timestamp with time zone DEFAULT now()) RETURNS double precision
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select public.smile_poly(c.coeffs, p_raw)
  from public.sensor_calibrations c
  where c.node_id = p_node and c.parameter = p_param and c.valid_from <= p_at
  order by c.valid_from desc
  limit 1
$$;


ALTER FUNCTION public.smile_calibrate(p_node uuid, p_param text, p_raw double precision, p_at timestamp with time zone) OWNER TO postgres;

--
-- Name: smile_corrected_ts(timestamp with time zone, integer, boolean, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_corrected_ts(ts_raw timestamp with time zone, delta_s integer, start_verified boolean, seg_start timestamp with time zone, rtc_before timestamp with time zone) RETURNS timestamp with time zone
    LANGUAGE sql IMMUTABLE
    AS $$
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


ALTER FUNCTION public.smile_corrected_ts(ts_raw timestamp with time zone, delta_s integer, start_verified boolean, seg_start timestamp with time zone, rtc_before timestamp with time zone) OWNER TO postgres;

--
-- Name: smile_dose_seconds(uuid, double precision, double precision, double precision, double precision); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_dose_seconds(p_batch_id uuid, p_n_g double precision, p_p2o5_g double precision, p_k2o_g double precision, p_flow_ml_per_s double precision) RETURNS integer
    LANGUAGE sql STABLE
    AS $$
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


ALTER FUNCTION public.smile_dose_seconds(p_batch_id uuid, p_n_g double precision, p_p2o5_g double precision, p_k2o_g double precision, p_flow_ml_per_s double precision) OWNER TO postgres;

--
-- Name: FUNCTION smile_dose_seconds(p_batch_id uuid, p_n_g double precision, p_p2o5_g double precision, p_k2o_g double precision, p_flow_ml_per_s double precision); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.smile_dose_seconds(p_batch_id uuid, p_n_g double precision, p_p2o5_g double precision, p_k2o_g double precision, p_flow_ml_per_s double precision) IS 'detik = gram_hara / (konsentrasi g/mL x debit mL/s); diambil yang terkecil antar-unsur. NULL kalau tidak bisa dihitung.';


--
-- Name: smile_guard_actuator_command(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_guard_actuator_command() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


ALTER FUNCTION public.smile_guard_actuator_command() OWNER TO postgres;

--
-- Name: smile_guard_batch_item(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_guard_batch_item() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


ALTER FUNCTION public.smile_guard_batch_item() OWNER TO postgres;

--
-- Name: smile_guard_fertilizer_product(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_guard_fertilizer_product() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if auth.uid() is not null then          -- request dari pengguna app (bukan SQL Editor / server)
    new.owner_user_id := auth.uid();
    new.is_verified   := false;
  end if;
  return new;
end $$;


ALTER FUNCTION public.smile_guard_fertilizer_product() OWNER TO postgres;

--
-- Name: smile_poly(double precision[], double precision); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_poly(p_coeffs double precision[], p_x double precision) RETURNS double precision
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  select sum(c * power(p_x, i - 1))
  from unnest(p_coeffs) with ordinality as t(c, i)
$$;


ALTER FUNCTION public.smile_poly(p_coeffs double precision[], p_x double precision) OWNER TO postgres;

--
-- Name: smile_raw_for_calibrated(uuid, text, double precision); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_raw_for_calibrated(p_node uuid, p_param text, p_target double precision) RETURNS double precision
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
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


ALTER FUNCTION public.smile_raw_for_calibrated(p_node uuid, p_param text, p_target double precision) OWNER TO postgres;

--
-- Name: smile_refresh_node_thresholds(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_refresh_node_thresholds(p_node uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


ALTER FUNCTION public.smile_refresh_node_thresholds(p_node uuid) OWNER TO postgres;

--
-- Name: smile_time_status(integer, boolean, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_time_status(delta_s integer, start_verified boolean, device_flags integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select case
    when delta_s is null then
      case when (coalesce(device_flags, 0) & 1) = 1 then 'unverified' else 'verified' end
    when not start_verified then 'corrected_constant'
    when delta_s = 0 then 'verified'
    else 'corrected_linear'
  end
$$;


ALTER FUNCTION public.smile_time_status(delta_s integer, start_verified boolean, device_flags integer) OWNER TO postgres;

--
-- Name: smile_trg_refresh_from_calibration(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_trg_refresh_from_calibration() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.parameter = 'soil_moisture' then
    perform public.smile_refresh_node_thresholds(new.node_id);
  end if;
  return null;
end $$;


ALTER FUNCTION public.smile_trg_refresh_from_calibration() OWNER TO postgres;

--
-- Name: smile_trg_refresh_from_config(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_trg_refresh_from_config() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if pg_trigger_depth() > 1 then return null; end if;   -- cegah rekursi
  perform public.smile_refresh_node_thresholds(new.node_id);
  return null;
end $$;


ALTER FUNCTION public.smile_trg_refresh_from_config() OWNER TO postgres;

--
-- Name: smile_trg_refresh_from_params(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smile_trg_refresh_from_params() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare r record;
begin
  for r in select id from public.nodes where plot_id = new.plot_id loop
    perform public.smile_refresh_node_thresholds(r.id);
  end loop;
  return null;
end $$;


ALTER FUNCTION public.smile_trg_refresh_from_params() OWNER TO postgres;

--
-- Name: sync_node_pump_state(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_node_pump_state() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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


ALTER FUNCTION public.sync_node_pump_state() OWNER TO postgres;

--
-- Name: sync_node_valve_state(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_node_valve_state() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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


ALTER FUNCTION public.sync_node_valve_state() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: users; Type: TABLE; Schema: auth; Owner: postgres
--

CREATE TABLE auth.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL
);


ALTER TABLE auth.users OWNER TO postgres;

--
-- Name: actuator_commands; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.actuator_commands (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    node_id uuid NOT NULL,
    plot_id uuid NOT NULL,
    command text NOT NULL,
    water_s integer,
    dose_s integer,
    trigger text NOT NULL,
    irrigation_prediction_id uuid,
    fertigation_recommendation_id uuid,
    reason text,
    status text DEFAULT 'pending'::text NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL,
    sent_at timestamp with time zone,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    actual_water_s integer,
    actual_dose_s integer,
    result_detail text,
    nutrient_batch_id uuid,
    CONSTRAINT actuator_command_shape CHECK ((((command = 'stop'::text) AND (water_s IS NULL) AND (dose_s IS NULL)) OR ((command = 'irrigate'::text) AND ((water_s >= 1) AND (water_s <= 600)) AND (dose_s IS NULL)) OR ((command = 'fertigate'::text) AND ((water_s >= 33) AND (water_s <= 600)) AND ((dose_s >= 1) AND (dose_s <= 300)) AND (dose_s <= (water_s - 32))))),
    CONSTRAINT actuator_commands_command_check CHECK ((command = ANY (ARRAY['irrigate'::text, 'fertigate'::text, 'stop'::text]))),
    CONSTRAINT actuator_commands_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sent'::text, 'running'::text, 'executed'::text, 'stopped'::text, 'interrupted'::text, 'rejected'::text, 'expired'::text, 'cancelled'::text]))),
    CONSTRAINT actuator_commands_trigger_check CHECK ((trigger = ANY (ARRAY['manual'::text, 'rule_engine'::text, 'schedule'::text])))
);


ALTER TABLE public.actuator_commands OWNER TO postgres;

--
-- Name: TABLE actuator_commands; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.actuator_commands IS 'Perintah berdurasi untuk ESP. Ditulis app (manual) atau server (rule_engine/schedule). ESP tidak pernah menerima perintah "nyala" tanpa durasi.';


--
-- Name: clock_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.clock_events (
    id bigint NOT NULL,
    node_id uuid NOT NULL,
    clock_segment text NOT NULL,
    rtc_before timestamp with time zone NOT NULL,
    ref_time timestamp with time zone NOT NULL,
    delta_s integer NOT NULL,
    start_verified boolean NOT NULL,
    segment_start timestamp with time zone,
    ref_source text NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT clock_events_ref_source_check CHECK ((ref_source = ANY (ARRAY['ntp'::text, 'server'::text])))
);


ALTER TABLE public.clock_events OWNER TO postgres;

--
-- Name: clock_events_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.clock_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.clock_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fertigation_actions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.fertigation_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recommendation_id uuid,
    execution_timestamp timestamp with time zone NOT NULL,
    executed_by public.fertigation_action_type,
    actual_volume double precision,
    actual_duration_sec double precision,
    execution_status public.execution_status,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    plot_id uuid,
    pump_action text,
    node_id uuid,
    command_id uuid,
    device_event_id text,
    clock_segment text,
    execution_timestamp_raw timestamp with time zone,
    detail text,
    nutrient_batch_id uuid,
    CONSTRAINT fertigation_actions_pump_action_check CHECK ((pump_action = ANY (ARRAY['on'::text, 'off'::text])))
);


ALTER TABLE public.fertigation_actions OWNER TO postgres;

--
-- Name: COLUMN fertigation_actions.nutrient_batch_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.fertigation_actions.nutrient_batch_id IS 'Larutan yang benar-benar dipompa. Gram hara terkirim = actual_volume (L) x 1000 x konsentrasi batch.';


--
-- Name: nutrient_batch_concentration; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.nutrient_batch_concentration AS
SELECT
    NULL::uuid AS batch_id,
    NULL::uuid AS node_id,
    NULL::boolean AS is_active,
    NULL::double precision AS solution_volume_l,
    NULL::double precision AS n_g_per_ml,
    NULL::double precision AS p2o5_g_per_ml,
    NULL::double precision AS k2o_g_per_ml,
    NULL::bigint AS item_count,
    NULL::boolean AS all_products_verified,
    NULL::boolean AS ec_measured;


ALTER VIEW public.nutrient_batch_concentration OWNER TO postgres;

--
-- Name: VIEW nutrient_batch_concentration; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON VIEW public.nutrient_batch_concentration IS 'Konsentrasi N, P2O5, K2O (g/mL) tiap batch. Untuk analisis riset, pakai batch dengan all_products_verified dan ec_measured.';


--
-- Name: fertigation_delivered; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.fertigation_delivered WITH (security_invoker='true') AS
 SELECT a.id AS fertigation_action_id,
    a.plot_id,
    a.node_id,
    a.execution_timestamp,
    a.nutrient_batch_id,
    a.actual_volume AS solution_l,
    ((a.actual_volume * (1000)::double precision) * c.n_g_per_ml) AS n_g,
    ((a.actual_volume * (1000)::double precision) * c.p2o5_g_per_ml) AS p2o5_g,
    ((a.actual_volume * (1000)::double precision) * c.k2o_g_per_ml) AS k2o_g
   FROM (public.fertigation_actions a
     LEFT JOIN public.nutrient_batch_concentration c ON ((c.batch_id = a.nutrient_batch_id)));


ALTER VIEW public.fertigation_delivered OWNER TO postgres;

--
-- Name: fertigation_recommendations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.fertigation_recommendations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plot_id uuid NOT NULL,
    model_id uuid NOT NULL,
    recommendation_timestamp timestamp with time zone NOT NULL,
    pump_duration_seconds double precision,
    status public.fertigation_recommendation_type,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    dispatched_command_id uuid,
    dispatch_note text,
    target_n_g double precision,
    target_p2o5_g double precision,
    target_k2o_g double precision,
    nutrient_batch_id uuid,
    CONSTRAINT fertigation_recommendations_target_k2o_g_check CHECK ((target_k2o_g >= (0)::double precision)),
    CONSTRAINT fertigation_recommendations_target_n_g_check CHECK ((target_n_g >= (0)::double precision)),
    CONSTRAINT fertigation_recommendations_target_p2o5_g_check CHECK ((target_p2o5_g >= (0)::double precision))
);


ALTER TABLE public.fertigation_recommendations OWNER TO postgres;

--
-- Name: COLUMN fertigation_recommendations.target_n_g; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.fertigation_recommendations.target_n_g IS 'Target hara per aplikasi (gram N). Model merekomendasikan gram hara, bukan gram produk.';


--
-- Name: fertilizer_products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.fertilizer_products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying NOT NULL,
    n_pct double precision NOT NULL,
    p_pct double precision NOT NULL,
    k_pct double precision NOT NULL,
    density_g_per_ml double precision,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    owner_user_id uuid,
    is_verified boolean DEFAULT false NOT NULL,
    form text DEFAULT 'solid'::text NOT NULL,
    CONSTRAINT fertilizer_products_form_check CHECK ((form = ANY (ARRAY['solid'::text, 'liquid'::text]))),
    CONSTRAINT fertilizer_products_liquid_density CHECK (((form <> 'liquid'::text) OR (density_g_per_ml > (0)::double precision))),
    CONSTRAINT fertilizer_products_pct_range CHECK ((((n_pct >= (0)::double precision) AND (n_pct <= (100)::double precision)) AND ((p_pct >= (0)::double precision) AND (p_pct <= (100)::double precision)) AND ((k_pct >= (0)::double precision) AND (k_pct <= (100)::double precision))))
);


ALTER TABLE public.fertilizer_products OWNER TO postgres;

--
-- Name: COLUMN fertilizer_products.n_pct; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.fertilizer_products.n_pct IS 'N total (%) sesuai label.';


--
-- Name: COLUMN fertilizer_products.p_pct; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.fertilizer_products.p_pct IS 'Fosfor sebagai P2O5 (%) sesuai label.';


--
-- Name: COLUMN fertilizer_products.k_pct; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.fertilizer_products.k_pct IS 'Kalium sebagai K2O (%) sesuai label.';


--
-- Name: COLUMN fertilizer_products.owner_user_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.fertilizer_products.owner_user_id IS 'NULL = katalog global (diisi tim). Terisi = produk pribadi petani, hanya terlihat oleh pemiliknya.';


--
-- Name: ingest_rejects; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ingest_rejects (
    id bigint NOT NULL,
    node_id uuid,
    endpoint text NOT NULL,
    line_no integer,
    raw_line text,
    reason text NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.ingest_rejects OWNER TO postgres;

--
-- Name: ingest_rejects_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.ingest_rejects ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ingest_rejects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: irrigation_actions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.irrigation_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plot_id uuid NOT NULL,
    irrigation_prediction_id uuid,
    action_timestamp timestamp with time zone NOT NULL,
    triggered_by public.trigger_type,
    valve_action public.valve_action_status,
    duration_sec bigint,
    estimated_volume_liter double precision,
    execution_status public.execution_status,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    node_id uuid,
    command_id uuid,
    device_event_id text,
    clock_segment text,
    action_timestamp_raw timestamp with time zone,
    detail text
);


ALTER TABLE public.irrigation_actions OWNER TO postgres;

--
-- Name: COLUMN irrigation_actions.duration_sec; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.irrigation_actions.duration_sec IS 'Durasi pompa air AKTUAL yang dilaporkan ESP (bukan durasi yang diminta).';


--
-- Name: COLUMN irrigation_actions.device_event_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.irrigation_actions.device_event_id IS 'ID event dari ESP (ev_id). Kunci anti-duplikat upload ulang.';


--
-- Name: irrigation_predictions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.irrigation_predictions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plot_id uuid NOT NULL,
    model_id uuid,
    prediction_timestamp timestamp with time zone NOT NULL,
    predicted_soil_moisture double precision,
    prediction_error_margin double precision,
    status_model public.model_status,
    prediction_dr_value double precision,
    raw_value double precision,
    irrigation_triggered boolean,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    reason text,
    recommended_irrigation_mm double precision,
    dispatched_command_id uuid,
    dispatch_note text,
    decision_layer text,
    dr_value_fao56 double precision,
    taw_mm double precision,
    raw_mm double precision,
    dr_forecast_24h_mm double precision,
    etc_forecast_24h_mm double precision,
    rain_forecast_12h_mm double precision,
    ledger_id bigint,
    CONSTRAINT ip_decision_layer_valid CHECK (((decision_layer IS NULL) OR (decision_layer = ANY (ARRAY['fao56'::text, 'rf'::text, 'fao56+rf'::text])))),
    CONSTRAINT ip_model_required_for_ml CHECK (((model_id IS NOT NULL) OR (decision_layer = 'fao56'::text)))
);


ALTER TABLE public.irrigation_predictions OWNER TO postgres;

--
-- Name: COLUMN irrigation_predictions.recommended_irrigation_mm; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.irrigation_predictions.recommended_irrigation_mm IS 'Irigasi yang disarankan rule engine (mm). Server mengubahnya ke detik: (mm x wetted_area_m2) / water_flow_lpm x 60.';


--
-- Name: model_registries; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.model_registries (
    id uuid DEFAULT gen_random_uuid() NOT NULL
);


ALTER TABLE public.model_registries OWNER TO postgres;

--
-- Name: node_actuator_config; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.node_actuator_config (
    node_id uuid NOT NULL,
    has_irrigation boolean DEFAULT true NOT NULL,
    has_fertigation boolean DEFAULT false NOT NULL,
    water_flow_lpm double precision,
    dose_flow_ml_per_s double precision,
    wetted_area_m2 double precision,
    max_run_s integer DEFAULT 600 NOT NULL,
    max_water_day_s integer DEFAULT 1800 NOT NULL,
    max_dose_day_s integer DEFAULT 300 NOT NULL,
    min_gap_s integer DEFAULT 1800 NOT NULL,
    flush_s integer DEFAULT 30 NOT NULL,
    fallback_threshold_raw double precision,
    fallback_run_s integer DEFAULT 120 NOT NULL,
    fallback_offline_h integer DEFAULT 24 NOT NULL,
    morning_start_hour integer DEFAULT 6 NOT NULL,
    morning_end_hour integer DEFAULT 9 NOT NULL,
    config_version integer DEFAULT 1 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    prewet_s integer DEFAULT 30 NOT NULL,
    stop_moisture_raw double precision,
    thresholds_auto boolean DEFAULT true NOT NULL,
    CONSTRAINT morning_window_valid CHECK ((morning_end_hour > morning_start_hour)),
    CONSTRAINT node_actuator_config_dose_flow_ml_per_s_check CHECK ((dose_flow_ml_per_s > (0)::double precision)),
    CONSTRAINT node_actuator_config_fallback_offline_h_check CHECK ((fallback_offline_h >= 6)),
    CONSTRAINT node_actuator_config_fallback_run_s_check CHECK (((fallback_run_s >= 1) AND (fallback_run_s <= 600))),
    CONSTRAINT node_actuator_config_flush_s_check CHECK ((flush_s >= 30)),
    CONSTRAINT node_actuator_config_max_dose_day_s_check CHECK (((max_dose_day_s >= 1) AND (max_dose_day_s <= 300))),
    CONSTRAINT node_actuator_config_max_run_s_check CHECK (((max_run_s >= 1) AND (max_run_s <= 600))),
    CONSTRAINT node_actuator_config_max_water_day_s_check CHECK (((max_water_day_s >= 1) AND (max_water_day_s <= 1800))),
    CONSTRAINT node_actuator_config_min_gap_s_check CHECK ((min_gap_s >= 900)),
    CONSTRAINT node_actuator_config_morning_end_hour_check CHECK (((morning_end_hour >= 1) AND (morning_end_hour <= 24))),
    CONSTRAINT node_actuator_config_morning_start_hour_check CHECK (((morning_start_hour >= 0) AND (morning_start_hour <= 23))),
    CONSTRAINT node_actuator_config_prewet_s_check CHECK (((prewet_s >= 0) AND (prewet_s <= 300))),
    CONSTRAINT node_actuator_config_water_flow_lpm_check CHECK ((water_flow_lpm > (0)::double precision)),
    CONSTRAINT node_actuator_config_wetted_area_m2_check CHECK ((wetted_area_m2 > (0)::double precision))
);


ALTER TABLE public.node_actuator_config OWNER TO postgres;

--
-- Name: TABLE node_actuator_config; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.node_actuator_config IS 'Konfigurasi aktuator per node. Dikirim ke ESP saat config_version berubah. Firmware tetap memakai batas kerasnya sendiri.';


--
-- Name: COLUMN node_actuator_config.dose_flow_ml_per_s; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.node_actuator_config.dose_flow_ml_per_s IS 'Debit peristaltik (mL/detik) pada DOSE_DUTY firmware, diukur SAAT POMPA AIR MENYALA (melawan tekanan jalur).';


--
-- Name: COLUMN node_actuator_config.flush_s; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.node_actuator_config.flush_s IS 'Fase BILAS (detik) setelah suntik pupuk. Tentukan dengan uji pewarna (waktu sampai penetes terjauh jernih kembali). Minimal 30.';


--
-- Name: COLUMN node_actuator_config.fallback_threshold_raw; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.node_actuator_config.fallback_threshold_raw IS 'Ambang kelembapan tanah dalam satuan BACAAN SENSOR MENTAH (%). NULL = fallback lokal nonaktif.';


--
-- Name: COLUMN node_actuator_config.prewet_s; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.node_actuator_config.prewet_s IS 'Fase BASAHI (detik): pompa air jalan sebelum pupuk disuntik.';


--
-- Name: COLUMN node_actuator_config.stop_moisture_raw; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.node_actuator_config.stop_moisture_raw IS 'Rem jenuh: ESP menghentikan IRIGASI bila kelembapan mentah ≥ nilai ini (setara θ_FC). NULL = rem nonaktif.';


--
-- Name: COLUMN node_actuator_config.thresholds_auto; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.node_actuator_config.thresholds_auto IS 'true = fallback_threshold_raw dan stop_moisture_raw dihitung otomatis dari plot_soil_water_params + sensor_calibrations.';


--
-- Name: nodes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.nodes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    plot_id uuid NOT NULL,
    firmware_version text,
    last_seen text,
    status public.node_status DEFAULT 'active'::public.node_status,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    valve_is_on boolean DEFAULT false NOT NULL,
    valve_mode text DEFAULT 'auto'::text NOT NULL,
    valve_updated_at timestamp with time zone,
    pump_is_on boolean DEFAULT false NOT NULL,
    pump_mode text DEFAULT 'auto'::text NOT NULL,
    pump_updated_at timestamp with time zone,
    api_token_hash text,
    last_seen_at timestamp with time zone,
    rain_mm_per_tip double precision,
    CONSTRAINT nodes_pump_mode_check CHECK ((pump_mode = ANY (ARRAY['auto'::text, 'manual'::text]))),
    CONSTRAINT nodes_rain_mm_per_tip_range CHECK (((rain_mm_per_tip IS NULL) OR ((rain_mm_per_tip > (0)::double precision) AND (rain_mm_per_tip < (1)::double precision)))),
    CONSTRAINT nodes_valve_mode_check CHECK ((valve_mode = ANY (ARRAY['auto'::text, 'manual'::text])))
);


ALTER TABLE public.nodes OWNER TO postgres;

--
-- Name: COLUMN nodes.valve_is_on; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.nodes.valve_is_on IS 'Status pompa air yang DILAPORKAN ESP. Ditulis server, app hanya membaca.';


--
-- Name: COLUMN nodes.valve_mode; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.nodes.valve_mode IS 'Mode kanal irigasi (auto/manual). DITULIS APP.';


--
-- Name: COLUMN nodes.valve_updated_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.nodes.valve_updated_at IS 'Kapan valve_is_on terakhir berubah menurut laporan ESP.';


--
-- Name: COLUMN nodes.pump_is_on; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.nodes.pump_is_on IS 'Status pompa peristaltik yang DILAPORKAN ESP. Ditulis server, app hanya membaca.';


--
-- Name: COLUMN nodes.pump_mode; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.nodes.pump_mode IS 'Mode kanal fertigasi (auto/manual). DITULIS APP.';


--
-- Name: COLUMN nodes.pump_updated_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.nodes.pump_updated_at IS 'Kapan pump_is_on terakhir berubah menurut laporan ESP.';


--
-- Name: COLUMN nodes.rain_mm_per_tip; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.nodes.rain_mm_per_tip IS 'mm hujan per tip tipping bucket (hasil kalibrasi). NULL = 0,28 (nominal). Dipakai neraca air, bukan firmware.';


--
-- Name: nutrient_batch_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.nutrient_batch_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    batch_id uuid NOT NULL,
    product_id uuid NOT NULL,
    amount_g double precision,
    amount_ml double precision,
    CONSTRAINT nutrient_batch_items_amount_g_check CHECK ((amount_g > (0)::double precision)),
    CONSTRAINT nutrient_batch_items_amount_ml_check CHECK ((amount_ml > (0)::double precision)),
    CONSTRAINT nutrient_batch_items_one_amount CHECK ((num_nonnulls(amount_g, amount_ml) = 1))
);


ALTER TABLE public.nutrient_batch_items OWNER TO postgres;

--
-- Name: nutrient_batches; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.nutrient_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    node_id uuid NOT NULL,
    name text,
    solution_volume_l double precision NOT NULL,
    prepared_at timestamp with time zone DEFAULT now() NOT NULL,
    measured_ec_uscm double precision,
    measured_ph double precision,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    deactivated_at timestamp with time zone,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT nutrient_batches_measured_ec_uscm_check CHECK ((measured_ec_uscm >= (0)::double precision)),
    CONSTRAINT nutrient_batches_measured_ph_check CHECK (((measured_ph >= (0)::double precision) AND (measured_ph <= (14)::double precision))),
    CONSTRAINT nutrient_batches_solution_volume_l_check CHECK ((solution_volume_l > (0)::double precision))
);


ALTER TABLE public.nutrient_batches OWNER TO postgres;

--
-- Name: TABLE nutrient_batches; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.nutrient_batches IS 'Larutan yang sedang/pernah ada di tangki pupuk node. Satu batch aktif per node. Batch baru otomatis menonaktifkan yang lama.';


--
-- Name: plot_soil_water_params; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.plot_soil_water_params (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plot_id uuid NOT NULL,
    theta_fc_pct double precision NOT NULL,
    theta_pwp_pct double precision NOT NULL,
    p_frac double precision DEFAULT 0.40 NOT NULL,
    zr_mm double precision NOT NULL,
    kc double precision DEFAULT 1.0 NOT NULL,
    source text NOT NULL,
    notes text,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pswp_kc_range CHECK (((kc > (0)::double precision) AND (kc <= (2)::double precision))),
    CONSTRAINT pswp_p_range CHECK (((p_frac > (0)::double precision) AND (p_frac < (1)::double precision))),
    CONSTRAINT pswp_theta_range CHECK (((theta_pwp_pct > (0)::double precision) AND (theta_fc_pct < (100)::double precision) AND (theta_pwp_pct < theta_fc_pct))),
    CONSTRAINT pswp_zr_range CHECK (((zr_mm >= (50)::double precision) AND (zr_mm <= (3000)::double precision)))
);


ALTER TABLE public.plot_soil_water_params OWNER TO postgres;

--
-- Name: TABLE plot_soil_water_params; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.plot_soil_water_params IS 'Parameter neraca air FAO-56 per plot. Berversi lewat valid_from; jangan di-update, insert baris baru.';


--
-- Name: plot_water_params_current; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.plot_water_params_current WITH (security_invoker='on') AS
 SELECT DISTINCT ON (plot_id) id AS params_id,
    plot_id,
    theta_fc_pct,
    theta_pwp_pct,
    p_frac,
    zr_mm,
    kc,
    source,
    valid_from,
    (((theta_fc_pct - theta_pwp_pct) / (100.0)::double precision) * zr_mm) AS taw_mm,
    (((p_frac * (theta_fc_pct - theta_pwp_pct)) / (100.0)::double precision) * zr_mm) AS raw_mm,
    (theta_fc_pct - (p_frac * (theta_fc_pct - theta_pwp_pct))) AS theta_trigger_pct
   FROM public.plot_soil_water_params p
  WHERE (valid_from <= now())
  ORDER BY plot_id, valid_from DESC;


ALTER VIEW public.plot_water_params_current OWNER TO postgres;

--
-- Name: plots; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.plots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    plot_name character varying NOT NULL,
    area_m2 double precision,
    location_lat text,
    location_lng text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.plots OWNER TO postgres;

--
-- Name: sensor_calibrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sensor_calibrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    node_id uuid NOT NULL,
    parameter text NOT NULL,
    coeffs double precision[] NOT NULL,
    raw_min double precision NOT NULL,
    raw_max double precision NOT NULL,
    r2 double precision,
    n_points integer,
    source text NOT NULL,
    notes text,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sc_raw_range CHECK ((raw_max > raw_min)),
    CONSTRAINT sensor_calibrations_coeffs_check CHECK (((array_length(coeffs, 1) >= 2) AND (array_length(coeffs, 1) <= 4))),
    CONSTRAINT sensor_calibrations_n_points_check CHECK (((n_points IS NULL) OR (n_points >= 2))),
    CONSTRAINT sensor_calibrations_parameter_check CHECK ((parameter = ANY (ARRAY['soil_moisture'::text, 'soil_temperature'::text, 'soil_ec'::text, 'soil_ph'::text]))),
    CONSTRAINT sensor_calibrations_r2_check CHECK (((r2 IS NULL) OR ((r2 >= (0)::double precision) AND (r2 <= (1)::double precision))))
);


ALTER TABLE public.sensor_calibrations OWNER TO postgres;

--
-- Name: sensor_raw_readings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sensor_raw_readings (
    id bigint NOT NULL,
    node_id uuid,
    plot_id uuid,
    reading_timestamp timestamp with time zone,
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
    quality_flag text,
    reading_timestamp_raw timestamp with time zone,
    clock_segment text,
    uptime_s bigint,
    device_flags integer,
    time_status text,
    ingested_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sensor_raw_readings_time_status_check CHECK ((time_status = ANY (ARRAY['verified'::text, 'corrected_constant'::text, 'corrected_linear'::text, 'unverified'::text, 'legacy'::text])))
);


ALTER TABLE public.sensor_raw_readings OWNER TO postgres;

--
-- Name: COLUMN sensor_raw_readings.reading_timestamp_raw; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sensor_raw_readings.reading_timestamp_raw IS 'Timestamp mentah dari RTC node, tidak pernah diubah. reading_timestamp = hasil koreksi.';


--
-- Name: COLUMN sensor_raw_readings.device_flags; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sensor_raw_readings.device_flags IS 'Bitmask firmware: 1 time_unverified, 2 rtc_jump, 4 soil_fail, 8 sht_fail, 16 rain_fail, 32 rtc_read_fail';


--
-- Name: sensor_raw_readings_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.sensor_raw_readings ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.sensor_raw_readings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: water_balance_ledger; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.water_balance_ledger (
    id bigint NOT NULL,
    plot_id uuid NOT NULL,
    node_id uuid,
    period_start timestamp with time zone NOT NULL,
    period_end timestamp with time zone NOT NULL,
    params_id uuid,
    eto_mm double precision,
    eto_source text NOT NULL,
    kc double precision,
    etc_mm double precision DEFAULT 0 NOT NULL,
    rain_mm double precision DEFAULT 0 NOT NULL,
    rain_source text NOT NULL,
    irrigation_mm double precision DEFAULT 0 NOT NULL,
    dp_mm double precision DEFAULT 0 NOT NULL,
    dr_start_mm double precision NOT NULL,
    dr_model_mm double precision NOT NULL,
    theta_obs_raw double precision,
    theta_obs_pct double precision,
    dr_obs_mm double precision,
    dr_end_mm double precision NOT NULL,
    corrected boolean DEFAULT false NOT NULL,
    taw_mm double precision,
    raw_mm double precision,
    calibration_status text NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT water_balance_ledger_calibration_status_check CHECK ((calibration_status = ANY (ARRAY['calibrated'::text, 'uncalibrated'::text]))),
    CONSTRAINT water_balance_ledger_dp_mm_check CHECK ((dp_mm >= (0)::double precision)),
    CONSTRAINT water_balance_ledger_dr_end_mm_check CHECK ((dr_end_mm >= (0)::double precision)),
    CONSTRAINT water_balance_ledger_dr_model_mm_check CHECK ((dr_model_mm >= (0)::double precision)),
    CONSTRAINT water_balance_ledger_dr_obs_mm_check CHECK (((dr_obs_mm IS NULL) OR (dr_obs_mm >= (0)::double precision))),
    CONSTRAINT water_balance_ledger_dr_start_mm_check CHECK ((dr_start_mm >= (0)::double precision)),
    CONSTRAINT water_balance_ledger_etc_mm_check CHECK ((etc_mm >= (0)::double precision)),
    CONSTRAINT water_balance_ledger_eto_mm_check CHECK (((eto_mm IS NULL) OR (eto_mm >= (0)::double precision))),
    CONSTRAINT water_balance_ledger_eto_source_check CHECK ((eto_source = ANY (ARRAY['open_meteo'::text, 'open_meteo_cached'::text, 'open_meteo_archive'::text, 'hargreaves_sht31'::text, 'none'::text]))),
    CONSTRAINT water_balance_ledger_irrigation_mm_check CHECK ((irrigation_mm >= (0)::double precision)),
    CONSTRAINT water_balance_ledger_rain_mm_check CHECK ((rain_mm >= (0)::double precision)),
    CONSTRAINT water_balance_ledger_rain_source_check CHECK ((rain_source = ANY (ARRAY['sensor'::text, 'open_meteo'::text, 'none'::text]))),
    CONSTRAINT wbl_period_valid CHECK ((period_end > period_start))
);


ALTER TABLE public.water_balance_ledger OWNER TO postgres;

--
-- Name: TABLE water_balance_ledger; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.water_balance_ledger IS 'Neraca air FAO-56 per jam (Layer 1). Ditulis server; 48 jam terakhir dihitung ulang tiap siklus agar data offline yang telat masuk ikut terhitung.';


--
-- Name: water_balance_ledger_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.water_balance_ledger ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.water_balance_ledger_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: weather_forecast_snapshots; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.weather_forecast_snapshots (
    id bigint NOT NULL,
    plot_id uuid NOT NULL,
    source text DEFAULT 'open_meteo'::text NOT NULL,
    model text DEFAULT 'best_match'::text NOT NULL,
    issued_at timestamp with time zone NOT NULL,
    valid_time timestamp with time zone NOT NULL,
    lead_hours integer NOT NULL,
    precipitation_mm double precision,
    precipitation_probability double precision,
    et0_fao_mm double precision,
    temperature_2m double precision,
    relative_humidity_2m double precision,
    wind_speed_10m double precision,
    shortwave_radiation double precision,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT weather_forecast_snapshots_et0_fao_mm_check CHECK (((et0_fao_mm IS NULL) OR (et0_fao_mm >= (0)::double precision))),
    CONSTRAINT weather_forecast_snapshots_lead_hours_check CHECK (((lead_hours >= 1) AND (lead_hours <= 48))),
    CONSTRAINT weather_forecast_snapshots_precipitation_mm_check CHECK (((precipitation_mm IS NULL) OR (precipitation_mm >= (0)::double precision))),
    CONSTRAINT weather_forecast_snapshots_precipitation_probability_check CHECK (((precipitation_probability IS NULL) OR ((precipitation_probability >= (0)::double precision) AND (precipitation_probability <= (100)::double precision)))),
    CONSTRAINT wfs_lead_matches CHECK ((valid_time = (issued_at + make_interval(hours => lead_hours))))
);


ALTER TABLE public.weather_forecast_snapshots OWNER TO postgres;

--
-- Name: TABLE weather_forecast_snapshots; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.weather_forecast_snapshots IS 'Arsip prakiraan Open-Meteo per jam untuk ML. Append-only: satu set baris per fetch (issued_at).';


--
-- Name: COLUMN weather_forecast_snapshots.model; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.weather_forecast_snapshots.model IS 'Model yang DIMINTA (parameter models). Open-Meteo tidak mengembalikan model yang dipakai; best_match = pilihan otomatis.';


--
-- Name: COLUMN weather_forecast_snapshots.issued_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.weather_forecast_snapshots.issued_at IS 'Waktu fetch dibulatkan ke bawah ke jam penuh (UTC). BUKAN waktu run model: Open-Meteo tidak mengembalikannya.';


--
-- Name: COLUMN weather_forecast_snapshots.valid_time; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.weather_forecast_snapshots.valid_time IS 'Stempel jam Open-Meteo (UTC). Nilai akumulasi/rata-rata (hujan, ET0, radiasi) berlaku untuk satu jam SEBELUM stempel.';


--
-- Name: COLUMN weather_forecast_snapshots.wind_speed_10m; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.weather_forecast_snapshots.wind_speed_10m IS 'm/s';


--
-- Name: COLUMN weather_forecast_snapshots.shortwave_radiation; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.weather_forecast_snapshots.shortwave_radiation IS 'W/m², rata-rata satu jam sebelum valid_time';


--
-- Name: weather_forecast_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.weather_forecast_snapshots ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.weather_forecast_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: weather_forecasts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.weather_forecasts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plot_id uuid,
    forecast_issued_at timestamp with time zone,
    valid_for_timestamp timestamp with time zone,
    forecast_rainfall_mm double precision,
    forecast_temperature_c double precision,
    forecast_humidity_pct double precision,
    source public.source_type,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    forecast_eto_mm double precision,
    CONSTRAINT wf_eto_nonneg CHECK (((forecast_eto_mm IS NULL) OR (forecast_eto_mm >= (0)::double precision)))
);


ALTER TABLE public.weather_forecasts OWNER TO postgres;

--
-- Name: weather_observed_hourly; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.weather_observed_hourly (
    id bigint NOT NULL,
    plot_id uuid NOT NULL,
    source text DEFAULT 'open_meteo_archive'::text NOT NULL,
    "time" timestamp with time zone NOT NULL,
    precipitation_mm double precision,
    temperature_2m double precision,
    relative_humidity_2m double precision,
    wind_speed_10m double precision,
    shortwave_radiation double precision,
    et0_fao_mm double precision,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT weather_observed_hourly_et0_fao_mm_check CHECK (((et0_fao_mm IS NULL) OR (et0_fao_mm >= (0)::double precision))),
    CONSTRAINT weather_observed_hourly_precipitation_mm_check CHECK (((precipitation_mm IS NULL) OR (precipitation_mm >= (0)::double precision)))
);


ALTER TABLE public.weather_observed_hourly OWNER TO postgres;

--
-- Name: TABLE weather_observed_hourly; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.weather_observed_hourly IS 'Cuaca reanalisis Open-Meteo archive per jam (UTC). Nilai hari-hari terakhir bisa direvisi oleh job harian.';


--
-- Name: COLUMN weather_observed_hourly."time"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.weather_observed_hourly."time" IS 'Stempel jam (UTC). Hujan, ET0, radiasi = jumlah/rata-rata satu jam SEBELUM stempel.';


--
-- Name: COLUMN weather_observed_hourly.wind_speed_10m; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.weather_observed_hourly.wind_speed_10m IS 'm/s';


--
-- Name: weather_observed_hourly_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.weather_observed_hourly ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.weather_observed_hourly_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: postgres
--

COPY auth.users (id) FROM stdin;
00000000-0000-0000-0000-0000000000aa
\.


--
-- Data for Name: actuator_commands; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.actuator_commands (id, node_id, plot_id, command, water_s, dose_s, trigger, irrigation_prediction_id, fertigation_recommendation_id, reason, status, created_by, created_at, expires_at, sent_at, started_at, finished_at, actual_water_s, actual_dose_s, result_detail, nutrient_batch_id) FROM stdin;
\.


--
-- Data for Name: clock_events; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.clock_events (id, node_id, clock_segment, rtc_before, ref_time, delta_s, start_verified, segment_start, ref_source, received_at) FROM stdin;
1	11111111-1111-1111-1111-111111111111	a1b2c3d4	2026-11-11 14:59:12+00	2026-11-11 15:02:09+00	177	f	2026-11-11 12:28:42+00	ntp	2026-11-11 15:01:57.068281+00
3	11111111-1111-1111-1111-111111111111	b1000001	2026-11-09 17:04:00+00	2026-11-09 17:09:00+00	300	f	2026-11-09 15:03:30+00	ntp	2026-11-11 15:04:05.071998+00
4	11111111-1111-1111-1111-111111111111	b1000002	2026-11-10 17:04:00+00	2026-11-10 17:03:15+00	-45	t	2026-11-10 15:03:30+00	ntp	2026-11-11 15:04:05.189807+00
\.


--
-- Data for Name: fertigation_actions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.fertigation_actions (id, recommendation_id, execution_timestamp, executed_by, actual_volume, actual_duration_sec, execution_status, created_at, plot_id, pump_action, node_id, command_id, device_event_id, clock_segment, execution_timestamp_raw, detail, nutrient_batch_id) FROM stdin;
\.


--
-- Data for Name: fertigation_recommendations; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.fertigation_recommendations (id, plot_id, model_id, recommendation_timestamp, pump_duration_seconds, status, reason, created_at, dispatched_command_id, dispatch_note, target_n_g, target_p2o5_g, target_k2o_g, nutrient_batch_id) FROM stdin;
\.


--
-- Data for Name: fertilizer_products; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.fertilizer_products (id, name, n_pct, p_pct, k_pct, density_g_per_ml, notes, created_at, owner_user_id, is_verified, form) FROM stdin;
\.


--
-- Data for Name: ingest_rejects; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ingest_rejects (id, node_id, endpoint, line_no, raw_line, reason, received_at) FROM stdin;
1	11111111-1111-1111-1111-111111111111	/v1/ingest/readings	3	BARIS-RUSAK,tidak,valid	expected 15 fields, got 3	2026-11-11 15:04:24.642337+00
\.


--
-- Data for Name: irrigation_actions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.irrigation_actions (id, plot_id, irrigation_prediction_id, action_timestamp, triggered_by, valve_action, duration_sec, estimated_volume_liter, execution_status, created_at, node_id, command_id, device_event_id, clock_segment, action_timestamp_raw, detail) FROM stdin;
\.


--
-- Data for Name: irrigation_predictions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.irrigation_predictions (id, plot_id, model_id, prediction_timestamp, predicted_soil_moisture, prediction_error_margin, status_model, prediction_dr_value, raw_value, irrigation_triggered, created_at, reason, recommended_irrigation_mm, dispatched_command_id, dispatch_note, decision_layer, dr_value_fao56, taw_mm, raw_mm, dr_forecast_24h_mm, etc_forecast_24h_mm, rain_forecast_12h_mm, ledger_id) FROM stdin;
6dde2dc5-a7de-4c78-88cb-7ded2c801487	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 15:01:15.846451+00	59	\N	\N	1.9999999999999991	\N	f	2026-11-11 15:01:17.39054+00	below_raw: Dr 3,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	2.9999999999999987	60	24	1.9999999999999991	5.2	0.1	48
1d73f652-a555-4148-8c7f-93e6fbf5af72	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 16:04:59.998898+00	59.5	\N	\N	0	31.85	f	2026-11-11 16:05:01.044847+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	5.19	0	144
3cd504da-87a0-4c72-aff7-e3c77b6570e5	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 17:04:59.999889+00	59.5	\N	\N	0	31.85	f	2026-11-11 17:05:01.117005+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	5.19	0	192
5e475703-49ff-4867-9e86-81eec8c570c5	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 18:05:00.000531+00	59.5	\N	\N	0	31.85	f	2026-11-11 18:05:01.127983+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	5.19	0	240
1032f8c7-b218-404e-8398-9ac022b3c269	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 19:05:00.000583+00	59.5	\N	\N	0	31.85	f	2026-11-11 19:05:01.096458+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	5.19	0	288
41d6ef3c-afeb-48d7-934e-160b4149a464	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 20:04:59.999645+00	59.5	\N	\N	0	31.85	f	2026-11-11 20:05:01.134456+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	5.08	0.7000000000000001	336
393cf69b-0660-4da1-89f0-d9b72a6e01e2	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 21:04:59.999369+00	59.5	\N	\N	0	31.85	f	2026-11-11 21:05:01.045886+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	5.08	5.699999999999999	384
ff4abc30-65c3-4ac6-8ca3-e74684cd6600	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 22:05:00.000354+00	59.5	\N	\N	0	31.85	f	2026-11-11 22:05:01.052646+00	rain_expected: hujan 12 jam 13,3 mm ≥ 10,0 mm; Dr 0,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	5.08	13.299999999999999	432
1c2b3f91-ccc1-4866-9dd0-13944cd3d041	00000000-0000-0000-0000-0000000000b1	\N	2026-11-11 23:04:59.99915+00	59.5	\N	\N	0	31.85	f	2026-11-11 23:05:01.031701+00	rain_expected: hujan 12 jam 13,7 mm ≥ 10,0 mm; Dr 0,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.01	60	24	0	5.07	13.7	480
9c0940a0-18b1-4e2a-a703-7d0979b1f2f6	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 00:05:00.000676+00	59.5	\N	\N	0	31.85	f	2026-11-12 00:05:01.07138+00	rain_expected: hujan 12 jam 14,7 mm ≥ 10,0 mm; Dr 0,1 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.12	60	24	0	5.06	14.7	528
78ab27a8-1351-4b93-ba13-d548b62bfd03	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 01:05:00.000115+00	59.5	\N	\N	0	31.85	f	2026-11-12 01:05:01.052228+00	rain_expected: hujan 12 jam 15,1 mm ≥ 10,0 mm; Dr 0,4 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.41	60	24	0	5.01	15.1	576
0aaa2fd0-632a-436d-aa42-7dfdf4510df8	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 02:05:00.0013+00	59.5	\N	\N	0	31.85	f	2026-11-12 02:05:01.046702+00	rain_expected: hujan 12 jam 10,9 mm ≥ 10,0 mm; Dr 0,9 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.9099999999999999	60	24	0	4.84	10.9	624
ec5b848f-9ffc-456e-9428-3d8d3f051eb0	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 03:04:59.999454+00	59.5	\N	\N	0	31.85	f	2026-11-12 03:05:01.14058+00	rain_expected: hujan 12 jam 11,0 mm ≥ 10,0 mm; Dr 1,4 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	1.41	60	24	0	4.69	11	672
792742da-a24d-4ff6-b86e-5063fee906ef	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 04:04:59.999118+00	59.5	\N	\N	0	31.85	f	2026-11-12 04:05:01.040744+00	rain_expected: hujan 12 jam 10,9 mm ≥ 10,0 mm; Dr 2,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	2.04	60	24	0	4.51	10.9	720
6cccc631-a3aa-41f1-8c7a-f57abd6abddd	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 05:04:59.999848+00	59.5	\N	\N	0	31.85	f	2026-11-12 05:05:01.048957+00	rain_expected: hujan 12 jam 10,6 mm ≥ 10,0 mm; Dr 2,5 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	2.49	60	24	0	4.43	10.6	768
785e9dca-6111-4dd2-bfe4-77cae93b402f	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 06:05:00.000707+00	59.5	\N	\N	0	31.85	f	2026-11-12 06:05:01.032631+00	rain_expected: hujan 12 jam 10,3 mm ≥ 10,0 mm; Dr 2,9 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	2.91	60	24	0	4.32	10.299999999999999	816
084558d3-4294-4834-8d9f-c8ab93a92da0	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 07:04:59.999156+00	59.5	\N	\N	0	31.85	f	2026-11-12 07:05:01.049647+00	rain_expected: hujan 12 jam 10,2 mm ≥ 10,0 mm; Dr 3,5 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	3.45	60	24	0	3.99	10.2	864
b3fd3830-65f2-4412-bc41-0224500beaaa	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 08:05:00.00058+00	59.5	\N	\N	0	31.85	f	2026-11-12 08:05:01.11548+00	below_raw: Dr 0,8 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.8499999999999998	60	24	0	3.57	3.1	912
be1e6b7e-8db9-4021-aa58-95c2169ec5d9	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 09:05:00.001186+00	59.5	\N	\N	0	31.85	f	2026-11-12 09:05:01.061415+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	3.44	2	960
d6f2cad5-b1fd-489d-aea8-b3dac44b4c21	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 10:05:00.000535+00	59.5	\N	\N	0	31.85	f	2026-11-12 10:05:01.041029+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	3.41	0.7999999999999999	1008
64d2eb07-b9a8-4ec0-aac9-6859782a1c76	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 11:05:00.000148+00	59.5	\N	\N	0	31.85	f	2026-11-12 11:05:01.068231+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	3.41	0.1	1056
80693f64-b1e4-40c0-8f4b-e364a60cee32	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 12:04:59.999844+00	59.5	\N	\N	0	31.85	f	2026-11-12 12:05:01.209615+00	below_raw: Dr 0,0 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0	60	24	0	3.41	0	1104
9e8bc756-76ab-498b-bba4-201940e529da	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 13:05:00.001243+00	59.1425	\N	\N	1.4299999999999997	31.85	f	2026-11-12 13:05:01.111945+00	below_raw: Dr 0,2 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.23999999999999957	60	24	1.4299999999999997	3.69	0.1	1152
a6442b34-4c91-4d70-91f9-c641318e4b02	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 14:04:59.999423+00	59.2425	\N	\N	1.0299999999999998	31.85	f	2026-11-12 14:05:01.037314+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	1.0299999999999998	3.69	0	1200
9acdd58a-373a-4241-a66e-b1fbabeab4b9	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 15:05:00.000353+00	59.3175	\N	\N	0.7299999999999995	31.85	f	2026-11-12 15:05:01.231074+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	0.7299999999999995	3.69	0	1248
c82dcc2a-a447-4f9c-916a-4021a9784b29	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 16:05:00.000406+00	59.3675	\N	\N	0.5299999999999998	31.85	f	2026-11-12 16:05:01.132953+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	0.5299999999999998	3.69	0	1296
82df880d-b8f9-4743-b2e6-72415438bdc5	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 17:05:00.001359+00	59.3675	\N	\N	0.5299999999999998	31.85	f	2026-11-12 17:05:01.078626+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	0.5299999999999998	3.69	0.1	1344
c0ad9a69-6079-4b4a-b450-04753b46ca32	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 18:04:59.999997+00	59.3675	\N	\N	0.5299999999999998	31.85	f	2026-11-12 18:05:48.772666+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	0.5299999999999998	3.69	0.2	1392
aa464756-39ad-4ef1-a36a-6adedaca7c40	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 19:05:00.000387+00	59.3675	\N	\N	0.5299999999999998	31.85	f	2026-11-12 19:05:01.070335+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	0.5299999999999998	3.69	0.30000000000000004	1440
8c19074c-9605-41e1-ae87-760cca7540fa	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 20:05:00.000822+00	59.1525	\N	\N	1.3899999999999997	31.85	f	2026-11-12 20:05:01.044834+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	1.3899999999999997	4.05	1.5	1488
7fef1417-381f-40e2-a509-899a47c7a93b	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 21:05:00.000084+00	59.1775	\N	\N	1.2899999999999996	31.85	f	2026-11-12 21:05:01.052105+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	1.2899999999999996	4.05	1.6	1536
e0f12856-facc-4513-8be4-1e1ae093c940	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 22:04:59.999305+00	59.2275	\N	\N	1.0899999999999994	31.85	f	2026-11-12 22:05:00.797938+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.13999999999999957	60	24	1.0899999999999994	4.05	1.6	1584
64a9e73b-f5d1-4920-b90c-e60909ef91b5	00000000-0000-0000-0000-0000000000b1	\N	2026-11-12 23:04:59.999358+00	59.225	\N	\N	1.0999999999999992	31.85	f	2026-11-12 23:05:00.888522+00	below_raw: Dr 0,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.14999999999999958	60	24	1.0999999999999992	4.05	1.6	1632
b89d38f2-8e1b-41dd-bbeb-44ef5de71653	00000000-0000-0000-0000-0000000000b1	\N	2026-11-13 00:04:59.999591+00	59.1975	\N	\N	1.2099999999999995	31.85	f	2026-11-13 00:05:00.767308+00	below_raw: Dr 0,3 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.25999999999999956	60	24	1.2099999999999995	4.05	1.6	1680
cba7d824-f04d-46d4-8efc-868cafd89922	00000000-0000-0000-0000-0000000000b1	\N	2026-11-13 01:05:00.000792+00	59.2825	\N	\N	0.8700000000000001	31.85	f	2026-11-13 01:05:01.055599+00	below_raw: Dr 0,5 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.4799999999999996	60	24	0.8700000000000001	4.49	4.1	1728
3672a159-b3ee-4329-9934-1da76c3f7167	00000000-0000-0000-0000-0000000000b1	\N	2026-11-13 02:05:00.000695+00	59.18	\N	\N	1.2800000000000002	31.85	f	2026-11-13 02:05:00.885712+00	below_raw: Dr 0,9 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	0.9099999999999996	60	24	1.2800000000000002	4.470000000000001	4.1	1776
aca5702a-2844-4658-addb-6f48939a86f9	00000000-0000-0000-0000-0000000000b1	\N	2026-11-13 03:05:00.001269+00	59.0775	\N	\N	1.6899999999999995	31.85	f	2026-11-13 03:05:01.059013+00	below_raw: Dr 1,5 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	1.4699999999999998	60	24	1.6899999999999995	4.42	4.1	1824
854e9827-8761-451a-b4e7-b57c4e931d41	00000000-0000-0000-0000-0000000000b1	\N	2026-11-13 04:04:59.999836+00	58.9575	\N	\N	2.169999999999999	31.85	f	2026-11-13 04:05:48.80345+00	below_raw: Dr 2,1 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	2.1199999999999997	60	24	2.169999999999999	4.35	4.1	1872
f1cff3a2-6789-45fe-b1b6-cf81fcc9a523	00000000-0000-0000-0000-0000000000b1	\N	2026-11-13 05:05:00.000693+00	58.8325	\N	\N	2.67	31.85	f	2026-11-13 05:05:00.764251+00	below_raw: Dr 2,6 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	2.59	60	24	2.67	4.28	3.9	1920
ec4331f2-1b50-4201-ba3b-964056abcf9d	00000000-0000-0000-0000-0000000000b1	\N	2026-11-13 06:04:59.999279+00	58.6825	\N	\N	3.27	31.85	f	2026-11-13 06:05:01.118404+00	below_raw: Dr 1,2 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	1.23	60	24	3.27	4.34	2	1968
ab0c0929-9187-4a35-a3aa-a81eec359b0b	00000000-0000-0000-0000-0000000000b1	\N	2026-11-13 07:04:59.998891+00	59.167500000000004	\N	\N	1.3299999999999983	31.85	f	2026-11-13 07:05:34.617728+00	below_raw: Dr 4,2 mm < RAW 24,0 mm; ETo open_meteo; sensor belum terkalibrasi	\N	\N	\N	fao56	4.1899999999999995	60	24	1.3299999999999983	4.4399999999999995	5.1000000000000005	2016
\.


--
-- Data for Name: model_registries; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.model_registries (id) FROM stdin;
00000000-0000-0000-0000-0000000000c1
\.


--
-- Data for Name: node_actuator_config; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.node_actuator_config (node_id, has_irrigation, has_fertigation, water_flow_lpm, dose_flow_ml_per_s, wetted_area_m2, max_run_s, max_water_day_s, max_dose_day_s, min_gap_s, flush_s, fallback_threshold_raw, fallback_run_s, fallback_offline_h, morning_start_hour, morning_end_hour, config_version, updated_at, prewet_s, stop_moisture_raw, thresholds_auto) FROM stdin;
11111111-1111-1111-1111-111111111111	t	t	1.2	1.5	0.8	600	1800	300	1800	30	\N	120	24	6	9	1	2026-11-11 15:01:13.734612+00	30	\N	t
22222222-2222-2222-2222-222222222222	f	f	\N	\N	\N	600	1800	300	1800	30	\N	120	24	6	9	1	2026-11-11 15:01:13.734612+00	30	\N	t
\.


--
-- Data for Name: nodes; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.nodes (id, user_id, plot_id, firmware_version, last_seen, status, created_at, valve_is_on, valve_mode, valve_updated_at, pump_is_on, pump_mode, pump_updated_at, api_token_hash, last_seen_at, rain_mm_per_tip) FROM stdin;
22222222-2222-2222-2222-222222222222	00000000-0000-0000-0000-0000000000aa	00000000-0000-0000-0000-0000000000b1	\N	\N	active	2026-11-11 15:01:13.388796+00	f	manual	\N	f	manual	\N	4fb6f83407781e1e3bf4f1c83cd708145bbc01b98c0a64f2be9f366b56bc60e7	\N	\N
11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000aa	00000000-0000-0000-0000-0000000000b1	smile-v7.0-sim	\N	active	2026-11-11 15:01:13.388796+00	f	manual	\N	f	manual	\N	9e07a405d1a9dd581cc6a7a6e6cc172ad438b38f43c44413ac62d83b8747f623	2026-11-11 15:04:05.044066+00	\N
\.


--
-- Data for Name: nutrient_batch_items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.nutrient_batch_items (id, batch_id, product_id, amount_g, amount_ml) FROM stdin;
\.


--
-- Data for Name: nutrient_batches; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.nutrient_batches (id, node_id, name, solution_volume_l, prepared_at, measured_ec_uscm, measured_ph, notes, is_active, deactivated_at, created_by, created_at) FROM stdin;
\.


--
-- Data for Name: plot_soil_water_params; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.plot_soil_water_params (id, plot_id, theta_fc_pct, theta_pwp_pct, p_frac, zr_mm, kc, source, notes, valid_from, created_by, created_at) FROM stdin;
0769df3d-79d0-4e84-95fe-1bf304fea2d0	00000000-0000-0000-0000-0000000000b1	59.5	44.5	0.4	400	1	literatur_latosol_darmaga	θ_FC pF2,54 & air tersedia: Latosol Darmaga kebun campuran 0–40 cm (FC 60,5/58,5; AW 16,1/14,2 %vol). p=0,40 FAO-56 Tabel 22 (kopi). Zr=400 mm asumsi, revisi bila umur tanaman diketahui. Kc=1,0 Villa Nova et al. 2005.	2026-11-11 15:01:13.581571+00	\N	2026-11-11 15:01:13.581571+00
\.


--
-- Data for Name: plots; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.plots (id, user_id, plot_name, area_m2, location_lat, location_lng, created_at) FROM stdin;
00000000-0000-0000-0000-0000000000b1	00000000-0000-0000-0000-0000000000aa	Plot A	\N	-6.595	106.8166	2026-11-11 15:01:13.385703+00
\.


--
-- Data for Name: sensor_calibrations; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.sensor_calibrations (id, node_id, parameter, coeffs, raw_min, raw_max, r2, n_points, source, notes, valid_from, created_by, created_at) FROM stdin;
\.


--
-- Data for Name: sensor_raw_readings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.sensor_raw_readings (id, node_id, plot_id, reading_timestamp, soil_temperature_c, soil_moisture_pct, soil_ec_uscm, soil_ph, soil_n_mgkg, soil_p_mgkg, soil_k_mgkg, air_temperature_c, air_humidity_pct, rainfall_mm, rainfall_tip_count, quality_flag, reading_timestamp_raw, clock_segment, uptime_s, device_flags, time_status, ingested_at) FROM stdin;
1	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2025-12-31 17:00:00+00	\N	\N	\N	6.5	\N	\N	\N	\N	\N	\N	\N	\N	2025-12-31 17:00:00+00	\N	\N	\N	legacy	2026-11-11 15:01:13.402186+00
2	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:32:09+00	23.6	29.6	393	5.9	14	6	95	27.57	83.46	12.4	1234	\N	2026-11-11 12:29:12+00	a1b2c3d4	184	1	corrected_constant	2026-11-11 15:01:57.092295+00
3	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:33:09+00	23.5	31.2	393	6.2	10	7	100	27.65	83.69	12.4	1234	\N	2026-11-11 12:30:12+00	a1b2c3d4	244	1	corrected_constant	2026-11-11 15:01:57.092295+00
4	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:34:09+00	23.1	32.4	408	6.1	14	6	99	27.02	82.9	12.4	1234	\N	2026-11-11 12:31:12+00	a1b2c3d4	304	1	corrected_constant	2026-11-11 15:01:57.092295+00
5	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:35:09+00	23.7	31.2	394	6.1	14	7	97	27.76	80.57	12.4	1234	\N	2026-11-11 12:32:12+00	a1b2c3d4	364	1	corrected_constant	2026-11-11 15:01:57.092295+00
6	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:36:09+00	23.6	32.2	405	5.9	12	10	97	28.15	82.38	12.4	1234	\N	2026-11-11 12:33:12+00	a1b2c3d4	424	1	corrected_constant	2026-11-11 15:01:57.092295+00
7	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:37:09+00	23.8	32	399	6.3	13	6	100	26.56	81.35	12.4	1234	\N	2026-11-11 12:34:12+00	a1b2c3d4	484	1	corrected_constant	2026-11-11 15:01:57.092295+00
8	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:38:09+00	23.7	31	419	5.9	10	8	97	27.79	78.39	12.4	1234	\N	2026-11-11 12:35:12+00	a1b2c3d4	544	1	corrected_constant	2026-11-11 15:01:57.092295+00
9	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:39:09+00	24.4	30.8	414	6.3	12	6	97	27.11	81.67	12.4	1234	\N	2026-11-11 12:36:12+00	a1b2c3d4	604	1	corrected_constant	2026-11-11 15:01:57.092295+00
10	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:40:09+00	24.5	30.6	421	5.9	13	9	98	26.96	78.82	12.4	1234	\N	2026-11-11 12:37:12+00	a1b2c3d4	664	1	corrected_constant	2026-11-11 15:01:57.092295+00
11	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:41:09+00	\N	\N	\N	\N	\N	\N	\N	26.7	81.95	12.4	1234	soil_fail	2026-11-11 12:38:12+00	a1b2c3d4	724	5	corrected_constant	2026-11-11 15:01:57.092295+00
12	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:42:09+00	23.6	29.6	424	6	14	8	92	27.78	81.09	12.4	1234	\N	2026-11-11 12:39:12+00	a1b2c3d4	784	1	corrected_constant	2026-11-11 15:01:57.092295+00
13	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:43:09+00	24.8	32.1	425	6.1	13	9	91	27.36	80.4	12.4	1234	\N	2026-11-11 12:40:12+00	a1b2c3d4	844	1	corrected_constant	2026-11-11 15:01:57.092295+00
14	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:44:09+00	23.2	31.4	396	5.9	11	10	91	28.3	81.68	12.4	1234	\N	2026-11-11 12:41:12+00	a1b2c3d4	904	1	corrected_constant	2026-11-11 15:01:57.092295+00
15	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:45:09+00	24.3	32.8	428	6	10	6	97	28.39	80.8	12.4	1234	\N	2026-11-11 12:42:12+00	a1b2c3d4	964	1	corrected_constant	2026-11-11 15:01:57.092295+00
16	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:46:09+00	\N	\N	\N	\N	\N	\N	\N	26.69	81.26	12.4	1234	soil_fail	2026-11-11 12:43:12+00	a1b2c3d4	1024	5	corrected_constant	2026-11-11 15:01:57.092295+00
17	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:47:09+00	24.7	31.8	406	6.1	11	8	93	27.47	82.67	12.4	1234	\N	2026-11-11 12:44:12+00	a1b2c3d4	1084	1	corrected_constant	2026-11-11 15:01:57.092295+00
18	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:48:09+00	25	32.4	405	6.2	11	7	98	27.39	82.39	12.4	1234	\N	2026-11-11 12:45:12+00	a1b2c3d4	1144	1	corrected_constant	2026-11-11 15:01:57.092295+00
19	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:49:09+00	23.4	31.4	412	6.1	12	8	91	26.84	79.36	12.4	1234	\N	2026-11-11 12:46:12+00	a1b2c3d4	1204	1	corrected_constant	2026-11-11 15:01:57.092295+00
20	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:50:09+00	24.8	32.4	420	6.3	12	6	100	26.64	80.33	12.4	1234	\N	2026-11-11 12:47:12+00	a1b2c3d4	1264	1	corrected_constant	2026-11-11 15:01:57.092295+00
21	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:51:09+00	23.9	31.5	395	6.2	13	9	96	27.89	78.51	12.6	1235	\N	2026-11-11 12:48:12+00	a1b2c3d4	1324	1	corrected_constant	2026-11-11 15:01:57.092295+00
22	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:52:09+00	24.2	30.9	399	6.1	14	9	100	\N	\N	12.6	1235	sht_fail	2026-11-11 12:49:12+00	a1b2c3d4	1384	9	corrected_constant	2026-11-11 15:01:57.092295+00
23	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:53:09+00	24.5	29.4	398	6.1	11	7	90	26.9	79.76	12.6	1235	\N	2026-11-11 12:50:12+00	a1b2c3d4	1444	1	corrected_constant	2026-11-11 15:01:57.092295+00
24	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:54:09+00	23.8	29.5	412	6.3	14	10	96	28.05	83.27	12.6	1235	\N	2026-11-11 12:51:12+00	a1b2c3d4	1504	1	corrected_constant	2026-11-11 15:01:57.092295+00
25	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:55:09+00	24.7	32.1	428	5.9	11	7	92	27.35	82.35	12.6	1235	\N	2026-11-11 12:52:12+00	a1b2c3d4	1564	1	corrected_constant	2026-11-11 15:01:57.092295+00
26	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:56:09+00	24.1	32.1	396	6.3	10	7	93	26.95	82.63	12.6	1235	\N	2026-11-11 12:53:12+00	a1b2c3d4	1624	1	corrected_constant	2026-11-11 15:01:57.092295+00
27	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:57:09+00	24.8	30.8	429	6.3	14	10	93	27.79	80.71	12.6	1235	\N	2026-11-11 12:54:12+00	a1b2c3d4	1684	1	corrected_constant	2026-11-11 15:01:57.092295+00
28	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:58:09+00	24.4	32.5	406	6.3	11	9	92	27.23	80.35	12.6	1235	\N	2026-11-11 12:55:12+00	a1b2c3d4	1744	1	corrected_constant	2026-11-11 15:01:57.092295+00
29	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:59:09+00	23.4	30.2	397	6.3	11	8	92	26.91	78.82	12.6	1235	\N	2026-11-11 12:56:12+00	a1b2c3d4	1804	1	corrected_constant	2026-11-11 15:01:57.092295+00
30	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:00:09+00	24.8	29.7	404	6	13	10	96	27.08	79.17	12.8	1236	\N	2026-11-11 12:57:12+00	a1b2c3d4	1864	1	corrected_constant	2026-11-11 15:01:57.092295+00
31	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:01:09+00	24.1	30.8	391	6.1	14	10	94	27.42	78.39	12.8	1236	\N	2026-11-11 12:58:12+00	a1b2c3d4	1924	1	corrected_constant	2026-11-11 15:01:57.092295+00
32	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:02:09+00	23.2	30.1	392	6.3	11	8	92	28.04	83.1	12.8	1236	\N	2026-11-11 12:59:12+00	a1b2c3d4	1984	1	corrected_constant	2026-11-11 15:01:57.092295+00
33	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:03:09+00	24.1	31.1	421	6.2	10	8	90	28	79.1	13	1237	\N	2026-11-11 13:00:12+00	a1b2c3d4	2044	1	corrected_constant	2026-11-11 15:01:57.092295+00
34	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:04:09+00	23.2	30	428	6.2	10	8	91	27.31	80.03	13	1237	\N	2026-11-11 13:01:12+00	a1b2c3d4	2104	1	corrected_constant	2026-11-11 15:01:57.092295+00
35	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:05:09+00	23.3	31.1	405	6.3	11	8	90	26.76	83.59	13	1237	\N	2026-11-11 13:02:12+00	a1b2c3d4	2164	1	corrected_constant	2026-11-11 15:01:57.092295+00
36	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:06:09+00	23.9	31.7	407	6	10	8	90	26.43	82.4	13	1237	\N	2026-11-11 13:03:12+00	a1b2c3d4	2224	1	corrected_constant	2026-11-11 15:01:57.092295+00
37	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:07:09+00	24.9	29.4	417	6.2	14	9	98	27.02	79.29	13	1237	\N	2026-11-11 13:04:12+00	a1b2c3d4	2284	1	corrected_constant	2026-11-11 15:01:57.092295+00
38	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:08:09+00	24.5	29.6	412	6.3	11	6	91	27.65	83.28	13	1237	\N	2026-11-11 13:05:12+00	a1b2c3d4	2344	1	corrected_constant	2026-11-11 15:01:57.092295+00
39	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:09:09+00	\N	\N	\N	\N	\N	\N	\N	26.77	79.61	13	1237	soil_fail	2026-11-11 13:06:12+00	a1b2c3d4	2404	5	corrected_constant	2026-11-11 15:01:57.092295+00
40	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:10:09+00	25	30.3	392	6.3	12	7	95	26.77	80.01	13	1237	\N	2026-11-11 13:07:12+00	a1b2c3d4	2464	1	corrected_constant	2026-11-11 15:01:57.092295+00
41	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:11:09+00	23.5	32.1	395	6	10	7	96	27.57	80.36	13	1237	\N	2026-11-11 13:08:12+00	a1b2c3d4	2524	1	corrected_constant	2026-11-11 15:01:57.092295+00
42	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:12:09+00	24.9	32.4	399	6.2	14	9	95	27.84	80.97	13	1237	\N	2026-11-11 13:09:12+00	a1b2c3d4	2584	1	corrected_constant	2026-11-11 15:01:57.092295+00
43	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:13:09+00	24.6	31.9	422	6.2	14	7	98	\N	\N	13	1237	sht_fail	2026-11-11 13:10:12+00	a1b2c3d4	2644	9	corrected_constant	2026-11-11 15:01:57.092295+00
44	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:14:09+00	24.6	31.8	404	5.9	10	7	100	27.12	78.63	13	1237	\N	2026-11-11 13:11:12+00	a1b2c3d4	2704	1	corrected_constant	2026-11-11 15:01:57.092295+00
45	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:15:09+00	24.3	31.7	421	6	13	6	98	28.2	78.55	13	1237	\N	2026-11-11 13:12:12+00	a1b2c3d4	2764	1	corrected_constant	2026-11-11 15:01:57.092295+00
46	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:16:09+00	24.6	32.4	405	6.2	11	7	100	28.35	80.96	13	1237	\N	2026-11-11 13:13:12+00	a1b2c3d4	2824	1	corrected_constant	2026-11-11 15:01:57.092295+00
47	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:17:09+00	24.5	31.5	402	5.9	11	8	94	27.7	82.16	13	1237	\N	2026-11-11 13:14:12+00	a1b2c3d4	2884	1	corrected_constant	2026-11-11 15:01:57.092295+00
48	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:18:09+00	24	32.9	396	6.2	13	8	98	26.97	80.8	13	1237	\N	2026-11-11 13:15:12+00	a1b2c3d4	2944	1	corrected_constant	2026-11-11 15:01:57.092295+00
49	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:19:09+00	23.6	29.3	420	5.9	13	6	98	28.34	80.7	13	1237	\N	2026-11-11 13:16:12+00	a1b2c3d4	3004	1	corrected_constant	2026-11-11 15:01:57.092295+00
50	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:20:09+00	23.4	31.3	399	6.2	12	8	92	27.61	81.79	13	1237	\N	2026-11-11 13:17:12+00	a1b2c3d4	3064	1	corrected_constant	2026-11-11 15:01:57.092295+00
51	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:21:09+00	24	32.5	415	5.9	10	9	100	27.3	79.81	13	1237	\N	2026-11-11 13:18:12+00	a1b2c3d4	3124	1	corrected_constant	2026-11-11 15:01:57.092295+00
52	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:22:09+00	24.7	29	411	6.2	10	7	90	28.2	79.74	13	1237	\N	2026-11-11 13:19:12+00	a1b2c3d4	3184	1	corrected_constant	2026-11-11 15:01:57.092295+00
53	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:23:09+00	24.2	30.4	417	6.2	10	8	91	26.5	81.97	13	1237	\N	2026-11-11 13:20:12+00	a1b2c3d4	3244	1	corrected_constant	2026-11-11 15:01:57.092295+00
54	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:24:09+00	23.9	30.3	413	6.2	13	6	100	27.2	83.25	13	1237	\N	2026-11-11 13:21:12+00	a1b2c3d4	3304	1	corrected_constant	2026-11-11 15:01:57.092295+00
55	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:25:09+00	24.9	30.6	429	6.2	12	9	90	28.22	81.3	13	1237	\N	2026-11-11 13:22:12+00	a1b2c3d4	3364	1	corrected_constant	2026-11-11 15:01:57.092295+00
56	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:26:09+00	23.5	32	406	6.1	11	8	97	27.51	80.37	13	1237	\N	2026-11-11 13:23:12+00	a1b2c3d4	3424	1	corrected_constant	2026-11-11 15:01:57.092295+00
57	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:27:09+00	24.8	31	404	6.1	12	9	96	26.68	79.15	13	1237	\N	2026-11-11 13:24:12+00	a1b2c3d4	3484	1	corrected_constant	2026-11-11 15:01:57.092295+00
58	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:28:09+00	23.5	30	426	6	10	9	96	27.23	81.15	13	1237	\N	2026-11-11 13:25:12+00	a1b2c3d4	3544	1	corrected_constant	2026-11-11 15:01:57.092295+00
59	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:29:09+00	23.6	32.9	398	6.2	14	7	91	26.94	79.49	13	1237	\N	2026-11-11 13:26:12+00	a1b2c3d4	3604	1	corrected_constant	2026-11-11 15:01:57.092295+00
60	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:30:09+00	24.7	32.5	391	6	13	9	99	27.38	78.44	13	1237	\N	2026-11-11 13:27:12+00	a1b2c3d4	3664	1	corrected_constant	2026-11-11 15:01:57.092295+00
61	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:31:09+00	23.9	30.8	396	6	11	10	100	26.62	82.95	13	1237	\N	2026-11-11 13:28:12+00	a1b2c3d4	3724	1	corrected_constant	2026-11-11 15:01:57.092295+00
62	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:32:09+00	23.2	32.1	390	6.2	11	10	90	27.69	79.82	13	1237	\N	2026-11-11 13:29:12+00	a1b2c3d4	3784	1	corrected_constant	2026-11-11 15:01:57.092295+00
63	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:33:09+00	\N	\N	\N	\N	\N	\N	\N	26.92	82.74	13	1237	soil_fail	2026-11-11 13:30:12+00	a1b2c3d4	3844	5	corrected_constant	2026-11-11 15:01:57.092295+00
64	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:34:09+00	23.6	30.3	405	6.1	11	10	93	26.46	80.47	13	1237	\N	2026-11-11 13:31:12+00	a1b2c3d4	3904	1	corrected_constant	2026-11-11 15:01:57.092295+00
65	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:35:09+00	24.8	31.6	395	6	13	8	93	27.39	82.17	13	1237	\N	2026-11-11 13:32:12+00	a1b2c3d4	3964	1	corrected_constant	2026-11-11 15:01:57.092295+00
66	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:36:09+00	23	30.2	422	5.9	13	7	94	27.93	79.16	13	1237	\N	2026-11-11 13:33:12+00	a1b2c3d4	4024	1	corrected_constant	2026-11-11 15:01:57.092295+00
67	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:37:09+00	23.2	31.5	429	6	11	9	96	28.22	78.34	13	1237	\N	2026-11-11 13:34:12+00	a1b2c3d4	4084	1	corrected_constant	2026-11-11 15:01:57.092295+00
68	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:38:09+00	23	31.4	416	5.9	10	7	96	27.3	82.27	13	1237	\N	2026-11-11 13:35:12+00	a1b2c3d4	4144	1	corrected_constant	2026-11-11 15:01:57.092295+00
69	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:39:09+00	23.3	29.8	423	6.2	10	8	100	27.85	83.03	13	1237	\N	2026-11-11 13:36:12+00	a1b2c3d4	4204	1	corrected_constant	2026-11-11 15:01:57.092295+00
380	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:27:00+00	\N	\N	\N	\N	\N	\N	\N	27.53	80.75	14	1242	soil_fail	2026-11-09 16:22:00+00	b1000001	4864	5	corrected_constant	2026-11-11 15:04:05.047053+00
70	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:40:09+00	23.2	29.3	416	6.3	10	10	93	27.16	82.61	13	1237	\N	2026-11-11 13:37:12+00	a1b2c3d4	4264	1	corrected_constant	2026-11-11 15:01:57.092295+00
71	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:41:09+00	24.4	29.8	424	6.3	11	8	95	27.87	80.85	13	1237	\N	2026-11-11 13:38:12+00	a1b2c3d4	4324	1	corrected_constant	2026-11-11 15:01:57.092295+00
72	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:42:09+00	23.8	30.5	419	5.9	10	8	93	27.89	83.39	13	1237	\N	2026-11-11 13:39:12+00	a1b2c3d4	4384	1	corrected_constant	2026-11-11 15:01:57.092295+00
73	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:43:09+00	24.2	30	410	6.3	12	6	99	\N	\N	13	1237	sht_fail	2026-11-11 13:40:12+00	a1b2c3d4	4444	9	corrected_constant	2026-11-11 15:01:57.092295+00
74	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:44:09+00	24	32.8	414	6.2	13	9	92	28.26	79.1	13	1237	\N	2026-11-11 13:41:12+00	a1b2c3d4	4504	1	corrected_constant	2026-11-11 15:01:57.092295+00
75	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:45:09+00	24.5	31.4	410	6.2	13	8	99	26.56	79.18	13	1237	\N	2026-11-11 13:42:12+00	a1b2c3d4	4564	1	corrected_constant	2026-11-11 15:01:57.092295+00
76	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:46:09+00	23.1	31.2	410	6	13	6	91	26.93	78.5	13	1237	\N	2026-11-11 13:43:12+00	a1b2c3d4	4624	1	corrected_constant	2026-11-11 15:01:57.092295+00
77	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:47:09+00	23.9	29.9	416	6.1	11	10	100	27.92	82.68	13	1237	\N	2026-11-11 13:44:12+00	a1b2c3d4	4684	1	corrected_constant	2026-11-11 15:01:57.092295+00
78	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:48:09+00	23.5	30	418	6	11	7	92	26.96	83.45	13	1237	\N	2026-11-11 13:45:12+00	a1b2c3d4	4744	1	corrected_constant	2026-11-11 15:01:57.092295+00
79	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:49:09+00	23.5	31.1	396	6.2	10	6	90	27.35	82.91	13.2	1238	\N	2026-11-11 13:46:12+00	a1b2c3d4	4804	1	corrected_constant	2026-11-11 15:01:57.092295+00
80	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:50:09+00	23.6	29.5	402	6.1	14	7	91	27.14	83.2	13.2	1238	\N	2026-11-11 13:47:12+00	a1b2c3d4	4864	1	corrected_constant	2026-11-11 15:01:57.092295+00
81	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:51:09+00	24.9	29.4	428	6.2	12	7	90	27.14	78.85	13.2	1238	\N	2026-11-11 13:48:12+00	a1b2c3d4	4924	1	corrected_constant	2026-11-11 15:01:57.092295+00
82	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:52:09+00	\N	\N	\N	\N	\N	\N	\N	27.64	78.47	13.2	1238	soil_fail	2026-11-11 13:49:12+00	a1b2c3d4	4984	5	corrected_constant	2026-11-11 15:01:57.092295+00
83	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:53:09+00	23.8	32.2	425	6	14	6	100	26.73	82.17	13.2	1238	\N	2026-11-11 13:50:12+00	a1b2c3d4	5044	1	corrected_constant	2026-11-11 15:01:57.092295+00
84	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:54:09+00	24.9	30.2	426	6.3	13	9	90	28.13	83.98	13.2	1238	\N	2026-11-11 13:51:12+00	a1b2c3d4	5104	1	corrected_constant	2026-11-11 15:01:57.092295+00
85	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:55:09+00	23.4	29	400	6.1	10	9	99	\N	\N	13.2	1238	sht_fail	2026-11-11 13:52:12+00	a1b2c3d4	5164	9	corrected_constant	2026-11-11 15:01:57.092295+00
86	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:56:09+00	24.3	32.6	395	6.1	12	10	92	26.69	79.7	13.2	1238	\N	2026-11-11 13:53:12+00	a1b2c3d4	5224	1	corrected_constant	2026-11-11 15:01:57.092295+00
87	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:57:09+00	24	32.2	402	6	10	9	95	26.51	83.56	13.2	1238	\N	2026-11-11 13:54:12+00	a1b2c3d4	5284	1	corrected_constant	2026-11-11 15:01:57.092295+00
88	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:58:09+00	24.6	29.6	404	6.1	14	7	97	26.77	79.31	13.2	1238	\N	2026-11-11 13:55:12+00	a1b2c3d4	5344	1	corrected_constant	2026-11-11 15:01:57.092295+00
89	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 13:59:09+00	23.2	30	402	5.9	14	6	100	28.08	78.71	13.2	1238	\N	2026-11-11 13:56:12+00	a1b2c3d4	5404	1	corrected_constant	2026-11-11 15:01:57.092295+00
90	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:00:09+00	\N	\N	\N	\N	\N	\N	\N	27.41	79.07	13.2	1238	soil_fail	2026-11-11 13:57:12+00	a1b2c3d4	5464	5	corrected_constant	2026-11-11 15:01:57.092295+00
91	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:01:09+00	23.9	31.5	419	6.2	13	9	91	26.53	80.15	13.2	1238	\N	2026-11-11 13:58:12+00	a1b2c3d4	5524	1	corrected_constant	2026-11-11 15:01:57.092295+00
92	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:02:09+00	24.3	29.2	398	5.9	12	10	91	26.51	81.02	13.2	1238	\N	2026-11-11 13:59:12+00	a1b2c3d4	5584	1	corrected_constant	2026-11-11 15:01:57.092295+00
93	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:03:09+00	24.7	33	397	6	13	8	92	27.77	82.33	13.2	1238	\N	2026-11-11 14:00:12+00	a1b2c3d4	5644	1	corrected_constant	2026-11-11 15:01:57.092295+00
94	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:04:09+00	23.5	30.3	429	6	13	7	94	27.4	83.52	13.2	1238	\N	2026-11-11 14:01:12+00	a1b2c3d4	5704	1	corrected_constant	2026-11-11 15:01:57.092295+00
95	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:05:09+00	23.6	29.1	401	6.1	12	8	96	26.74	82.71	13.2	1238	\N	2026-11-11 14:02:12+00	a1b2c3d4	5764	1	corrected_constant	2026-11-11 15:01:57.092295+00
96	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:06:09+00	23.7	32.5	425	6.1	10	8	98	27.66	80.37	13.2	1238	\N	2026-11-11 14:03:12+00	a1b2c3d4	5824	1	corrected_constant	2026-11-11 15:01:57.092295+00
97	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:07:09+00	24.2	30.4	395	6.1	11	10	90	26.99	81.1	13.2	1238	\N	2026-11-11 14:04:12+00	a1b2c3d4	5884	1	corrected_constant	2026-11-11 15:01:57.092295+00
98	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:08:09+00	24.9	32.6	390	6.2	11	7	94	27.63	80.59	13.2	1238	\N	2026-11-11 14:05:12+00	a1b2c3d4	5944	1	corrected_constant	2026-11-11 15:01:57.092295+00
99	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:09:09+00	23.5	31.6	391	5.9	14	8	94	26.61	80.14	13.2	1238	\N	2026-11-11 14:06:12+00	a1b2c3d4	6004	1	corrected_constant	2026-11-11 15:01:57.092295+00
100	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:10:09+00	23.4	31.5	420	6	10	7	92	27.3	78.38	13.2	1238	\N	2026-11-11 14:07:12+00	a1b2c3d4	6064	1	corrected_constant	2026-11-11 15:01:57.092295+00
101	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:11:09+00	24.6	32.9	393	6.2	14	8	99	27.69	80.66	13.2	1238	\N	2026-11-11 14:08:12+00	a1b2c3d4	6124	1	corrected_constant	2026-11-11 15:01:57.092295+00
102	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:12:09+00	\N	\N	\N	\N	\N	\N	\N	26.52	82.67	13.2	1238	soil_fail	2026-11-11 14:09:12+00	a1b2c3d4	6184	5	corrected_constant	2026-11-11 15:01:57.122223+00
103	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:13:09+00	23.3	29.8	428	6.2	13	10	92	27.42	78.38	13.2	1238	\N	2026-11-11 14:10:12+00	a1b2c3d4	6244	1	corrected_constant	2026-11-11 15:01:57.122223+00
104	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:14:09+00	24	31.2	414	6.2	13	6	100	27.3	79.36	13.4	1239	\N	2026-11-11 14:11:12+00	a1b2c3d4	6304	1	corrected_constant	2026-11-11 15:01:57.122223+00
105	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:15:09+00	23.7	32	406	6.2	12	10	100	27.27	82.73	13.4	1239	\N	2026-11-11 14:12:12+00	a1b2c3d4	6364	1	corrected_constant	2026-11-11 15:01:57.122223+00
106	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:16:09+00	24.9	29.9	422	5.9	12	7	93	28.29	82.48	13.4	1239	\N	2026-11-11 14:13:12+00	a1b2c3d4	6424	1	corrected_constant	2026-11-11 15:01:57.122223+00
107	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:17:09+00	23.5	32.6	430	6.3	14	9	97	28.08	82.19	13.4	1239	\N	2026-11-11 14:14:12+00	a1b2c3d4	6484	1	corrected_constant	2026-11-11 15:01:57.122223+00
108	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:18:09+00	\N	\N	\N	\N	\N	\N	\N	28.22	78.87	13.4	1239	soil_fail	2026-11-11 14:15:12+00	a1b2c3d4	6544	5	corrected_constant	2026-11-11 15:01:57.122223+00
109	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:19:09+00	23.7	29.6	391	5.9	11	6	91	27.87	78.39	13.4	1239	\N	2026-11-11 14:16:12+00	a1b2c3d4	6604	1	corrected_constant	2026-11-11 15:01:57.122223+00
110	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:20:09+00	\N	\N	\N	\N	\N	\N	\N	26.81	78.67	13.4	1239	soil_fail	2026-11-11 14:17:12+00	a1b2c3d4	6664	5	corrected_constant	2026-11-11 15:01:57.122223+00
111	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:21:09+00	24.3	32.3	430	6.2	13	6	92	26.6	82.54	13.4	1239	\N	2026-11-11 14:18:12+00	a1b2c3d4	6724	1	corrected_constant	2026-11-11 15:01:57.122223+00
112	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:22:09+00	23	30	408	5.9	12	8	99	\N	\N	13.4	1239	sht_fail	2026-11-11 14:19:12+00	a1b2c3d4	6784	9	corrected_constant	2026-11-11 15:01:57.122223+00
113	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:23:09+00	23.9	32.1	412	6.1	10	10	99	26.83	83.17	13.4	1239	\N	2026-11-11 14:20:12+00	a1b2c3d4	6844	1	corrected_constant	2026-11-11 15:01:57.122223+00
114	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:24:09+00	23	29.8	393	5.9	13	6	97	27.79	82.95	13.4	1239	\N	2026-11-11 14:21:12+00	a1b2c3d4	6904	1	corrected_constant	2026-11-11 15:01:57.122223+00
115	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:25:09+00	24	31.3	400	6	11	7	97	26.73	83.63	13.4	1239	\N	2026-11-11 14:22:12+00	a1b2c3d4	6964	1	corrected_constant	2026-11-11 15:01:57.122223+00
116	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:26:09+00	24.1	29.4	410	6	13	9	91	27.24	81.88	13.4	1239	\N	2026-11-11 14:23:12+00	a1b2c3d4	7024	1	corrected_constant	2026-11-11 15:01:57.122223+00
117	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:27:09+00	24.1	29.7	430	6	13	7	98	\N	\N	13.4	1239	sht_fail	2026-11-11 14:24:12+00	a1b2c3d4	7084	9	corrected_constant	2026-11-11 15:01:57.122223+00
118	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:28:09+00	24	32.5	418	6.2	12	7	97	27.28	82.64	13.4	1239	\N	2026-11-11 14:25:12+00	a1b2c3d4	7144	1	corrected_constant	2026-11-11 15:01:57.122223+00
119	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:29:09+00	24.8	30	402	6	14	7	92	28.35	82.34	13.4	1239	\N	2026-11-11 14:26:12+00	a1b2c3d4	7204	1	corrected_constant	2026-11-11 15:01:57.122223+00
120	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:30:09+00	24.9	30	396	6	10	7	96	26.7	78.89	13.4	1239	\N	2026-11-11 14:27:12+00	a1b2c3d4	7264	1	corrected_constant	2026-11-11 15:01:57.122223+00
121	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:31:09+00	23.2	32.6	407	6	13	9	90	26.43	83.13	13.4	1239	\N	2026-11-11 14:28:12+00	a1b2c3d4	7324	1	corrected_constant	2026-11-11 15:01:57.122223+00
122	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:32:09+00	23.6	29.1	406	6.1	13	6	93	28.22	80.58	13.4	1239	\N	2026-11-11 14:29:12+00	a1b2c3d4	7384	1	corrected_constant	2026-11-11 15:01:57.122223+00
123	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:33:09+00	23.5	31.9	427	6.2	11	6	97	27.27	79.56	13.4	1239	\N	2026-11-11 14:30:12+00	a1b2c3d4	7444	1	corrected_constant	2026-11-11 15:01:57.122223+00
124	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:34:09+00	23.8	31.9	400	6	13	9	97	26.44	83.15	13.4	1239	\N	2026-11-11 14:31:12+00	a1b2c3d4	7504	1	corrected_constant	2026-11-11 15:01:57.122223+00
125	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:35:09+00	24.8	30.3	390	6.1	13	6	90	26.9	79.31	13.4	1239	\N	2026-11-11 14:32:12+00	a1b2c3d4	7564	1	corrected_constant	2026-11-11 15:01:57.122223+00
126	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:36:09+00	23.7	32.4	419	6.1	13	10	90	27.68	82.97	13.4	1239	\N	2026-11-11 14:33:12+00	a1b2c3d4	7624	1	corrected_constant	2026-11-11 15:01:57.122223+00
127	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:37:09+00	23.4	31.7	415	6.1	10	10	95	27.68	79.51	13.4	1239	\N	2026-11-11 14:34:12+00	a1b2c3d4	7684	1	corrected_constant	2026-11-11 15:01:57.122223+00
128	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:38:09+00	24.8	31.5	412	6.1	10	7	94	27.88	83.64	13.4	1239	\N	2026-11-11 14:35:12+00	a1b2c3d4	7744	1	corrected_constant	2026-11-11 15:01:57.122223+00
129	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:39:09+00	23.8	29.8	398	6.3	10	7	97	27.68	82.32	13.4	1239	\N	2026-11-11 14:36:12+00	a1b2c3d4	7804	1	corrected_constant	2026-11-11 15:01:57.122223+00
130	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:40:09+00	24.7	32.2	416	6.1	12	10	100	26.65	83	13.4	1239	\N	2026-11-11 14:37:12+00	a1b2c3d4	7864	1	corrected_constant	2026-11-11 15:01:57.122223+00
131	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:41:09+00	23.8	30	417	6.2	13	6	94	27.12	81.93	13.4	1239	\N	2026-11-11 14:38:12+00	a1b2c3d4	7924	1	corrected_constant	2026-11-11 15:01:57.122223+00
132	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:42:09+00	23.2	32.6	399	6.3	13	6	91	28.06	83.43	13.4	1239	\N	2026-11-11 14:39:12+00	a1b2c3d4	7984	1	corrected_constant	2026-11-11 15:01:57.122223+00
133	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:43:09+00	24.3	29.1	390	6	10	8	94	27.62	81.47	13.4	1239	\N	2026-11-11 14:40:12+00	a1b2c3d4	8044	1	corrected_constant	2026-11-11 15:01:57.122223+00
134	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:44:09+00	24.6	29.8	415	6.2	11	10	99	28.35	78.54	13.4	1239	\N	2026-11-11 14:41:12+00	a1b2c3d4	8104	1	corrected_constant	2026-11-11 15:01:57.122223+00
135	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:45:09+00	23.6	31	403	6.1	13	6	98	26.64	80.51	13.4	1239	\N	2026-11-11 14:42:12+00	a1b2c3d4	8164	1	corrected_constant	2026-11-11 15:01:57.122223+00
136	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:46:09+00	24	32.6	421	6	11	10	99	28.13	78.04	13.4	1239	\N	2026-11-11 14:43:12+00	a1b2c3d4	8224	1	corrected_constant	2026-11-11 15:01:57.122223+00
137	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:47:09+00	\N	\N	\N	\N	\N	\N	\N	\N	\N	13.4	1239	soil_fail,sht_fail	2026-11-11 14:44:12+00	a1b2c3d4	8284	13	corrected_constant	2026-11-11 15:01:57.122223+00
138	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:48:09+00	25	32.2	396	6.1	13	7	90	26.83	80.49	13.4	1239	\N	2026-11-11 14:45:12+00	a1b2c3d4	8344	1	corrected_constant	2026-11-11 15:01:57.122223+00
139	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:49:09+00	23.7	32.1	425	6.2	11	8	96	27.08	79.51	13.4	1239	\N	2026-11-11 14:46:12+00	a1b2c3d4	8404	1	corrected_constant	2026-11-11 15:01:57.122223+00
140	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:50:09+00	24	30.3	407	6.2	12	7	100	27.38	78.71	13.4	1239	\N	2026-11-11 14:47:12+00	a1b2c3d4	8464	1	corrected_constant	2026-11-11 15:01:57.122223+00
141	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:51:09+00	24.9	29.4	392	6.1	14	9	98	\N	\N	13.4	1239	sht_fail	2026-11-11 14:48:12+00	a1b2c3d4	8524	9	corrected_constant	2026-11-11 15:01:57.122223+00
142	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:52:09+00	24	32.1	393	6.2	14	10	96	27.63	81.76	13.4	1239	\N	2026-11-11 14:49:12+00	a1b2c3d4	8584	1	corrected_constant	2026-11-11 15:01:57.122223+00
143	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:53:09+00	23.4	31.7	419	6.2	11	6	100	26.76	78.22	13.4	1239	\N	2026-11-11 14:50:12+00	a1b2c3d4	8644	1	corrected_constant	2026-11-11 15:01:57.122223+00
144	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:54:09+00	23.7	32.3	409	6.1	12	8	92	27.24	79.91	13.4	1239	\N	2026-11-11 14:51:12+00	a1b2c3d4	8704	1	corrected_constant	2026-11-11 15:01:57.122223+00
145	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:55:09+00	23.1	31.3	392	6.2	13	10	96	27.29	78.08	13.4	1239	\N	2026-11-11 14:52:12+00	a1b2c3d4	8764	1	corrected_constant	2026-11-11 15:01:57.122223+00
146	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:56:09+00	25	30.9	416	6.1	10	9	93	\N	\N	13.4	1239	sht_fail	2026-11-11 14:53:12+00	a1b2c3d4	8824	9	corrected_constant	2026-11-11 15:01:57.122223+00
147	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:57:09+00	25	32.4	403	6.2	11	9	90	26.95	81.41	13.4	1239	\N	2026-11-11 14:54:12+00	a1b2c3d4	8884	1	corrected_constant	2026-11-11 15:01:57.122223+00
148	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:58:09+00	23.7	32	399	6.2	10	8	100	27.51	80.99	13.4	1239	\N	2026-11-11 14:55:12+00	a1b2c3d4	8944	1	corrected_constant	2026-11-11 15:01:57.122223+00
149	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 14:59:09+00	23.1	29.1	393	5.9	14	6	96	27.02	82.38	13.4	1239	\N	2026-11-11 14:56:12+00	a1b2c3d4	9004	1	corrected_constant	2026-11-11 15:01:57.122223+00
150	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 15:00:09+00	23.1	30.5	426	6.2	13	7	92	28.33	78.7	13.4	1239	\N	2026-11-11 14:57:12+00	a1b2c3d4	9064	1	corrected_constant	2026-11-11 15:01:57.122223+00
151	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 15:01:09+00	24	32.1	418	6.3	14	8	94	26.96	81.73	13.4	1239	\N	2026-11-11 14:58:12+00	a1b2c3d4	9124	1	corrected_constant	2026-11-11 15:01:57.122223+00
302	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:09:00+00	23.9	31.2	419	6.1	14	7	92	28.01	80.85	12.4	1234	\N	2026-11-09 15:04:00+00	b1000001	184	1	corrected_constant	2026-11-11 15:04:05.047053+00
303	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:10:00+00	23.3	31.2	430	5.9	13	9	100	27.88	81.9	12.4	1234	\N	2026-11-09 15:05:00+00	b1000001	244	1	corrected_constant	2026-11-11 15:04:05.047053+00
304	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:11:00+00	23.1	32.5	428	5.9	13	8	97	27.58	79.17	12.6	1235	\N	2026-11-09 15:06:00+00	b1000001	304	1	corrected_constant	2026-11-11 15:04:05.047053+00
305	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:12:00+00	\N	\N	\N	\N	\N	\N	\N	27.92	81.08	12.6	1235	soil_fail	2026-11-09 15:07:00+00	b1000001	364	5	corrected_constant	2026-11-11 15:04:05.047053+00
306	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:13:00+00	23.2	30.2	394	6.3	10	7	93	28.25	78.31	12.6	1235	\N	2026-11-09 15:08:00+00	b1000001	424	1	corrected_constant	2026-11-11 15:04:05.047053+00
307	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:14:00+00	24.1	29.8	407	6	12	8	90	28.33	82.55	12.6	1235	\N	2026-11-09 15:09:00+00	b1000001	484	1	corrected_constant	2026-11-11 15:04:05.047053+00
308	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:15:00+00	23.1	32.2	401	6.2	11	9	98	26.78	82.39	12.6	1235	\N	2026-11-09 15:10:00+00	b1000001	544	1	corrected_constant	2026-11-11 15:04:05.047053+00
309	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:16:00+00	23.8	29.9	407	6.2	14	8	90	26.82	80.37	12.6	1235	\N	2026-11-09 15:11:00+00	b1000001	604	1	corrected_constant	2026-11-11 15:04:05.047053+00
310	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:17:00+00	25	29.9	406	5.9	14	8	94	27.17	78.45	12.8	1236	\N	2026-11-09 15:12:00+00	b1000001	664	1	corrected_constant	2026-11-11 15:04:05.047053+00
311	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:18:00+00	23.7	31.5	398	6.3	13	10	92	28.13	79.1	12.8	1236	\N	2026-11-09 15:13:00+00	b1000001	724	1	corrected_constant	2026-11-11 15:04:05.047053+00
312	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:19:00+00	23.5	29.8	430	6.3	11	9	97	\N	\N	12.8	1236	sht_fail	2026-11-09 15:14:00+00	b1000001	784	9	corrected_constant	2026-11-11 15:04:05.047053+00
313	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:20:00+00	23.5	31.8	406	6.1	14	9	94	27.44	83.58	12.8	1236	\N	2026-11-09 15:15:00+00	b1000001	844	1	corrected_constant	2026-11-11 15:04:05.047053+00
314	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:21:00+00	24.3	31.5	394	6	11	6	91	26.94	80.67	12.8	1236	\N	2026-11-09 15:16:00+00	b1000001	904	1	corrected_constant	2026-11-11 15:04:05.047053+00
315	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:22:00+00	24.1	29.5	413	6	13	8	100	27.87	81.13	12.8	1236	\N	2026-11-09 15:17:00+00	b1000001	964	1	corrected_constant	2026-11-11 15:04:05.047053+00
316	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:23:00+00	23.9	30.4	409	6.3	10	10	100	26.55	78.4	12.8	1236	\N	2026-11-09 15:18:00+00	b1000001	1024	1	corrected_constant	2026-11-11 15:04:05.047053+00
317	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:24:00+00	23.9	30.5	392	6.3	11	8	95	26.57	80.84	12.8	1236	\N	2026-11-09 15:19:00+00	b1000001	1084	1	corrected_constant	2026-11-11 15:04:05.047053+00
318	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:25:00+00	23.1	31	390	6.1	13	9	99	26.42	78.43	12.8	1236	\N	2026-11-09 15:20:00+00	b1000001	1144	1	corrected_constant	2026-11-11 15:04:05.047053+00
319	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:26:00+00	23.8	30.3	427	6.1	13	10	91	27.44	81.09	13	1237	\N	2026-11-09 15:21:00+00	b1000001	1204	1	corrected_constant	2026-11-11 15:04:05.047053+00
320	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:27:00+00	24.9	29.5	429	6.2	13	8	90	27.14	78.86	13	1237	\N	2026-11-09 15:22:00+00	b1000001	1264	1	corrected_constant	2026-11-11 15:04:05.047053+00
321	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:28:00+00	23.7	32.7	421	6.3	12	9	100	26.9	81.81	13	1237	\N	2026-11-09 15:23:00+00	b1000001	1324	1	corrected_constant	2026-11-11 15:04:05.047053+00
322	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:29:00+00	23.4	29.9	410	6	11	9	95	28.07	83.09	13	1237	\N	2026-11-09 15:24:00+00	b1000001	1384	1	corrected_constant	2026-11-11 15:04:05.047053+00
323	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:30:00+00	23.3	30.8	407	6.3	13	9	100	27.44	82.03	13	1237	\N	2026-11-09 15:25:00+00	b1000001	1444	1	corrected_constant	2026-11-11 15:04:05.047053+00
324	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:31:00+00	23.6	32.3	407	6.2	10	8	99	27.11	81.9	13	1237	\N	2026-11-09 15:26:00+00	b1000001	1504	1	corrected_constant	2026-11-11 15:04:05.047053+00
325	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:32:00+00	23.4	32.1	407	6	11	6	100	26.63	78.65	13	1237	\N	2026-11-09 15:27:00+00	b1000001	1564	1	corrected_constant	2026-11-11 15:04:05.047053+00
326	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:33:00+00	23.2	29.8	420	6	10	9	98	27.83	79.07	13	1237	\N	2026-11-09 15:28:00+00	b1000001	1624	1	corrected_constant	2026-11-11 15:04:05.047053+00
327	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:34:00+00	24	31.5	400	6.1	11	6	96	28.27	82.33	13	1237	\N	2026-11-09 15:29:00+00	b1000001	1684	1	corrected_constant	2026-11-11 15:04:05.047053+00
328	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:35:00+00	24.8	30.5	426	6.2	14	8	97	27.05	83.89	13	1237	\N	2026-11-09 15:30:00+00	b1000001	1744	1	corrected_constant	2026-11-11 15:04:05.047053+00
329	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:36:00+00	24.8	29.5	405	6.3	10	8	98	28.35	83.59	13.2	1238	\N	2026-11-09 15:31:00+00	b1000001	1804	1	corrected_constant	2026-11-11 15:04:05.047053+00
330	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:37:00+00	24	29.1	411	6.1	12	9	90	\N	\N	13.2	1238	sht_fail	2026-11-09 15:32:00+00	b1000001	1864	9	corrected_constant	2026-11-11 15:04:05.047053+00
331	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:38:00+00	24.4	32.7	420	6	14	10	100	27.78	83.67	13.2	1238	\N	2026-11-09 15:33:00+00	b1000001	1924	1	corrected_constant	2026-11-11 15:04:05.047053+00
332	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:39:00+00	23.4	31.1	408	6.2	14	7	98	27.43	83.44	13.2	1238	\N	2026-11-09 15:34:00+00	b1000001	1984	1	corrected_constant	2026-11-11 15:04:05.047053+00
333	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:40:00+00	24.7	31.4	409	6.2	14	10	94	27.55	79.21	13.2	1238	\N	2026-11-09 15:35:00+00	b1000001	2044	1	corrected_constant	2026-11-11 15:04:05.047053+00
334	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:41:00+00	23.1	32.9	423	6.3	14	10	91	27.38	82.15	13.2	1238	\N	2026-11-09 15:36:00+00	b1000001	2104	1	corrected_constant	2026-11-11 15:04:05.047053+00
335	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:42:00+00	24.9	32.7	407	6	13	7	95	27.27	82.89	13.2	1238	\N	2026-11-09 15:37:00+00	b1000001	2164	1	corrected_constant	2026-11-11 15:04:05.047053+00
336	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:43:00+00	23.4	31.5	406	6	10	6	93	26.71	78.07	13.2	1238	\N	2026-11-09 15:38:00+00	b1000001	2224	1	corrected_constant	2026-11-11 15:04:05.047053+00
337	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:44:00+00	24	31	427	5.9	14	10	94	\N	\N	13.2	1238	sht_fail	2026-11-09 15:39:00+00	b1000001	2284	9	corrected_constant	2026-11-11 15:04:05.047053+00
338	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:45:00+00	24.7	31.5	424	6	14	7	98	26.83	81.26	13.2	1238	\N	2026-11-09 15:40:00+00	b1000001	2344	1	corrected_constant	2026-11-11 15:04:05.047053+00
339	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:46:00+00	24.3	30.4	401	6	12	7	93	27.96	79.17	13.2	1238	\N	2026-11-09 15:41:00+00	b1000001	2404	1	corrected_constant	2026-11-11 15:04:05.047053+00
340	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:47:00+00	23.2	30.6	417	6.2	13	10	92	26.8	81.77	13.2	1238	\N	2026-11-09 15:42:00+00	b1000001	2464	1	corrected_constant	2026-11-11 15:04:05.047053+00
341	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:48:00+00	23.7	32.3	413	5.9	14	8	98	28.4	83	13.4	1239	\N	2026-11-09 15:43:00+00	b1000001	2524	1	corrected_constant	2026-11-11 15:04:05.047053+00
342	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:49:00+00	24.5	31.5	426	6.1	11	7	91	26.81	83.04	13.4	1239	\N	2026-11-09 15:44:00+00	b1000001	2584	1	corrected_constant	2026-11-11 15:04:05.047053+00
343	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:50:00+00	23.1	32.8	419	5.9	10	8	96	27.33	81.09	13.6	1240	\N	2026-11-09 15:45:00+00	b1000001	2644	1	corrected_constant	2026-11-11 15:04:05.047053+00
344	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:51:00+00	24.4	32.4	401	6.1	12	8	96	28.24	81.63	13.6	1240	\N	2026-11-09 15:46:00+00	b1000001	2704	1	corrected_constant	2026-11-11 15:04:05.047053+00
345	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:52:00+00	23.2	32.4	430	6.3	14	10	93	27.41	83.9	13.6	1240	\N	2026-11-09 15:47:00+00	b1000001	2764	1	corrected_constant	2026-11-11 15:04:05.047053+00
346	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:53:00+00	24.5	32.1	415	6	12	10	95	27.93	82.59	13.6	1240	\N	2026-11-09 15:48:00+00	b1000001	2824	1	corrected_constant	2026-11-11 15:04:05.047053+00
347	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:54:00+00	23.7	30.9	390	6.3	14	6	93	26.95	83.77	13.6	1240	\N	2026-11-09 15:49:00+00	b1000001	2884	1	corrected_constant	2026-11-11 15:04:05.047053+00
348	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:55:00+00	23.4	29.3	422	6.3	11	6	96	28.36	78.14	13.6	1240	\N	2026-11-09 15:50:00+00	b1000001	2944	1	corrected_constant	2026-11-11 15:04:05.047053+00
349	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:56:00+00	23.8	29.2	402	6.2	10	6	94	26.9	83.43	13.6	1240	\N	2026-11-09 15:51:00+00	b1000001	3004	1	corrected_constant	2026-11-11 15:04:05.047053+00
350	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:57:00+00	24.1	33	430	6.1	10	10	99	27.74	83.73	13.6	1240	\N	2026-11-09 15:52:00+00	b1000001	3064	1	corrected_constant	2026-11-11 15:04:05.047053+00
351	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:58:00+00	24.9	32.4	424	6.1	10	9	97	27.24	81.16	13.6	1240	\N	2026-11-09 15:53:00+00	b1000001	3124	1	corrected_constant	2026-11-11 15:04:05.047053+00
352	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 15:59:00+00	24.3	31.2	408	6.2	12	6	90	27.94	81.51	13.6	1240	\N	2026-11-09 15:54:00+00	b1000001	3184	1	corrected_constant	2026-11-11 15:04:05.047053+00
353	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:00:00+00	23.1	30.3	415	5.9	12	6	93	27.26	80.87	13.6	1240	\N	2026-11-09 15:55:00+00	b1000001	3244	1	corrected_constant	2026-11-11 15:04:05.047053+00
354	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:01:00+00	24.9	31.9	419	6	11	10	91	26.5	80.5	13.6	1240	\N	2026-11-09 15:56:00+00	b1000001	3304	1	corrected_constant	2026-11-11 15:04:05.047053+00
355	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:02:00+00	23.3	30.5	398	6.2	13	10	94	27.68	82.09	13.6	1240	\N	2026-11-09 15:57:00+00	b1000001	3364	1	corrected_constant	2026-11-11 15:04:05.047053+00
356	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:03:00+00	23.3	30.2	398	6	10	10	94	27.97	81.75	13.6	1240	\N	2026-11-09 15:58:00+00	b1000001	3424	1	corrected_constant	2026-11-11 15:04:05.047053+00
357	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:04:00+00	24.1	31.4	430	6	11	7	93	27.4	81.92	13.6	1240	\N	2026-11-09 15:59:00+00	b1000001	3484	1	corrected_constant	2026-11-11 15:04:05.047053+00
358	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:05:00+00	23	30	391	6.1	10	7	98	26.96	82.53	13.6	1240	\N	2026-11-09 16:00:00+00	b1000001	3544	1	corrected_constant	2026-11-11 15:04:05.047053+00
359	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:06:00+00	25	30.9	412	6	12	9	92	28.08	78.45	13.6	1240	\N	2026-11-09 16:01:00+00	b1000001	3604	1	corrected_constant	2026-11-11 15:04:05.047053+00
360	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:07:00+00	24.5	29.9	417	6.2	13	7	95	26.71	83.02	13.6	1240	\N	2026-11-09 16:02:00+00	b1000001	3664	1	corrected_constant	2026-11-11 15:04:05.047053+00
361	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:08:00+00	24.7	29.7	413	6.1	13	8	91	27.49	80.59	13.6	1240	\N	2026-11-09 16:03:00+00	b1000001	3724	1	corrected_constant	2026-11-11 15:04:05.047053+00
362	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:09:00+00	24.6	29	409	6	14	6	94	27.39	82.58	13.6	1240	\N	2026-11-09 16:04:00+00	b1000001	3784	1	corrected_constant	2026-11-11 15:04:05.047053+00
363	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:10:00+00	24.3	30.3	397	6	13	10	99	28.24	83.64	13.6	1240	\N	2026-11-09 16:05:00+00	b1000001	3844	1	corrected_constant	2026-11-11 15:04:05.047053+00
364	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:11:00+00	23.6	30.3	415	6.3	14	7	91	27.12	80.19	13.6	1240	\N	2026-11-09 16:06:00+00	b1000001	3904	1	corrected_constant	2026-11-11 15:04:05.047053+00
365	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:12:00+00	23.4	31.3	414	6.1	14	10	92	26.75	82.55	13.8	1241	\N	2026-11-09 16:07:00+00	b1000001	3964	1	corrected_constant	2026-11-11 15:04:05.047053+00
366	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:13:00+00	24	31.2	426	6	10	9	91	27.56	79.83	13.8	1241	\N	2026-11-09 16:08:00+00	b1000001	4024	1	corrected_constant	2026-11-11 15:04:05.047053+00
367	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:14:00+00	23.2	30.3	391	6.2	11	6	100	27.24	82.27	13.8	1241	\N	2026-11-09 16:09:00+00	b1000001	4084	1	corrected_constant	2026-11-11 15:04:05.047053+00
368	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:15:00+00	23.9	30.4	411	6.2	13	9	98	\N	\N	13.8	1241	sht_fail	2026-11-09 16:10:00+00	b1000001	4144	9	corrected_constant	2026-11-11 15:04:05.047053+00
369	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:16:00+00	25	30.4	390	6.2	10	9	98	27.68	81.14	13.8	1241	\N	2026-11-09 16:11:00+00	b1000001	4204	1	corrected_constant	2026-11-11 15:04:05.047053+00
370	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:17:00+00	23.8	29.6	400	6.3	13	7	95	26.81	80.55	13.8	1241	\N	2026-11-09 16:12:00+00	b1000001	4264	1	corrected_constant	2026-11-11 15:04:05.047053+00
371	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:18:00+00	23.6	29.5	399	6.2	11	6	97	26.43	80.89	13.8	1241	\N	2026-11-09 16:13:00+00	b1000001	4324	1	corrected_constant	2026-11-11 15:04:05.047053+00
372	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:19:00+00	23.7	31.4	428	6.2	14	10	93	27.28	83.37	13.8	1241	\N	2026-11-09 16:14:00+00	b1000001	4384	1	corrected_constant	2026-11-11 15:04:05.047053+00
373	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:20:00+00	24.3	32.8	425	6.1	12	9	96	28.23	80.05	13.8	1241	\N	2026-11-09 16:15:00+00	b1000001	4444	1	corrected_constant	2026-11-11 15:04:05.047053+00
374	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:21:00+00	23.4	29.2	398	6.2	13	10	98	27.95	82.73	13.8	1241	\N	2026-11-09 16:16:00+00	b1000001	4504	1	corrected_constant	2026-11-11 15:04:05.047053+00
375	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:22:00+00	24.7	32.6	418	6.2	13	10	92	27.23	82.63	13.8	1241	\N	2026-11-09 16:17:00+00	b1000001	4564	1	corrected_constant	2026-11-11 15:04:05.047053+00
376	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:23:00+00	23.3	32	429	6	14	6	92	27.54	79.07	13.8	1241	\N	2026-11-09 16:18:00+00	b1000001	4624	1	corrected_constant	2026-11-11 15:04:05.047053+00
377	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:24:00+00	23.3	30.4	429	6.2	10	9	97	26.57	82.49	14	1242	\N	2026-11-09 16:19:00+00	b1000001	4684	1	corrected_constant	2026-11-11 15:04:05.047053+00
378	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:25:00+00	23.4	29.8	395	6.2	13	7	90	27.49	81.15	14	1242	\N	2026-11-09 16:20:00+00	b1000001	4744	1	corrected_constant	2026-11-11 15:04:05.047053+00
379	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:26:00+00	23.6	29.3	409	6.3	10	8	91	27.77	78.63	14	1242	\N	2026-11-09 16:21:00+00	b1000001	4804	1	corrected_constant	2026-11-11 15:04:05.047053+00
381	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:28:00+00	23.4	31.5	408	6.2	14	8	95	27.91	81.33	14	1242	\N	2026-11-09 16:23:00+00	b1000001	4924	1	corrected_constant	2026-11-11 15:04:05.047053+00
382	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:29:00+00	23.2	30.2	407	6.1	12	9	96	26.58	78.84	14	1242	\N	2026-11-09 16:24:00+00	b1000001	4984	1	corrected_constant	2026-11-11 15:04:05.047053+00
383	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:30:00+00	23.4	30.6	419	6.1	10	6	93	26.46	83.92	14	1242	\N	2026-11-09 16:25:00+00	b1000001	5044	1	corrected_constant	2026-11-11 15:04:05.047053+00
384	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:31:00+00	\N	\N	\N	\N	\N	\N	\N	27.06	80.47	14	1242	soil_fail	2026-11-09 16:26:00+00	b1000001	5104	5	corrected_constant	2026-11-11 15:04:05.047053+00
385	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:32:00+00	25	32.2	428	6.1	12	8	93	27.08	81.9	14	1242	\N	2026-11-09 16:27:00+00	b1000001	5164	1	corrected_constant	2026-11-11 15:04:05.047053+00
386	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:33:00+00	24.6	32.3	429	6.2	12	10	94	27.5	80.12	14	1242	\N	2026-11-09 16:28:00+00	b1000001	5224	1	corrected_constant	2026-11-11 15:04:05.047053+00
387	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:34:00+00	25	31.1	402	6.1	10	7	91	26.67	80.87	14	1242	\N	2026-11-09 16:29:00+00	b1000001	5284	1	corrected_constant	2026-11-11 15:04:05.047053+00
388	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:35:00+00	24.7	30.1	397	6.1	11	7	99	27.49	81.36	14	1242	\N	2026-11-09 16:30:00+00	b1000001	5344	1	corrected_constant	2026-11-11 15:04:05.047053+00
389	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:36:00+00	25	32.3	428	6	10	8	100	28.19	79.45	14	1242	\N	2026-11-09 16:31:00+00	b1000001	5404	1	corrected_constant	2026-11-11 15:04:05.047053+00
390	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:37:00+00	24.1	29.3	392	6.1	11	8	100	28.09	83.44	14	1242	\N	2026-11-09 16:32:00+00	b1000001	5464	1	corrected_constant	2026-11-11 15:04:05.047053+00
391	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:38:00+00	23.3	30.6	392	6	13	6	99	27.21	80.02	14	1242	\N	2026-11-09 16:33:00+00	b1000001	5524	1	corrected_constant	2026-11-11 15:04:05.047053+00
392	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:39:00+00	23.1	32.1	399	6.1	13	10	91	27.34	80.47	14	1242	\N	2026-11-09 16:34:00+00	b1000001	5584	1	corrected_constant	2026-11-11 15:04:05.047053+00
393	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:40:00+00	24.5	30.9	419	6.2	13	9	91	27.53	83.43	14	1242	\N	2026-11-09 16:35:00+00	b1000001	5644	1	corrected_constant	2026-11-11 15:04:05.047053+00
394	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:41:00+00	24.8	30.3	393	6	14	9	96	27.6	82.51	14	1242	\N	2026-11-09 16:36:00+00	b1000001	5704	1	corrected_constant	2026-11-11 15:04:05.047053+00
395	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:42:00+00	23.2	30.8	422	6.2	10	9	91	27.45	79.43	14	1242	\N	2026-11-09 16:37:00+00	b1000001	5764	1	corrected_constant	2026-11-11 15:04:05.047053+00
396	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:43:00+00	23.1	32.6	413	6.2	13	10	92	26.84	82.48	14	1242	\N	2026-11-09 16:38:00+00	b1000001	5824	1	corrected_constant	2026-11-11 15:04:05.047053+00
397	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:44:00+00	24.6	29.5	424	6.1	13	6	94	26.89	79.8	14	1242	\N	2026-11-09 16:39:00+00	b1000001	5884	1	corrected_constant	2026-11-11 15:04:05.047053+00
398	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:45:00+00	24.6	30.6	412	6.2	11	6	94	26.46	83.39	14	1242	\N	2026-11-09 16:40:00+00	b1000001	5944	1	corrected_constant	2026-11-11 15:04:05.047053+00
399	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:46:00+00	25	30.9	403	6	10	7	95	28.08	80.12	14	1242	\N	2026-11-09 16:41:00+00	b1000001	6004	1	corrected_constant	2026-11-11 15:04:05.047053+00
400	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:47:00+00	25	29.8	430	6	10	6	94	27.85	79.88	14	1242	\N	2026-11-09 16:42:00+00	b1000001	6064	1	corrected_constant	2026-11-11 15:04:05.047053+00
401	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:48:00+00	23.3	31.8	418	6.1	11	7	94	26.64	82.15	14	1242	\N	2026-11-09 16:43:00+00	b1000001	6124	1	corrected_constant	2026-11-11 15:04:05.047053+00
402	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:08:00+00	23.6	31.9	415	6	14	8	93	26.61	80.22	14.2	1243	\N	2026-11-09 17:03:00+00	b1000001	7324	1	corrected_constant	2026-11-11 15:04:05.064408+00
403	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:07:00+00	23.1	30.2	417	6.1	11	10	98	26.92	82.35	14.2	1243	\N	2026-11-09 17:02:00+00	b1000001	7264	1	corrected_constant	2026-11-11 15:04:05.064408+00
404	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:06:00+00	\N	\N	\N	\N	\N	\N	\N	27.19	79.43	14.2	1243	soil_fail	2026-11-09 17:01:00+00	b1000001	7204	5	corrected_constant	2026-11-11 15:04:05.064408+00
405	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:05:00+00	\N	\N	\N	\N	\N	\N	\N	27.85	83.44	14.2	1243	soil_fail	2026-11-09 17:00:00+00	b1000001	7144	5	corrected_constant	2026-11-11 15:04:05.064408+00
406	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:04:00+00	23.8	29.2	407	6	12	10	90	27.44	82.45	14.2	1243	\N	2026-11-09 16:59:00+00	b1000001	7084	1	corrected_constant	2026-11-11 15:04:05.064408+00
407	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:03:00+00	23.3	29.8	403	6.1	12	9	97	27.38	81.76	14.2	1243	\N	2026-11-09 16:58:00+00	b1000001	7024	1	corrected_constant	2026-11-11 15:04:05.064408+00
408	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:02:00+00	24.8	29.7	415	6.3	11	9	96	27.96	79.29	14.2	1243	\N	2026-11-09 16:57:00+00	b1000001	6964	1	corrected_constant	2026-11-11 15:04:05.064408+00
409	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:01:00+00	24.9	32.7	403	5.9	13	10	100	28.39	82.42	14.2	1243	\N	2026-11-09 16:56:00+00	b1000001	6904	1	corrected_constant	2026-11-11 15:04:05.064408+00
410	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 17:00:00+00	24.4	32.9	429	6	12	6	98	28.11	80.51	14.2	1243	\N	2026-11-09 16:55:00+00	b1000001	6844	1	corrected_constant	2026-11-11 15:04:05.064408+00
411	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:59:00+00	25	29	416	6.3	11	6	96	27.51	80.83	14.2	1243	\N	2026-11-09 16:54:00+00	b1000001	6784	1	corrected_constant	2026-11-11 15:04:05.064408+00
412	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:58:00+00	23.1	30.6	413	6.2	10	7	97	27.91	81.6	14.2	1243	\N	2026-11-09 16:53:00+00	b1000001	6724	1	corrected_constant	2026-11-11 15:04:05.064408+00
413	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:57:00+00	24.6	32.1	421	5.9	14	7	96	26.91	78.96	14.2	1243	\N	2026-11-09 16:52:00+00	b1000001	6664	1	corrected_constant	2026-11-11 15:04:05.064408+00
414	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:56:00+00	23.2	29.7	430	6.1	11	10	92	26.51	80.55	14.2	1243	\N	2026-11-09 16:51:00+00	b1000001	6604	1	corrected_constant	2026-11-11 15:04:05.064408+00
415	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:55:00+00	23.9	32.5	410	6	10	10	97	28.01	81.02	14.2	1243	\N	2026-11-09 16:50:00+00	b1000001	6544	1	corrected_constant	2026-11-11 15:04:05.064408+00
416	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:54:00+00	24.5	32.1	405	6	14	7	99	27.61	79.57	14	1242	\N	2026-11-09 16:49:00+00	b1000001	6484	1	corrected_constant	2026-11-11 15:04:05.064408+00
417	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:53:00+00	24.7	31.5	423	6.2	14	7	99	27.96	78.99	14	1242	\N	2026-11-09 16:48:00+00	b1000001	6424	1	corrected_constant	2026-11-11 15:04:05.064408+00
418	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:52:00+00	24.5	30.5	421	5.9	10	10	100	\N	\N	14	1242	sht_fail	2026-11-09 16:47:00+00	b1000001	6364	9	corrected_constant	2026-11-11 15:04:05.064408+00
419	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:51:00+00	24.1	29.7	402	6	12	10	90	\N	\N	14	1242	sht_fail	2026-11-09 16:46:00+00	b1000001	6304	9	corrected_constant	2026-11-11 15:04:05.064408+00
420	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:50:00+00	24.3	30.9	394	6.1	14	6	98	28.21	78.04	14	1242	\N	2026-11-09 16:45:00+00	b1000001	6244	1	corrected_constant	2026-11-11 15:04:05.064408+00
421	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-09 16:49:00+00	23.6	30.1	423	6.3	14	10	93	28.35	83.37	14	1242	\N	2026-11-09 16:44:00+00	b1000001	6184	1	corrected_constant	2026-11-11 15:04:05.064408+00
422	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:42:22.842324+00	23.1	30.8	424	6.2	13	10	96	28.38	83.39	13.4	1239	\N	2026-11-10 16:43:00+00	b1000002	6124	0	corrected_linear	2026-11-11 15:04:05.196712+00
423	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:41:23.215768+00	23.1	30.4	416	6.1	10	10	97	28.4	80.6	13.4	1239	\N	2026-11-10 16:42:00+00	b1000002	6064	0	corrected_linear	2026-11-11 15:04:05.196712+00
424	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:40:23.589212+00	24.5	29.1	390	6.2	12	10	93	27.42	80.03	13.4	1239	\N	2026-11-10 16:41:00+00	b1000002	6004	0	corrected_linear	2026-11-11 15:04:05.196712+00
425	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:39:23.962656+00	23.2	31.1	404	6.3	10	6	97	28.14	82.84	13.4	1239	\N	2026-11-10 16:40:00+00	b1000002	5944	0	corrected_linear	2026-11-11 15:04:05.196712+00
426	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:38:24.3361+00	23.5	31.7	427	6.3	10	9	96	27.08	78.19	13.4	1239	\N	2026-11-10 16:39:00+00	b1000002	5884	0	corrected_linear	2026-11-11 15:04:05.196712+00
427	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:37:24.709544+00	24.1	30.5	405	6.3	14	9	94	27.86	83.58	13.2	1238	\N	2026-11-10 16:38:00+00	b1000002	5824	0	corrected_linear	2026-11-11 15:04:05.196712+00
428	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:36:25.082988+00	24.2	31.6	425	5.9	13	6	96	27.36	78.19	13.2	1238	\N	2026-11-10 16:37:00+00	b1000002	5764	0	corrected_linear	2026-11-11 15:04:05.196712+00
429	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:35:25.456432+00	23.9	32.9	406	6.2	11	9	97	26.96	80.67	13.2	1238	\N	2026-11-10 16:36:00+00	b1000002	5704	0	corrected_linear	2026-11-11 15:04:05.196712+00
430	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:34:25.829876+00	24	30.7	398	6.3	14	8	98	27.21	78.52	13.2	1238	\N	2026-11-10 16:35:00+00	b1000002	5644	0	corrected_linear	2026-11-11 15:04:05.196712+00
431	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:33:26.20332+00	23.9	30.4	422	6.2	13	10	95	28.01	78.86	13.2	1238	\N	2026-11-10 16:34:00+00	b1000002	5584	0	corrected_linear	2026-11-11 15:04:05.196712+00
432	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:32:26.576763+00	24	30.5	413	6.1	12	10	95	27.63	81.14	13.2	1238	\N	2026-11-10 16:33:00+00	b1000002	5524	0	corrected_linear	2026-11-11 15:04:05.196712+00
433	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:31:26.950207+00	25	29.7	420	6.2	14	6	94	27.49	78.83	13.2	1238	\N	2026-11-10 16:32:00+00	b1000002	5464	0	corrected_linear	2026-11-11 15:04:05.196712+00
434	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:30:27.323651+00	24	29.9	428	6.1	10	6	99	28.15	81.62	13.2	1238	\N	2026-11-10 16:31:00+00	b1000002	5404	0	corrected_linear	2026-11-11 15:04:05.196712+00
435	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:29:27.697095+00	24.1	31.9	405	6	12	9	94	27.39	79.62	13.2	1238	\N	2026-11-10 16:30:00+00	b1000002	5344	0	corrected_linear	2026-11-11 15:04:05.196712+00
436	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:28:28.070539+00	23.2	30.7	425	6.2	11	8	96	26.81	83.7	13.2	1238	\N	2026-11-10 16:29:00+00	b1000002	5284	0	corrected_linear	2026-11-11 15:04:05.196712+00
437	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:27:28.443983+00	25	29.3	404	5.9	11	7	99	27.24	79.87	13.2	1238	\N	2026-11-10 16:28:00+00	b1000002	5224	0	corrected_linear	2026-11-11 15:04:05.196712+00
438	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:26:28.817427+00	24.1	32.4	410	5.9	12	9	92	28.26	82.65	13.2	1238	\N	2026-11-10 16:27:00+00	b1000002	5164	0	corrected_linear	2026-11-11 15:04:05.196712+00
439	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:25:29.190871+00	24.6	30.5	426	6.1	10	6	97	27.12	82.61	13.2	1238	\N	2026-11-10 16:26:00+00	b1000002	5104	0	corrected_linear	2026-11-11 15:04:05.196712+00
440	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:24:29.564315+00	24.2	30.9	412	5.9	10	7	94	27.58	81.74	13.2	1238	\N	2026-11-10 16:25:00+00	b1000002	5044	0	corrected_linear	2026-11-11 15:04:05.196712+00
441	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:23:29.937759+00	23.1	30.6	391	6.1	12	8	93	26.7	78.06	13.2	1238	\N	2026-11-10 16:24:00+00	b1000002	4984	0	corrected_linear	2026-11-11 15:04:05.196712+00
442	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:22:30.311203+00	24.4	29.6	420	6.1	12	8	90	26.81	82.14	13.2	1238	\N	2026-11-10 16:23:00+00	b1000002	4924	0	corrected_linear	2026-11-11 15:04:05.196712+00
443	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:21:30.684647+00	23.1	32.1	399	6.1	13	8	91	27.41	81.6	13.2	1238	\N	2026-11-10 16:22:00+00	b1000002	4864	0	corrected_linear	2026-11-11 15:04:05.196712+00
444	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:20:31.058091+00	23.6	29.4	400	6	13	10	97	28.15	83.84	13.2	1238	\N	2026-11-10 16:21:00+00	b1000002	4804	0	corrected_linear	2026-11-11 15:04:05.196712+00
445	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:19:31.431535+00	23.1	30.4	402	6.3	10	8	100	28.25	81.3	13.2	1238	\N	2026-11-10 16:20:00+00	b1000002	4744	0	corrected_linear	2026-11-11 15:04:05.196712+00
446	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:18:31.804979+00	24.5	31.1	393	5.9	10	9	96	27.28	83.66	13.2	1238	\N	2026-11-10 16:19:00+00	b1000002	4684	0	corrected_linear	2026-11-11 15:04:05.196712+00
447	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:17:32.178423+00	24.3	30.8	394	6.2	10	6	100	27.72	81.14	13.2	1238	\N	2026-11-10 16:18:00+00	b1000002	4624	0	corrected_linear	2026-11-11 15:04:05.196712+00
448	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:16:32.551867+00	23.3	30.8	401	5.9	14	6	93	27.98	79.54	13	1237	\N	2026-11-10 16:17:00+00	b1000002	4564	0	corrected_linear	2026-11-11 15:04:05.196712+00
449	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:15:32.925311+00	24.3	32.5	428	6.2	13	7	92	28.22	83.35	13	1237	\N	2026-11-10 16:16:00+00	b1000002	4504	0	corrected_linear	2026-11-11 15:04:05.196712+00
450	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:14:33.298755+00	\N	\N	\N	\N	\N	\N	\N	28.05	82.97	13	1237	soil_fail	2026-11-10 16:15:00+00	b1000002	4444	4	corrected_linear	2026-11-11 15:04:05.196712+00
451	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:13:33.672199+00	24.7	31.3	425	6.1	11	7	99	26.42	80.79	13	1237	\N	2026-11-10 16:14:00+00	b1000002	4384	0	corrected_linear	2026-11-11 15:04:05.196712+00
452	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:12:34.045643+00	24.7	29.2	396	6.3	10	9	100	28.33	82.67	13	1237	\N	2026-11-10 16:13:00+00	b1000002	4324	0	corrected_linear	2026-11-11 15:04:05.196712+00
453	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:11:34.419087+00	23.1	30.9	393	6.1	11	8	90	28.3	78.99	13	1237	\N	2026-11-10 16:12:00+00	b1000002	4264	0	corrected_linear	2026-11-11 15:04:05.196712+00
454	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:10:34.792531+00	24.1	32.4	401	6	11	9	95	27.25	79.12	13	1237	\N	2026-11-10 16:11:00+00	b1000002	4204	0	corrected_linear	2026-11-11 15:04:05.196712+00
455	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:09:35.165975+00	24.4	29.6	413	6.1	10	8	93	26.74	80.61	13	1237	\N	2026-11-10 16:10:00+00	b1000002	4144	0	corrected_linear	2026-11-11 15:04:05.196712+00
456	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:08:35.539419+00	23.8	30.1	393	6.1	11	10	90	27.88	79.36	13	1237	\N	2026-11-10 16:09:00+00	b1000002	4084	0	corrected_linear	2026-11-11 15:04:05.196712+00
457	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:07:35.912863+00	23.1	29.5	429	6	13	6	95	27.32	80.13	13	1237	\N	2026-11-10 16:08:00+00	b1000002	4024	0	corrected_linear	2026-11-11 15:04:05.196712+00
458	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:06:36.286307+00	23.6	31.9	393	5.9	11	8	97	27.18	79.88	13	1237	\N	2026-11-10 16:07:00+00	b1000002	3964	0	corrected_linear	2026-11-11 15:04:05.196712+00
459	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:05:36.659751+00	24.7	32.2	414	6.2	10	7	99	27.29	82.13	13	1237	\N	2026-11-10 16:06:00+00	b1000002	3904	0	corrected_linear	2026-11-11 15:04:05.196712+00
460	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:04:37.033195+00	24.8	30	420	6.1	10	6	91	27.2	78.95	13	1237	\N	2026-11-10 16:05:00+00	b1000002	3844	0	corrected_linear	2026-11-11 15:04:05.196712+00
461	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:03:37.406639+00	24.5	32.5	417	6.2	13	8	94	28.23	83.99	13	1237	\N	2026-11-10 16:04:00+00	b1000002	3784	0	corrected_linear	2026-11-11 15:04:05.196712+00
462	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:02:37.780083+00	23	29.4	390	6	12	8	94	27.84	78.71	13	1237	\N	2026-11-10 16:03:00+00	b1000002	3724	0	corrected_linear	2026-11-11 15:04:05.196712+00
463	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:01:38.153527+00	24.8	32.4	424	6.2	14	7	94	26.54	78.98	13	1237	\N	2026-11-10 16:02:00+00	b1000002	3664	0	corrected_linear	2026-11-11 15:04:05.196712+00
464	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:00:38.526971+00	24.7	29.7	393	6.2	10	6	91	27.87	78.84	13	1237	\N	2026-11-10 16:01:00+00	b1000002	3604	0	corrected_linear	2026-11-11 15:04:05.196712+00
465	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:59:38.900415+00	23.3	30.1	424	6.3	10	9	99	26.48	82.99	13	1237	\N	2026-11-10 16:00:00+00	b1000002	3544	0	corrected_linear	2026-11-11 15:04:05.196712+00
466	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:58:39.273859+00	24.1	29.6	421	6.2	11	8	98	27.5	79.49	13	1237	\N	2026-11-10 15:59:00+00	b1000002	3484	0	corrected_linear	2026-11-11 15:04:05.196712+00
467	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:57:39.647303+00	23.6	31.3	400	5.9	13	9	92	26.72	78.53	13	1237	\N	2026-11-10 15:58:00+00	b1000002	3424	0	corrected_linear	2026-11-11 15:04:05.196712+00
468	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:56:40.020747+00	24.4	31.1	417	6.2	11	7	99	27.7	81.9	13	1237	\N	2026-11-10 15:57:00+00	b1000002	3364	0	corrected_linear	2026-11-11 15:04:05.196712+00
469	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:55:40.394191+00	23.3	30.9	418	6.3	10	7	100	27.22	79.05	13	1237	\N	2026-11-10 15:56:00+00	b1000002	3304	0	corrected_linear	2026-11-11 15:04:05.196712+00
470	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:54:40.767635+00	24.3	31	400	6.1	13	10	96	27.81	83.91	13	1237	\N	2026-11-10 15:55:00+00	b1000002	3244	0	corrected_linear	2026-11-11 15:04:05.196712+00
471	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:53:41.141079+00	24.6	30.7	413	6	10	8	100	27.78	83.41	13	1237	\N	2026-11-10 15:54:00+00	b1000002	3184	0	corrected_linear	2026-11-11 15:04:05.196712+00
472	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:52:41.514523+00	23.5	31.2	403	6.3	10	6	99	26.75	80.58	13	1237	\N	2026-11-10 15:53:00+00	b1000002	3124	0	corrected_linear	2026-11-11 15:04:05.196712+00
473	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:51:41.887967+00	24.1	31.2	423	6.1	14	6	94	27.65	81.36	13	1237	\N	2026-11-10 15:52:00+00	b1000002	3064	0	corrected_linear	2026-11-11 15:04:05.196712+00
474	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:50:42.261411+00	23	30.7	417	6	10	10	95	27.12	78.56	13	1237	\N	2026-11-10 15:51:00+00	b1000002	3004	0	corrected_linear	2026-11-11 15:04:05.196712+00
475	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:49:42.634855+00	24.8	30.4	404	6.2	10	7	94	27.32	80.73	13	1237	\N	2026-11-10 15:50:00+00	b1000002	2944	0	corrected_linear	2026-11-11 15:04:05.196712+00
476	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:48:43.008299+00	23.2	29.5	392	5.9	11	6	99	26.7	82.72	13	1237	\N	2026-11-10 15:49:00+00	b1000002	2884	0	corrected_linear	2026-11-11 15:04:05.196712+00
477	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:47:43.381743+00	23.4	30.6	422	6.2	14	6	100	27.75	83.22	13	1237	\N	2026-11-10 15:48:00+00	b1000002	2824	0	corrected_linear	2026-11-11 15:04:05.196712+00
478	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:46:43.755187+00	24.5	30.6	390	6.2	12	9	92	26.45	82.78	13	1237	\N	2026-11-10 15:47:00+00	b1000002	2764	0	corrected_linear	2026-11-11 15:04:05.196712+00
479	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:45:44.128631+00	23.9	29.1	421	6.1	13	6	91	27.49	83.46	13	1237	\N	2026-11-10 15:46:00+00	b1000002	2704	0	corrected_linear	2026-11-11 15:04:05.196712+00
480	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:44:44.502075+00	23.2	30	392	6.1	13	6	97	27.63	79.11	13	1237	\N	2026-11-10 15:45:00+00	b1000002	2644	0	corrected_linear	2026-11-11 15:04:05.196712+00
481	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:43:44.875519+00	23.2	29.8	404	6.1	14	8	98	28.04	82.71	13	1237	\N	2026-11-10 15:44:00+00	b1000002	2584	0	corrected_linear	2026-11-11 15:04:05.196712+00
482	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:42:45.248963+00	24.7	29.6	418	5.9	12	7	92	26.82	82.68	13	1237	\N	2026-11-10 15:43:00+00	b1000002	2524	0	corrected_linear	2026-11-11 15:04:05.196712+00
483	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:41:45.622407+00	23	32.6	408	6.1	12	9	92	27.78	81.12	13	1237	\N	2026-11-10 15:42:00+00	b1000002	2464	0	corrected_linear	2026-11-11 15:04:05.196712+00
484	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:40:45.995851+00	24.5	30	423	6.2	13	10	100	27.72	81.7	13	1237	\N	2026-11-10 15:41:00+00	b1000002	2404	0	corrected_linear	2026-11-11 15:04:05.196712+00
485	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:39:46.369295+00	24.3	31.4	420	6.2	12	9	92	28.27	80.35	13	1237	\N	2026-11-10 15:40:00+00	b1000002	2344	0	corrected_linear	2026-11-11 15:04:05.196712+00
486	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:38:46.742739+00	23.3	30.9	395	6.2	11	9	93	26.97	83.05	13	1237	\N	2026-11-10 15:39:00+00	b1000002	2284	0	corrected_linear	2026-11-11 15:04:05.196712+00
487	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:37:47.116183+00	23.7	32.8	408	6	13	6	98	27.06	81.22	13	1237	\N	2026-11-10 15:38:00+00	b1000002	2224	0	corrected_linear	2026-11-11 15:04:05.196712+00
488	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:36:47.489627+00	23.7	32.6	411	6.3	14	9	91	26.75	80.4	13	1237	\N	2026-11-10 15:37:00+00	b1000002	2164	0	corrected_linear	2026-11-11 15:04:05.196712+00
489	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:35:47.863071+00	23.5	30.7	396	5.9	14	9	92	27.13	78.94	13	1237	\N	2026-11-10 15:36:00+00	b1000002	2104	0	corrected_linear	2026-11-11 15:04:05.196712+00
490	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:34:48.236515+00	24.2	31.1	413	5.9	12	9	94	27.62	78.76	13	1237	\N	2026-11-10 15:35:00+00	b1000002	2044	0	corrected_linear	2026-11-11 15:04:05.196712+00
491	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:33:48.609959+00	23.5	30.9	411	6.2	12	8	99	27.16	83.17	13	1237	\N	2026-11-10 15:34:00+00	b1000002	1984	0	corrected_linear	2026-11-11 15:04:05.196712+00
492	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:32:48.983402+00	23.5	29.3	428	6	10	8	92	27	83.54	13	1237	\N	2026-11-10 15:33:00+00	b1000002	1924	0	corrected_linear	2026-11-11 15:04:05.196712+00
493	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:31:49.356846+00	24.5	31.6	391	6.1	14	9	100	26.81	82.54	12.8	1236	\N	2026-11-10 15:32:00+00	b1000002	1864	0	corrected_linear	2026-11-11 15:04:05.196712+00
494	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:30:49.73029+00	24.8	30.4	404	5.9	10	6	90	28.27	78.19	12.8	1236	\N	2026-11-10 15:31:00+00	b1000002	1804	0	corrected_linear	2026-11-11 15:04:05.196712+00
495	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:29:50.103734+00	23.6	32.7	421	6.2	12	6	100	27.99	81.29	12.8	1236	\N	2026-11-10 15:30:00+00	b1000002	1744	0	corrected_linear	2026-11-11 15:04:05.196712+00
496	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:28:50.477178+00	23	29.5	415	6.1	12	9	95	27.67	80.33	12.8	1236	\N	2026-11-10 15:29:00+00	b1000002	1684	0	corrected_linear	2026-11-11 15:04:05.196712+00
497	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:27:50.850622+00	24.6	32.7	401	6.2	14	6	99	28.22	80.19	12.8	1236	\N	2026-11-10 15:28:00+00	b1000002	1624	0	corrected_linear	2026-11-11 15:04:05.196712+00
498	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:26:51.224066+00	23.7	31.9	409	6.2	12	7	90	27.51	78.26	12.8	1236	\N	2026-11-10 15:27:00+00	b1000002	1564	0	corrected_linear	2026-11-11 15:04:05.196712+00
499	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:25:51.59751+00	23.8	32.2	400	6.2	12	6	94	27.45	78.32	12.8	1236	\N	2026-11-10 15:26:00+00	b1000002	1504	0	corrected_linear	2026-11-11 15:04:05.196712+00
500	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:24:51.970954+00	23.3	31.6	428	6.2	13	9	96	27.64	79.58	12.8	1236	\N	2026-11-10 15:25:00+00	b1000002	1444	0	corrected_linear	2026-11-11 15:04:05.196712+00
501	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:23:52.344398+00	23.3	31	417	6.2	12	9	100	27.6	80.33	12.8	1236	\N	2026-11-10 15:24:00+00	b1000002	1384	0	corrected_linear	2026-11-11 15:04:05.196712+00
502	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:22:52.717842+00	23.2	31.3	409	6	10	8	97	28.19	81.8	12.8	1236	\N	2026-11-10 15:23:00+00	b1000002	1324	0	corrected_linear	2026-11-11 15:04:05.196712+00
503	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:21:53.091286+00	24.4	30.8	393	6.2	11	9	98	27.8	82.75	12.8	1236	\N	2026-11-10 15:22:00+00	b1000002	1264	0	corrected_linear	2026-11-11 15:04:05.196712+00
504	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:20:53.46473+00	23.6	29.8	417	6	14	7	98	28.21	80	12.8	1236	\N	2026-11-10 15:21:00+00	b1000002	1204	0	corrected_linear	2026-11-11 15:04:05.196712+00
505	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:19:53.838174+00	24	30.8	401	5.9	14	8	97	\N	\N	12.8	1236	sht_fail	2026-11-10 15:20:00+00	b1000002	1144	8	corrected_linear	2026-11-11 15:04:05.196712+00
506	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:18:54.211618+00	23.6	31.7	399	6.2	12	8	92	27.92	81.96	12.8	1236	\N	2026-11-10 15:19:00+00	b1000002	1084	0	corrected_linear	2026-11-11 15:04:05.196712+00
507	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:17:54.585062+00	24.9	31.8	424	6.1	14	6	93	27.47	82.2	12.6	1235	\N	2026-11-10 15:18:00+00	b1000002	1024	0	corrected_linear	2026-11-11 15:04:05.196712+00
508	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:16:54.958506+00	23.3	29.1	392	6.3	13	10	93	27.98	80.28	12.6	1235	\N	2026-11-10 15:17:00+00	b1000002	964	0	corrected_linear	2026-11-11 15:04:05.196712+00
509	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:15:55.33195+00	23.8	31.4	415	6.2	14	10	95	28.36	81.83	12.6	1235	\N	2026-11-10 15:16:00+00	b1000002	904	0	corrected_linear	2026-11-11 15:04:05.196712+00
510	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:14:55.705394+00	24.1	30.1	398	6	13	9	90	27.52	81.75	12.6	1235	\N	2026-11-10 15:15:00+00	b1000002	844	0	corrected_linear	2026-11-11 15:04:05.196712+00
511	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:13:56.078838+00	\N	\N	\N	\N	\N	\N	\N	\N	\N	12.6	1235	soil_fail,sht_fail	2026-11-10 15:14:00+00	b1000002	784	12	corrected_linear	2026-11-11 15:04:05.196712+00
512	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:12:56.452282+00	24.9	32.5	407	6.2	11	10	98	27.35	81.76	12.4	1234	\N	2026-11-10 15:13:00+00	b1000002	724	0	corrected_linear	2026-11-11 15:04:05.196712+00
513	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:11:56.825726+00	24.2	32.8	411	6	10	10	90	26.9	78.7	12.4	1234	\N	2026-11-10 15:12:00+00	b1000002	664	0	corrected_linear	2026-11-11 15:04:05.196712+00
514	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:10:57.19917+00	23.4	30.1	420	6.2	13	7	92	27.33	81.29	12.4	1234	\N	2026-11-10 15:11:00+00	b1000002	604	0	corrected_linear	2026-11-11 15:04:05.196712+00
515	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:09:57.572614+00	23.2	31.2	401	5.9	12	6	96	26.95	80.07	12.4	1234	\N	2026-11-10 15:10:00+00	b1000002	544	0	corrected_linear	2026-11-11 15:04:05.196712+00
516	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:08:57.946058+00	23.7	31.3	422	6	13	9	90	27.44	79.33	12.4	1234	\N	2026-11-10 15:09:00+00	b1000002	484	0	corrected_linear	2026-11-11 15:04:05.196712+00
517	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:07:58.319502+00	24.2	31.2	395	6.3	12	8	95	28.13	80.31	12.4	1234	\N	2026-11-10 15:08:00+00	b1000002	424	0	corrected_linear	2026-11-11 15:04:05.196712+00
518	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:06:58.692946+00	24.1	32.5	425	6	10	10	92	27.41	78.5	12.4	1234	\N	2026-11-10 15:07:00+00	b1000002	364	0	corrected_linear	2026-11-11 15:04:05.196712+00
519	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:05:59.06639+00	24.6	29.3	393	6.2	14	7	91	28.38	80.54	12.4	1234	\N	2026-11-10 15:06:00+00	b1000002	304	0	corrected_linear	2026-11-11 15:04:05.196712+00
520	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:04:59.439834+00	24.3	29.6	418	6	12	7	90	27.55	79.2	12.4	1234	\N	2026-11-10 15:05:00+00	b1000002	244	0	corrected_linear	2026-11-11 15:04:05.196712+00
521	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 15:03:59.813278+00	23.9	31.6	412	6	10	8	97	26.95	82.86	12.4	1234	\N	2026-11-10 15:04:00+00	b1000002	184	0	corrected_linear	2026-11-11 15:04:05.196712+00
522	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 17:02:15.373444+00	23.3	32.5	422	6	14	7	97	26.75	79.99	13.4	1239	\N	2026-11-10 17:03:00+00	b1000002	7324	0	corrected_linear	2026-11-11 15:04:05.212255+00
523	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 17:01:15.746888+00	24.5	31.6	390	6	10	8	98	27.55	82.64	13.4	1239	\N	2026-11-10 17:02:00+00	b1000002	7264	0	corrected_linear	2026-11-11 15:04:05.212255+00
524	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 17:00:16.120332+00	24.1	29.5	430	6.3	11	8	96	27.88	80.67	13.4	1239	\N	2026-11-10 17:01:00+00	b1000002	7204	0	corrected_linear	2026-11-11 15:04:05.212255+00
525	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:59:16.493776+00	24.2	30.7	401	6.3	14	7	98	27.18	80.36	13.4	1239	\N	2026-11-10 17:00:00+00	b1000002	7144	0	corrected_linear	2026-11-11 15:04:05.212255+00
526	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:58:16.86722+00	24.4	32.6	408	6.1	14	10	93	26.8	78.97	13.4	1239	\N	2026-11-10 16:59:00+00	b1000002	7084	0	corrected_linear	2026-11-11 15:04:05.212255+00
527	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:57:17.240664+00	\N	\N	\N	\N	\N	\N	\N	27.77	78.62	13.4	1239	soil_fail	2026-11-10 16:58:00+00	b1000002	7024	4	corrected_linear	2026-11-11 15:04:05.212255+00
528	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:56:17.614108+00	23.8	29.6	420	6.2	13	7	100	27.57	83.99	13.4	1239	\N	2026-11-10 16:57:00+00	b1000002	6964	0	corrected_linear	2026-11-11 15:04:05.212255+00
529	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:55:17.987552+00	24.7	30.3	411	6.1	13	7	99	27.61	80.98	13.4	1239	\N	2026-11-10 16:56:00+00	b1000002	6904	0	corrected_linear	2026-11-11 15:04:05.212255+00
530	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:54:18.360996+00	23.6	31	406	6.2	14	8	93	26.61	83.59	13.4	1239	\N	2026-11-10 16:55:00+00	b1000002	6844	0	corrected_linear	2026-11-11 15:04:05.212255+00
531	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:53:18.73444+00	24.1	30.4	416	6.2	10	6	100	28.12	78.69	13.4	1239	\N	2026-11-10 16:54:00+00	b1000002	6784	0	corrected_linear	2026-11-11 15:04:05.212255+00
532	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:52:19.107884+00	23.6	31.9	402	6.1	12	10	100	27.02	83.53	13.4	1239	\N	2026-11-10 16:53:00+00	b1000002	6724	0	corrected_linear	2026-11-11 15:04:05.212255+00
533	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:51:19.481328+00	24.4	29.4	419	6.2	11	6	94	27.31	79.56	13.4	1239	\N	2026-11-10 16:52:00+00	b1000002	6664	0	corrected_linear	2026-11-11 15:04:05.212255+00
534	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:50:19.854772+00	25	30.4	414	6.2	11	9	90	27.54	83.27	13.4	1239	\N	2026-11-10 16:51:00+00	b1000002	6604	0	corrected_linear	2026-11-11 15:04:05.212255+00
535	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:49:20.228216+00	23.1	31	390	6.3	12	7	95	27.55	83.18	13.4	1239	\N	2026-11-10 16:50:00+00	b1000002	6544	0	corrected_linear	2026-11-11 15:04:05.212255+00
536	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:48:20.60166+00	\N	\N	\N	\N	\N	\N	\N	26.62	82.23	13.4	1239	soil_fail	2026-11-10 16:49:00+00	b1000002	6484	4	corrected_linear	2026-11-11 15:04:05.212255+00
537	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:47:20.975104+00	23.2	32.3	409	6.2	10	8	100	26.85	82.23	13.4	1239	\N	2026-11-10 16:48:00+00	b1000002	6424	0	corrected_linear	2026-11-11 15:04:05.212255+00
538	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:46:21.348548+00	24.1	32.8	410	6.1	13	6	98	27.74	81.2	13.4	1239	\N	2026-11-10 16:47:00+00	b1000002	6364	0	corrected_linear	2026-11-11 15:04:05.212255+00
539	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:45:21.721992+00	24.8	29.4	422	6	14	10	97	27.7	81.09	13.4	1239	\N	2026-11-10 16:46:00+00	b1000002	6304	0	corrected_linear	2026-11-11 15:04:05.212255+00
540	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:44:22.095436+00	23.3	30.3	423	6.1	11	8	96	26.44	80.48	13.4	1239	\N	2026-11-10 16:45:00+00	b1000002	6244	0	corrected_linear	2026-11-11 15:04:05.212255+00
541	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-10 16:43:22.46888+00	24.8	32.3	427	6	14	6	95	27.52	78.35	13.4	1239	\N	2026-11-10 16:44:00+00	b1000002	6184	0	corrected_linear	2026-11-11 15:04:05.212255+00
542	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:04:00+00	26.5	80.1	260	3.1	12	18	44	27	80	0	0	\N	2026-11-11 12:04:00+00	c0ffee01	60	0	verified	2026-11-11 15:04:24.642337+00
543	11111111-1111-1111-1111-111111111111	00000000-0000-0000-0000-0000000000b1	2026-11-11 12:05:00+00	26.5	80.2	261	3.1	12	18	44	27.1	79.8	0	0	\N	2026-11-11 12:05:00+00	c0ffee01	120	0	verified	2026-11-11 15:04:24.642337+00
\.


--
-- Data for Name: water_balance_ledger; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.water_balance_ledger (id, plot_id, node_id, period_start, period_end, params_id, eto_mm, eto_source, kc, etc_mm, rain_mm, rain_source, irrigation_mm, dp_mm, dr_start_mm, dr_model_mm, theta_obs_raw, theta_obs_pct, dr_obs_mm, dr_end_mm, corrected, taw_mm, raw_mm, calibration_status, computed_at) FROM stdin;
19	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 09:00:00+00	2026-11-10 10:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.13	open_meteo	1	0.13	0.1	open_meteo	0	0	0.23	0.26	\N	\N	\N	0.26	f	60	24	uncalibrated	2026-11-12 09:05:01.061415+00
21	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 11:00:00+00	2026-11-10 12:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.3	open_meteo	0	0.019999999999999962	0.28	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 11:05:01.068231+00
25	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 15:00:00+00	2026-11-10 16:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	346.36	sensor	0	346.36	0	0	30.7	\N	\N	0	f	60	24	uncalibrated	2026-11-12 15:05:01.231074+00
27	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 17:00:00+00	2026-11-10 18:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 17:05:01.078626+00
240	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 17:00:00+00	2026-11-11 18:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.02	0.03	\N	\N	\N	0.03	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
18	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 08:00:00+00	2026-11-10 09:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.23	open_meteo	1	0.23	0	open_meteo	0	0	0	0.23	\N	\N	\N	0.23	f	60	24	uncalibrated	2026-11-12 08:05:01.11548+00
20	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 10:00:00+00	2026-11-10 11:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.02	open_meteo	1	0.02	0	open_meteo	0	0	0.26	0.28	\N	\N	\N	0.28	f	60	24	uncalibrated	2026-11-12 10:05:01.041029+00
22	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 12:00:00+00	2026-11-10 13:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.7	open_meteo	0	0.7	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 12:05:01.209615+00
24	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 14:00:00+00	2026-11-10 15:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 14:05:01.037314+00
26	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 16:00:00+00	2026-11-10 17:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.56	sensor	0	0.56	0	0	30.7	\N	\N	0	f	60	24	uncalibrated	2026-11-12 16:05:01.132953+00
28	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 18:00:00+00	2026-11-10 19:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 18:05:48.772666+00
288	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 18:00:00+00	2026-11-11 19:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.03	0.03	\N	\N	\N	0.03	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
384	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 20:00:00+00	2026-11-11 21:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.03	0.03	\N	\N	\N	0.03	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
528	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 23:00:00+00	2026-11-12 00:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.12	open_meteo	1	0.12	0	open_meteo	0	0	0.04	0.16	\N	\N	\N	0.16	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
576	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 00:00:00+00	2026-11-12 01:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.3	open_meteo	1	0.3	0	open_meteo	0	0	0.16	0.45999999999999996	\N	\N	\N	0.45999999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
960	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 08:00:00+00	2026-11-12 09:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.25	open_meteo	1	0.25	1.1	open_meteo	0	0	2.3499999999999996	1.4999999999999996	\N	\N	\N	1.4999999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1008	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 09:00:00+00	2026-11-12 10:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.12	open_meteo	1	0.12	1	open_meteo	0	0	1.4999999999999996	0.6199999999999996	\N	\N	\N	0.6199999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1104	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 11:00:00+00	2026-11-12 12:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.1	open_meteo	0	0	0.3399999999999996	0.23999999999999957	\N	\N	\N	0.23999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1200	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 13:00:00+00	2026-11-12 14:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1440	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 18:00:00+00	2026-11-12 19:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
3	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 17:00:00+00	2026-11-09 18:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0	0.01	\N	\N	\N	0.01	f	60	24	uncalibrated	2026-11-11 17:05:01.117005+00
5	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 19:00:00+00	2026-11-09 20:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.02	0.03	\N	\N	\N	0.03	f	60	24	uncalibrated	2026-11-11 19:05:01.096458+00
7	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 21:00:00+00	2026-11-09 22:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.04	0.05	\N	\N	\N	0.05	f	60	24	uncalibrated	2026-11-11 21:05:01.045886+00
13	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 03:00:00+00	2026-11-10 04:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.52	open_meteo	1	0.52	1.6	open_meteo	0	1.08	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 03:05:01.14058+00
23	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 13:00:00+00	2026-11-10 14:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.1	open_meteo	0	0.1	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 13:05:01.111945+00
336	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 19:00:00+00	2026-11-11 20:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.03	0.03	\N	\N	\N	0.03	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
432	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 21:00:00+00	2026-11-11 22:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.03	0.03	\N	\N	\N	0.03	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
480	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 22:00:00+00	2026-11-11 23:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.03	0.04	\N	\N	\N	0.04	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
624	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 01:00:00+00	2026-11-12 02:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.44	open_meteo	1	0.44	0	open_meteo	0	0	0.45999999999999996	0.8999999999999999	\N	\N	\N	0.8999999999999999	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
672	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 02:00:00+00	2026-11-12 03:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.6	open_meteo	1	0.6	0	open_meteo	0	0	0.8999999999999999	1.5	\N	\N	\N	1.5	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
10	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 00:00:00+00	2026-11-10 01:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.29	open_meteo	1	0.29	0	open_meteo	0	0	0.18	0.47	\N	\N	\N	0.47	f	60	24	uncalibrated	2026-11-12 00:05:01.07138+00
4	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 18:00:00+00	2026-11-09 19:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.01	0.02	\N	\N	\N	0.02	f	60	24	uncalibrated	2026-11-11 18:05:01.127983+00
6	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 20:00:00+00	2026-11-09 21:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.03	0.04	\N	\N	\N	0.04	f	60	24	uncalibrated	2026-11-11 20:05:01.134456+00
1	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 15:00:00+00	2026-11-09 16:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	1.6800000000000002	sensor	0	1.6700000000000002	0	0	31.5	\N	\N	0	f	60	24	uncalibrated	2026-11-11 15:05:01.507841+00
2	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 16:00:00+00	2026-11-09 17:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.8400000000000001	sensor	0	0.8400000000000001	0	0	30.6	\N	\N	0	f	60	24	uncalibrated	2026-11-11 16:05:01.044847+00
14	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 04:00:00+00	2026-11-10 05:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.61	open_meteo	1	0.61	0.2	open_meteo	0	0	0	0.41	\N	\N	\N	0.41	f	60	24	uncalibrated	2026-11-12 04:05:01.040744+00
9	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 23:00:00+00	2026-11-10 00:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.12	open_meteo	1	0.12	0	open_meteo	0	0	0.060000000000000005	0.18	\N	\N	\N	0.18	f	60	24	uncalibrated	2026-11-11 23:05:01.031701+00
8	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-09 22:00:00+00	2026-11-09 23:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.05	0.060000000000000005	\N	\N	\N	0.060000000000000005	f	60	24	uncalibrated	2026-11-11 22:05:01.052646+00
12	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 02:00:00+00	2026-11-10 03:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.43	open_meteo	1	0.43	1.7	open_meteo	0	0.48999999999999994	0.78	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 02:05:01.046702+00
11	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 01:00:00+00	2026-11-10 02:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.41	open_meteo	1	0.41	0.1	open_meteo	0	0	0.47	0.78	\N	\N	\N	0.78	f	60	24	uncalibrated	2026-11-12 01:05:01.052228+00
720	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 03:00:00+00	2026-11-12 04:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.68	open_meteo	1	0.68	0.1	open_meteo	0	0	1.5	2.08	\N	\N	\N	2.08	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
768	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 04:00:00+00	2026-11-12 05:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.71	open_meteo	1	0.71	0.1	open_meteo	0	0	2.08	2.69	\N	\N	\N	2.69	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1152	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 12:00:00+00	2026-11-12 13:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.1	open_meteo	0	0	0.23999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
29	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 19:00:00+00	2026-11-10 20:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 19:05:01.070335+00
31	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 21:00:00+00	2026-11-10 22:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 21:05:01.052105+00
33	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 23:00:00+00	2026-11-11 00:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.12	open_meteo	1	0.12	0	open_meteo	0	0	0.01	0.13	\N	\N	\N	0.13	f	60	24	uncalibrated	2026-11-12 23:05:00.888522+00
35	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 01:00:00+00	2026-11-11 02:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.37	open_meteo	1	0.37	0	open_meteo	0	0	0.4	0.77	\N	\N	\N	0.77	f	60	24	uncalibrated	2026-11-13 01:05:01.055599+00
39	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 05:00:00+00	2026-11-11 06:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.76	open_meteo	1	0.76	0.2	open_meteo	0	0	2.4899999999999998	3.05	\N	\N	\N	3.05	f	60	24	uncalibrated	2026-11-13 05:05:00.764251+00
42	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 08:00:00+00	2026-11-11 09:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.36	open_meteo	1	0.36	0.5	open_meteo	0	0	4.2299999999999995	4.09	\N	\N	\N	4.09	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
192	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 16:00:00+00	2026-11-11 17:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.01	0.02	\N	\N	\N	0.02	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1488	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 19:00:00+00	2026-11-12 20:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1536	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 20:00:00+00	2026-11-12 21:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1776	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-13 01:00:00+00	2026-11-13 02:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.46	open_meteo	1	0.46	0	open_meteo	0	0	0.5199999999999996	0.9799999999999995	\N	\N	\N	0.9799999999999995	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1824	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-13 02:00:00+00	2026-11-13 03:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.52	open_meteo	1	0.52	0	open_meteo	0	0	0.9799999999999995	1.4999999999999996	\N	\N	\N	1.4999999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
36	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 02:00:00+00	2026-11-11 03:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.51	open_meteo	1	0.51	0	open_meteo	0	0	0.77	1.28	\N	\N	\N	1.28	f	60	24	uncalibrated	2026-11-13 02:05:00.885712+00
30	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 20:00:00+00	2026-11-10 21:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 20:05:01.044834+00
32	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 22:00:00+00	2026-11-10 23:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0	0.01	\N	\N	\N	0.01	f	60	24	uncalibrated	2026-11-12 22:05:00.797938+00
34	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 00:00:00+00	2026-11-11 01:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.27	open_meteo	1	0.27	0	open_meteo	0	0	0.13	0.4	\N	\N	\N	0.4	f	60	24	uncalibrated	2026-11-13 00:05:00.767308+00
38	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 04:00:00+00	2026-11-11 05:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.73	open_meteo	1	0.73	0.1	open_meteo	0	0	1.8599999999999999	2.4899999999999998	\N	\N	\N	2.4899999999999998	f	60	24	uncalibrated	2026-11-13 04:05:48.80345+00
40	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 06:00:00+00	2026-11-11 07:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.69	open_meteo	1	0.69	0.1	open_meteo	0	0	3.05	3.6399999999999997	\N	\N	\N	3.6399999999999997	f	60	24	uncalibrated	2026-11-13 06:05:01.118404+00
37	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 03:00:00+00	2026-11-11 04:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.68	open_meteo	1	0.68	0.1	open_meteo	0	0	1.28	1.8599999999999999	\N	\N	\N	1.8599999999999999	f	60	24	uncalibrated	2026-11-13 03:05:01.059013+00
41	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 07:00:00+00	2026-11-11 08:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.59	open_meteo	1	0.59	0	open_meteo	0	0	3.6399999999999997	4.2299999999999995	\N	\N	\N	4.2299999999999995	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
16	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 06:00:00+00	2026-11-10 07:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.5	open_meteo	1	0.5	1.2	open_meteo	0	0.6800000000000002	0.019999999999999907	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 06:05:01.032631+00
17	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 07:00:00+00	2026-11-10 08:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.38	open_meteo	1	0.38	1	open_meteo	0	0.62	0	0	\N	\N	\N	0	f	60	24	uncalibrated	2026-11-12 07:05:01.049647+00
816	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 05:00:00+00	2026-11-12 06:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.73	open_meteo	1	0.73	0.5	open_meteo	0	0	2.69	2.92	\N	\N	\N	2.92	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
15	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-10 05:00:00+00	2026-11-10 06:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.61	open_meteo	1	0.61	1	open_meteo	0	0	0.41	0.019999999999999907	\N	\N	\N	0.019999999999999907	f	60	24	uncalibrated	2026-11-12 05:05:01.048957+00
864	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 06:00:00+00	2026-11-12 07:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.61	open_meteo	1	0.61	0.1	open_meteo	0	0	2.92	3.4299999999999997	\N	\N	\N	3.4299999999999997	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
912	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 07:00:00+00	2026-11-12 08:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.42	open_meteo	1	0.42	1.5	open_meteo	0	0	3.4299999999999997	2.3499999999999996	\N	\N	\N	2.3499999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1584	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 21:00:00+00	2026-11-12 22:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1632	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 22:00:00+00	2026-11-12 23:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0.13999999999999957	0.14999999999999958	\N	\N	\N	0.14999999999999958	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1872	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-13 03:00:00+00	2026-11-13 04:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.66	open_meteo	1	0.66	0	open_meteo	0	0	1.4999999999999996	2.1599999999999997	\N	\N	\N	2.1599999999999997	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1920	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-13 04:00:00+00	2026-11-13 05:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.73	open_meteo	1	0.73	0	open_meteo	0	0	2.1599999999999997	2.8899999999999997	\N	\N	\N	2.8899999999999997	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1056	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 10:00:00+00	2026-11-12 11:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.02	open_meteo	1	0.02	0.3	open_meteo	0	0	0.6199999999999996	0.3399999999999996	\N	\N	\N	0.3399999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1248	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 14:00:00+00	2026-11-12 15:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1392	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 17:00:00+00	2026-11-12 18:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
144	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 15:00:00+00	2026-11-11 16:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0	open_meteo	0	0	0	0.01	\N	\N	\N	0.01	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1296	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 15:00:00+00	2026-11-12 16:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1344	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 16:00:00+00	2026-11-12 17:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0	open_meteo	0	0	0.13999999999999957	0.13999999999999957	\N	\N	\N	0.13999999999999957	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1680	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-12 23:00:00+00	2026-11-13 00:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.1	open_meteo	1	0.1	0	open_meteo	0	0	0.14999999999999958	0.24999999999999958	\N	\N	\N	0.24999999999999958	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
43	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 09:00:00+00	2026-11-11 10:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.14	open_meteo	1	0.14	0.7	open_meteo	0	0	4.09	3.53	\N	\N	\N	3.53	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
44	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 10:00:00+00	2026-11-11 11:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.03	open_meteo	1	0.03	0.5	open_meteo	0	0	3.53	3.0599999999999996	\N	\N	\N	3.0599999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
45	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 11:00:00+00	2026-11-11 12:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.1	open_meteo	0	0	3.0599999999999996	2.9599999999999995	\N	\N	\N	2.9599999999999995	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
46	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 12:00:00+00	2026-11-11 13:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	345.8	sensor	0	342.84000000000003	2.9599999999999995	0	31.65	\N	\N	0	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1728	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-13 00:00:00+00	2026-11-13 01:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.27	open_meteo	1	0.27	0	open_meteo	0	0	0.24999999999999958	0.5199999999999996	\N	\N	\N	0.5199999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
1968	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-13 05:00:00+00	2026-11-13 06:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.65	open_meteo	1	0.65	0	open_meteo	0	0	2.8899999999999997	3.5399999999999996	\N	\N	\N	3.5399999999999996	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
2016	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-13 06:00:00+00	2026-11-13 07:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.65	open_meteo	1	0.65	0	open_meteo	0	0	3.5399999999999996	4.1899999999999995	\N	\N	\N	4.1899999999999995	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
47	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 13:00:00+00	2026-11-11 14:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0	open_meteo	1	0	0.8400000000000001	sensor	0	0.8400000000000001	0	0	30.1	\N	\N	0	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
48	00000000-0000-0000-0000-0000000000b1	11111111-1111-1111-1111-111111111111	2026-11-11 14:00:00+00	2026-11-11 15:00:00+00	0769df3d-79d0-4e84-95fe-1bf304fea2d0	0.01	open_meteo	1	0.01	0.28	sensor	0	0.27	0	0	31.85	\N	\N	0	f	60	24	uncalibrated	2026-11-13 07:05:34.617728+00
\.


--
-- Data for Name: weather_forecast_snapshots; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.weather_forecast_snapshots (id, plot_id, source, model, issued_at, valid_time, lead_hours, precipitation_mm, precipitation_probability, et0_fao_mm, temperature_2m, relative_humidity_2m, wind_speed_10m, shortwave_radiation, fetched_at) FROM stdin;
1	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-11 16:00:00+00	1	0.1	75	0.01	24.9	85	1.39	0	2026-11-11 15:01:15.846451+00
2	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-11 17:00:00+00	2	0	61	0	24.8	86	0.61	0	2026-11-11 15:01:15.846451+00
3	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-11 18:00:00+00	3	0	47	0	24.6	86	0.62	0	2026-11-11 15:01:15.846451+00
4	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-11 19:00:00+00	4	0	32	0	24.1	85	1.06	0	2026-11-11 15:01:15.846451+00
5	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-11 20:00:00+00	5	0	17	0	23.7	86	1	0	2026-11-11 15:01:15.846451+00
6	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-11 21:00:00+00	6	0	6	0	23.6	86	1.01	0	2026-11-11 15:01:15.846451+00
7	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-11 22:00:00+00	7	0	2	0	23.3	87	0.94	0	2026-11-11 15:01:15.846451+00
8	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-11 23:00:00+00	8	0	2	0.01	24	85	1.1	17	2026-11-11 15:01:15.846451+00
9	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 00:00:00+00	9	0	2	0.11	26.8	74	0.61	175	2026-11-11 15:01:15.846451+00
10	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 01:00:00+00	10	0	0	0.29	28.5	67	0.58	407	2026-11-11 15:01:15.846451+00
11	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 02:00:00+00	11	0	0	0.48	30.1	61	1.92	651	2026-11-11 15:01:15.846451+00
12	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 03:00:00+00	12	0	2	0.62	31.5	54	2.62	808	2026-11-11 15:01:15.846451+00
13	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 04:00:00+00	13	0	11	0.73	32.8	48	3.4	923	2026-11-11 15:01:15.846451+00
14	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 05:00:00+00	14	0	24	0.77	33.4	46	3.56	965	2026-11-11 15:01:15.846451+00
15	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 06:00:00+00	15	0	39	0.77	33.9	46	3.57	948	2026-11-11 15:01:15.846451+00
16	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 07:00:00+00	16	0	58	0.63	33.1	49	2.2	790	2026-11-11 15:01:15.846451+00
17	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 08:00:00+00	17	1	79	0.4	28.5	70	3.84	538	2026-11-11 15:01:15.846451+00
18	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 09:00:00+00	18	2.3	94	0.25	27.1	83	2.04	360	2026-11-11 15:01:15.846451+00
19	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 10:00:00+00	19	1.1	100	0.11	26.1	85	0	163	2026-11-11 15:01:15.846451+00
20	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 11:00:00+00	20	1.4	100	0.02	25.3	93	0.62	21	2026-11-11 15:01:15.846451+00
21	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 12:00:00+00	21	0.1	96	0	25	95	0.35	0	2026-11-11 15:01:15.846451+00
22	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 13:00:00+00	22	0.1	82	0	25	96	0.57	0	2026-11-11 15:01:15.846451+00
23	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 14:00:00+00	23	0.1	61	0	25.1	96	0.07	0	2026-11-11 15:01:15.846451+00
24	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 15:00:00+00	24	0	43	0	24.9	96	0.54	0	2026-11-11 15:01:15.846451+00
25	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 16:00:00+00	25	0	29	0	24.6	95	0.42	0	2026-11-11 15:01:15.846451+00
26	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 17:00:00+00	26	0	17	0	24.5	94	0.4	0	2026-11-11 15:01:15.846451+00
27	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 18:00:00+00	27	0	8	0	24.3	96	0.65	0	2026-11-11 15:01:15.846451+00
28	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 19:00:00+00	28	0	4	0	24.1	96	0.32	0	2026-11-11 15:01:15.846451+00
29	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 20:00:00+00	29	0	3	0	23.9	94	1.27	0	2026-11-11 15:01:15.846451+00
30	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 21:00:00+00	30	0	2	0	23.7	93	0.25	0	2026-11-11 15:01:15.846451+00
31	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 22:00:00+00	31	0	1	0	23.5	93	0.68	0	2026-11-11 15:01:15.846451+00
32	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-12 23:00:00+00	32	0	0	0	24	93	0.4	15	2026-11-11 15:01:15.846451+00
33	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 00:00:00+00	33	0	0	0.09	24.9	88	0.86	136	2026-11-11 15:01:15.846451+00
34	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 01:00:00+00	34	0	0	0.22	26.4	80	1.05	320	2026-11-11 15:01:15.846451+00
35	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 02:00:00+00	35	0	0	0.36	27.8	74	0.71	500	2026-11-11 15:01:15.846451+00
36	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 03:00:00+00	36	0	2	0.5	29.5	66	1.04	666	2026-11-11 15:01:15.846451+00
37	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 04:00:00+00	37	0	10	0.55	30.1	67	2.07	738	2026-11-11 15:01:15.846451+00
38	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 05:00:00+00	38	0	23	0.63	30.4	66	1.46	846	2026-11-11 15:01:15.846451+00
39	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 06:00:00+00	39	0	37	0.6	31.7	62	0.6	777	2026-11-11 15:01:15.846451+00
40	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 07:00:00+00	40	0.4	57	0.51	31	66	0.67	667	2026-11-11 15:01:15.846451+00
41	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 08:00:00+00	41	0.4	79	0.4	30.3	69	1.81	528	2026-11-11 15:01:15.846451+00
42	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 09:00:00+00	42	0.1	92	0.26	29.6	71	1.18	335	2026-11-11 15:01:15.846451+00
43	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 10:00:00+00	43	1.8	90	0.11	26.8	87	1.53	159	2026-11-11 15:01:15.846451+00
44	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 11:00:00+00	44	0.1	78	0.02	26.2	88	0.73	24	2026-11-11 15:01:15.846451+00
45	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 12:00:00+00	45	0	65	0	25.8	92	0.3	0	2026-11-11 15:01:15.846451+00
46	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 13:00:00+00	46	0	51	0	25.6	93	0.21	0	2026-11-11 15:01:15.846451+00
47	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 14:00:00+00	47	0	36	0	25.4	95	0.16	0	2026-11-11 15:01:15.846451+00
48	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 15:00:00+00	2026-11-13 15:00:00+00	48	0	24	0	25.1	93	0.47	0	2026-11-11 15:01:15.846451+00
97	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-11 17:00:00+00	1	0	34	0	24.8	86	0.61	0	2026-11-11 16:04:59.998898+00
98	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-11 18:00:00+00	2	0	33	0	24.6	86	0.62	0	2026-11-11 16:04:59.998898+00
99	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-11 19:00:00+00	3	0	25	0	24.1	85	1.06	0	2026-11-11 16:04:59.998898+00
100	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-11 20:00:00+00	4	0	13	0	23.7	86	1	0	2026-11-11 16:04:59.998898+00
101	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-11 21:00:00+00	5	0	4	0	23.6	86	1.01	0	2026-11-11 16:04:59.998898+00
102	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-11 22:00:00+00	6	0	1	0	23.3	87	0.94	0	2026-11-11 16:04:59.998898+00
103	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-11 23:00:00+00	7	0	2	0.01	24	85	1.1	17	2026-11-11 16:04:59.998898+00
104	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 00:00:00+00	8	0	2	0.11	26.8	74	0.61	175	2026-11-11 16:04:59.998898+00
105	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 01:00:00+00	9	0	1	0.29	28.5	67	0.58	407	2026-11-11 16:04:59.998898+00
106	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 02:00:00+00	10	0	0	0.48	30.1	61	1.92	651	2026-11-11 16:04:59.998898+00
107	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 03:00:00+00	11	0	2	0.62	31.5	54	2.62	808	2026-11-11 16:04:59.998898+00
108	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 04:00:00+00	12	0	10	0.73	32.8	48	3.4	923	2026-11-11 16:04:59.998898+00
109	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 05:00:00+00	13	0	21	0.77	33.4	46	3.56	965	2026-11-11 16:04:59.998898+00
110	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 06:00:00+00	14	0	35	0.77	33.9	46	3.57	948	2026-11-11 16:04:59.998898+00
111	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 07:00:00+00	15	0	55	0.63	33.1	49	2.2	790	2026-11-11 16:04:59.998898+00
112	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 08:00:00+00	16	1	78	0.4	28.5	70	3.84	538	2026-11-11 16:04:59.998898+00
113	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 09:00:00+00	17	2.3	94	0.25	27.1	83	2.04	360	2026-11-11 16:04:59.998898+00
114	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 10:00:00+00	18	1.1	100	0.11	26.1	85	0	163	2026-11-11 16:04:59.998898+00
115	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 11:00:00+00	19	1.4	100	0.02	25.3	93	0.62	21	2026-11-11 16:04:59.998898+00
116	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 12:00:00+00	20	0.1	96	0	25	95	0.35	0	2026-11-11 16:04:59.998898+00
117	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 13:00:00+00	21	0.1	86	0	25	96	0.57	0	2026-11-11 16:04:59.998898+00
118	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 14:00:00+00	22	0.1	71	0	25.1	96	0.07	0	2026-11-11 16:04:59.998898+00
119	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 15:00:00+00	23	0	55	0	24.9	96	0.54	0	2026-11-11 16:04:59.998898+00
120	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 16:00:00+00	24	0	38	0	24.6	95	0.42	0	2026-11-11 16:04:59.998898+00
121	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 17:00:00+00	25	0	21	0	24.5	94	0.4	0	2026-11-11 16:04:59.998898+00
122	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 18:00:00+00	26	0	8	0	24.3	96	0.65	0	2026-11-11 16:04:59.998898+00
123	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 19:00:00+00	27	0	3	0	24.1	96	0.32	0	2026-11-11 16:04:59.998898+00
124	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 20:00:00+00	28	0	2	0	23.9	94	1.27	0	2026-11-11 16:04:59.998898+00
125	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 21:00:00+00	29	0	2	0	23.7	93	0.25	0	2026-11-11 16:04:59.998898+00
126	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 22:00:00+00	30	0	2	0	23.5	93	0.68	0	2026-11-11 16:04:59.998898+00
127	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-12 23:00:00+00	31	0	2	0	24	93	0.4	15	2026-11-11 16:04:59.998898+00
128	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 00:00:00+00	32	0	2	0.09	24.9	88	0.86	136	2026-11-11 16:04:59.998898+00
129	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 01:00:00+00	33	0	1	0.22	26.4	80	1.05	320	2026-11-11 16:04:59.998898+00
130	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 02:00:00+00	34	0	0	0.36	27.8	74	0.71	500	2026-11-11 16:04:59.998898+00
131	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 03:00:00+00	35	0	0	0.5	29.5	66	1.04	666	2026-11-11 16:04:59.998898+00
132	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 04:00:00+00	36	0	4	0.55	30.1	67	2.07	738	2026-11-11 16:04:59.998898+00
133	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 05:00:00+00	37	0	12	0.63	30.4	66	1.46	846	2026-11-11 16:04:59.998898+00
134	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 06:00:00+00	38	0	24	0.6	31.7	62	0.6	777	2026-11-11 16:04:59.998898+00
135	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 07:00:00+00	39	0.4	48	0.51	31	66	0.67	667	2026-11-11 16:04:59.998898+00
136	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 08:00:00+00	40	0.4	76	0.4	30.3	69	1.81	528	2026-11-11 16:04:59.998898+00
137	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 09:00:00+00	41	0.1	94	0.26	29.6	71	1.18	335	2026-11-11 16:04:59.998898+00
138	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 10:00:00+00	42	1.8	93	0.11	26.8	87	1.53	159	2026-11-11 16:04:59.998898+00
139	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 11:00:00+00	43	0.1	81	0.02	26.2	88	0.73	24	2026-11-11 16:04:59.998898+00
140	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 12:00:00+00	44	0	67	0	25.8	92	0.3	0	2026-11-11 16:04:59.998898+00
141	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 13:00:00+00	45	0	50	0	25.6	93	0.21	0	2026-11-11 16:04:59.998898+00
142	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 14:00:00+00	46	0	31	0	25.4	95	0.16	0	2026-11-11 16:04:59.998898+00
143	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 15:00:00+00	47	0	16	0	25.1	93	0.47	0	2026-11-11 16:04:59.998898+00
144	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 16:00:00+00	2026-11-13 16:00:00+00	48	0	11	0	25	92	0.25	0	2026-11-11 16:04:59.998898+00
145	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-11 18:00:00+00	1	0	33	0	24.6	86	0.62	0	2026-11-11 17:04:59.999889+00
146	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-11 19:00:00+00	2	0	25	0	24.1	85	1.06	0	2026-11-11 17:04:59.999889+00
147	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-11 20:00:00+00	3	0	13	0	23.7	86	1	0	2026-11-11 17:04:59.999889+00
148	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-11 21:00:00+00	4	0	4	0	23.6	86	1.01	0	2026-11-11 17:04:59.999889+00
149	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-11 22:00:00+00	5	0	1	0	23.3	87	0.94	0	2026-11-11 17:04:59.999889+00
150	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-11 23:00:00+00	6	0	2	0.01	24	85	1.1	17	2026-11-11 17:04:59.999889+00
151	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 00:00:00+00	7	0	2	0.11	26.8	74	0.61	175	2026-11-11 17:04:59.999889+00
152	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 01:00:00+00	8	0	1	0.29	28.5	67	0.58	407	2026-11-11 17:04:59.999889+00
153	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 02:00:00+00	9	0	0	0.48	30.1	61	1.92	651	2026-11-11 17:04:59.999889+00
154	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 03:00:00+00	10	0	2	0.62	31.5	54	2.62	808	2026-11-11 17:04:59.999889+00
155	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 04:00:00+00	11	0	10	0.73	32.8	48	3.4	923	2026-11-11 17:04:59.999889+00
156	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 05:00:00+00	12	0	21	0.77	33.4	46	3.56	965	2026-11-11 17:04:59.999889+00
157	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 06:00:00+00	13	0	35	0.77	33.9	46	3.57	948	2026-11-11 17:04:59.999889+00
158	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 07:00:00+00	14	0	55	0.63	33.1	49	2.2	790	2026-11-11 17:04:59.999889+00
159	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 08:00:00+00	15	1	78	0.4	28.5	70	3.84	538	2026-11-11 17:04:59.999889+00
160	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 09:00:00+00	16	2.3	94	0.25	27.1	83	2.04	360	2026-11-11 17:04:59.999889+00
161	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 10:00:00+00	17	1.1	100	0.11	26.1	85	0	163	2026-11-11 17:04:59.999889+00
162	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 11:00:00+00	18	1.4	100	0.02	25.3	93	0.62	21	2026-11-11 17:04:59.999889+00
163	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 12:00:00+00	19	0.1	96	0	25	95	0.35	0	2026-11-11 17:04:59.999889+00
164	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 13:00:00+00	20	0.1	86	0	25	96	0.57	0	2026-11-11 17:04:59.999889+00
165	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 14:00:00+00	21	0.1	71	0	25.1	96	0.07	0	2026-11-11 17:04:59.999889+00
166	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 15:00:00+00	22	0	55	0	24.9	96	0.54	0	2026-11-11 17:04:59.999889+00
167	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 16:00:00+00	23	0	38	0	24.6	95	0.42	0	2026-11-11 17:04:59.999889+00
168	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 17:00:00+00	24	0	21	0	24.5	94	0.4	0	2026-11-11 17:04:59.999889+00
169	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 18:00:00+00	25	0	8	0	24.3	96	0.65	0	2026-11-11 17:04:59.999889+00
170	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 19:00:00+00	26	0	3	0	24.1	96	0.32	0	2026-11-11 17:04:59.999889+00
171	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 20:00:00+00	27	0	2	0	23.9	94	1.27	0	2026-11-11 17:04:59.999889+00
172	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 21:00:00+00	28	0	2	0	23.7	93	0.25	0	2026-11-11 17:04:59.999889+00
173	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 22:00:00+00	29	0	2	0	23.5	93	0.68	0	2026-11-11 17:04:59.999889+00
174	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-12 23:00:00+00	30	0	2	0	24	93	0.4	15	2026-11-11 17:04:59.999889+00
175	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 00:00:00+00	31	0	2	0.09	24.9	88	0.86	136	2026-11-11 17:04:59.999889+00
176	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 01:00:00+00	32	0	1	0.22	26.4	80	1.05	320	2026-11-11 17:04:59.999889+00
177	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 02:00:00+00	33	0	0	0.36	27.8	74	0.71	500	2026-11-11 17:04:59.999889+00
178	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 03:00:00+00	34	0	0	0.5	29.5	66	1.04	666	2026-11-11 17:04:59.999889+00
179	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 04:00:00+00	35	0	4	0.55	30.1	67	2.07	738	2026-11-11 17:04:59.999889+00
180	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 05:00:00+00	36	0	12	0.63	30.4	66	1.46	846	2026-11-11 17:04:59.999889+00
181	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 06:00:00+00	37	0	24	0.6	31.7	62	0.6	777	2026-11-11 17:04:59.999889+00
182	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 07:00:00+00	38	0.4	48	0.51	31	66	0.67	667	2026-11-11 17:04:59.999889+00
183	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 08:00:00+00	39	0.4	76	0.4	30.3	69	1.81	528	2026-11-11 17:04:59.999889+00
184	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 09:00:00+00	40	0.1	94	0.26	29.6	71	1.18	335	2026-11-11 17:04:59.999889+00
185	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 10:00:00+00	41	1.8	93	0.11	26.8	87	1.53	159	2026-11-11 17:04:59.999889+00
186	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 11:00:00+00	42	0.1	81	0.02	26.2	88	0.73	24	2026-11-11 17:04:59.999889+00
187	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 12:00:00+00	43	0	67	0	25.8	92	0.3	0	2026-11-11 17:04:59.999889+00
188	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 13:00:00+00	44	0	50	0	25.6	93	0.21	0	2026-11-11 17:04:59.999889+00
189	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 14:00:00+00	45	0	31	0	25.4	95	0.16	0	2026-11-11 17:04:59.999889+00
190	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 15:00:00+00	46	0	16	0	25.1	93	0.47	0	2026-11-11 17:04:59.999889+00
191	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 16:00:00+00	47	0	11	0	25	92	0.25	0	2026-11-11 17:04:59.999889+00
192	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 17:00:00+00	2026-11-13 17:00:00+00	48	0	10	0	24.8	90	0.21	0	2026-11-11 17:04:59.999889+00
193	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-11 19:00:00+00	1	0	25	0	24.1	85	1.06	0	2026-11-11 18:05:00.000531+00
194	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-11 20:00:00+00	2	0	13	0	23.7	86	1	0	2026-11-11 18:05:00.000531+00
195	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-11 21:00:00+00	3	0	4	0	23.6	86	1.01	0	2026-11-11 18:05:00.000531+00
196	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-11 22:00:00+00	4	0	1	0	23.3	87	0.94	0	2026-11-11 18:05:00.000531+00
197	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-11 23:00:00+00	5	0	2	0.01	24	85	1.1	17	2026-11-11 18:05:00.000531+00
198	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 00:00:00+00	6	0	2	0.11	26.8	74	0.61	175	2026-11-11 18:05:00.000531+00
199	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 01:00:00+00	7	0	1	0.29	28.5	67	0.58	407	2026-11-11 18:05:00.000531+00
200	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 02:00:00+00	8	0	0	0.48	30.1	61	1.92	651	2026-11-11 18:05:00.000531+00
201	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 03:00:00+00	9	0	2	0.62	31.5	54	2.62	808	2026-11-11 18:05:00.000531+00
202	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 04:00:00+00	10	0	10	0.73	32.8	48	3.4	923	2026-11-11 18:05:00.000531+00
203	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 05:00:00+00	11	0	21	0.77	33.4	46	3.56	965	2026-11-11 18:05:00.000531+00
204	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 06:00:00+00	12	0	35	0.77	33.9	46	3.57	948	2026-11-11 18:05:00.000531+00
205	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 07:00:00+00	13	0	55	0.63	33.1	49	2.2	790	2026-11-11 18:05:00.000531+00
206	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 08:00:00+00	14	1	78	0.4	28.5	70	3.84	538	2026-11-11 18:05:00.000531+00
207	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 09:00:00+00	15	2.3	94	0.25	27.1	83	2.04	360	2026-11-11 18:05:00.000531+00
208	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 10:00:00+00	16	1.1	100	0.11	26.1	85	0	163	2026-11-11 18:05:00.000531+00
209	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 11:00:00+00	17	1.4	100	0.02	25.3	93	0.62	21	2026-11-11 18:05:00.000531+00
210	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 12:00:00+00	18	0.1	96	0	25	95	0.35	0	2026-11-11 18:05:00.000531+00
211	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 13:00:00+00	19	0.1	86	0	25	96	0.57	0	2026-11-11 18:05:00.000531+00
212	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 14:00:00+00	20	0.1	71	0	25.1	96	0.07	0	2026-11-11 18:05:00.000531+00
213	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 15:00:00+00	21	0	55	0	24.9	96	0.54	0	2026-11-11 18:05:00.000531+00
214	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 16:00:00+00	22	0	38	0	24.6	95	0.42	0	2026-11-11 18:05:00.000531+00
215	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 17:00:00+00	23	0	21	0	24.5	94	0.4	0	2026-11-11 18:05:00.000531+00
216	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 18:00:00+00	24	0	8	0	24.3	96	0.65	0	2026-11-11 18:05:00.000531+00
217	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 19:00:00+00	25	0	3	0	24.1	96	0.32	0	2026-11-11 18:05:00.000531+00
218	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 20:00:00+00	26	0	2	0	23.9	94	1.27	0	2026-11-11 18:05:00.000531+00
219	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 21:00:00+00	27	0	2	0	23.7	93	0.25	0	2026-11-11 18:05:00.000531+00
220	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 22:00:00+00	28	0	2	0	23.5	93	0.68	0	2026-11-11 18:05:00.000531+00
221	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-12 23:00:00+00	29	0	2	0	24	93	0.4	15	2026-11-11 18:05:00.000531+00
222	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 00:00:00+00	30	0	2	0.09	24.9	88	0.86	136	2026-11-11 18:05:00.000531+00
223	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 01:00:00+00	31	0	1	0.22	26.4	80	1.05	320	2026-11-11 18:05:00.000531+00
224	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 02:00:00+00	32	0	0	0.36	27.8	74	0.71	500	2026-11-11 18:05:00.000531+00
225	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 03:00:00+00	33	0	0	0.5	29.5	66	1.04	666	2026-11-11 18:05:00.000531+00
226	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 04:00:00+00	34	0	4	0.55	30.1	67	2.07	738	2026-11-11 18:05:00.000531+00
227	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 05:00:00+00	35	0	12	0.63	30.4	66	1.46	846	2026-11-11 18:05:00.000531+00
228	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 06:00:00+00	36	0	24	0.6	31.7	62	0.6	777	2026-11-11 18:05:00.000531+00
229	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 07:00:00+00	37	0.4	48	0.51	31	66	0.67	667	2026-11-11 18:05:00.000531+00
230	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 08:00:00+00	38	0.4	76	0.4	30.3	69	1.81	528	2026-11-11 18:05:00.000531+00
231	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 09:00:00+00	39	0.1	94	0.26	29.6	71	1.18	335	2026-11-11 18:05:00.000531+00
232	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 10:00:00+00	40	1.8	93	0.11	26.8	87	1.53	159	2026-11-11 18:05:00.000531+00
233	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 11:00:00+00	41	0.1	81	0.02	26.2	88	0.73	24	2026-11-11 18:05:00.000531+00
234	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 12:00:00+00	42	0	67	0	25.8	92	0.3	0	2026-11-11 18:05:00.000531+00
235	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 13:00:00+00	43	0	50	0	25.6	93	0.21	0	2026-11-11 18:05:00.000531+00
236	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 14:00:00+00	44	0	31	0	25.4	95	0.16	0	2026-11-11 18:05:00.000531+00
237	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 15:00:00+00	45	0	16	0	25.1	93	0.47	0	2026-11-11 18:05:00.000531+00
238	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 16:00:00+00	46	0	11	0	25	92	0.25	0	2026-11-11 18:05:00.000531+00
239	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 17:00:00+00	47	0	10	0	24.8	90	0.21	0	2026-11-11 18:05:00.000531+00
240	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 18:00:00+00	2026-11-13 18:00:00+00	48	0	10	0	24.6	91	0.43	0	2026-11-11 18:05:00.000531+00
241	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-11 20:00:00+00	1	0	13	0	23.7	86	1	0	2026-11-11 19:05:00.000583+00
242	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-11 21:00:00+00	2	0	4	0	23.6	86	1.01	0	2026-11-11 19:05:00.000583+00
243	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-11 22:00:00+00	3	0	1	0	23.3	87	0.94	0	2026-11-11 19:05:00.000583+00
244	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-11 23:00:00+00	4	0	2	0.01	24	85	1.1	17	2026-11-11 19:05:00.000583+00
245	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 00:00:00+00	5	0	2	0.11	26.8	74	0.61	175	2026-11-11 19:05:00.000583+00
246	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 01:00:00+00	6	0	1	0.29	28.5	67	0.58	407	2026-11-11 19:05:00.000583+00
247	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 02:00:00+00	7	0	0	0.48	30.1	61	1.92	651	2026-11-11 19:05:00.000583+00
248	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 03:00:00+00	8	0	2	0.62	31.5	54	2.62	808	2026-11-11 19:05:00.000583+00
249	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 04:00:00+00	9	0	10	0.73	32.8	48	3.4	923	2026-11-11 19:05:00.000583+00
250	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 05:00:00+00	10	0	21	0.77	33.4	46	3.56	965	2026-11-11 19:05:00.000583+00
251	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 06:00:00+00	11	0	35	0.77	33.9	46	3.57	948	2026-11-11 19:05:00.000583+00
252	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 07:00:00+00	12	0	55	0.63	33.1	49	2.2	790	2026-11-11 19:05:00.000583+00
253	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 08:00:00+00	13	1	78	0.4	28.5	70	3.84	538	2026-11-11 19:05:00.000583+00
254	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 09:00:00+00	14	2.3	94	0.25	27.1	83	2.04	360	2026-11-11 19:05:00.000583+00
255	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 10:00:00+00	15	1.1	100	0.11	26.1	85	0	163	2026-11-11 19:05:00.000583+00
256	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 11:00:00+00	16	1.4	100	0.02	25.3	93	0.62	21	2026-11-11 19:05:00.000583+00
257	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 12:00:00+00	17	0.1	96	0	25	95	0.35	0	2026-11-11 19:05:00.000583+00
258	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 13:00:00+00	18	0.1	86	0	25	96	0.57	0	2026-11-11 19:05:00.000583+00
259	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 14:00:00+00	19	0.1	71	0	25.1	96	0.07	0	2026-11-11 19:05:00.000583+00
260	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 15:00:00+00	20	0	55	0	24.9	96	0.54	0	2026-11-11 19:05:00.000583+00
261	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 16:00:00+00	21	0	38	0	24.6	95	0.42	0	2026-11-11 19:05:00.000583+00
262	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 17:00:00+00	22	0	21	0	24.5	94	0.4	0	2026-11-11 19:05:00.000583+00
263	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 18:00:00+00	23	0	8	0	24.3	96	0.65	0	2026-11-11 19:05:00.000583+00
264	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 19:00:00+00	24	0	3	0	24.1	96	0.32	0	2026-11-11 19:05:00.000583+00
265	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 20:00:00+00	25	0	2	0	23.9	94	1.27	0	2026-11-11 19:05:00.000583+00
266	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 21:00:00+00	26	0	2	0	23.7	93	0.25	0	2026-11-11 19:05:00.000583+00
267	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 22:00:00+00	27	0	2	0	23.5	93	0.68	0	2026-11-11 19:05:00.000583+00
268	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-12 23:00:00+00	28	0	2	0	24	93	0.4	15	2026-11-11 19:05:00.000583+00
269	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 00:00:00+00	29	0	2	0.09	24.9	88	0.86	136	2026-11-11 19:05:00.000583+00
270	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 01:00:00+00	30	0	1	0.22	26.4	80	1.05	320	2026-11-11 19:05:00.000583+00
271	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 02:00:00+00	31	0	0	0.36	27.8	74	0.71	500	2026-11-11 19:05:00.000583+00
272	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 03:00:00+00	32	0	0	0.5	29.5	66	1.04	666	2026-11-11 19:05:00.000583+00
273	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 04:00:00+00	33	0	4	0.55	30.1	67	2.07	738	2026-11-11 19:05:00.000583+00
274	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 05:00:00+00	34	0	12	0.63	30.4	66	1.46	846	2026-11-11 19:05:00.000583+00
275	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 06:00:00+00	35	0	24	0.6	31.7	62	0.6	777	2026-11-11 19:05:00.000583+00
276	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 07:00:00+00	36	0.4	48	0.51	31	66	0.67	667	2026-11-11 19:05:00.000583+00
277	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 08:00:00+00	37	0.4	76	0.4	30.3	69	1.81	528	2026-11-11 19:05:00.000583+00
278	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 09:00:00+00	38	0.1	94	0.26	29.6	71	1.18	335	2026-11-11 19:05:00.000583+00
279	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 10:00:00+00	39	1.8	93	0.11	26.8	87	1.53	159	2026-11-11 19:05:00.000583+00
280	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 11:00:00+00	40	0.1	81	0.02	26.2	88	0.73	24	2026-11-11 19:05:00.000583+00
281	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 12:00:00+00	41	0	67	0	25.8	92	0.3	0	2026-11-11 19:05:00.000583+00
282	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 13:00:00+00	42	0	50	0	25.6	93	0.21	0	2026-11-11 19:05:00.000583+00
283	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 14:00:00+00	43	0	31	0	25.4	95	0.16	0	2026-11-11 19:05:00.000583+00
284	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 15:00:00+00	44	0	16	0	25.1	93	0.47	0	2026-11-11 19:05:00.000583+00
285	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 16:00:00+00	45	0	11	0	25	92	0.25	0	2026-11-11 19:05:00.000583+00
286	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 17:00:00+00	46	0	10	0	24.8	90	0.21	0	2026-11-11 19:05:00.000583+00
287	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 18:00:00+00	47	0	10	0	24.6	91	0.43	0	2026-11-11 19:05:00.000583+00
288	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 19:00:00+00	2026-11-13 19:00:00+00	48	0	8	0	24.1	91	0.51	0	2026-11-11 19:05:00.000583+00
289	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-11 21:00:00+00	1	0.1	4	0	24.4	85	0.94	0	2026-11-11 20:04:59.999645+00
290	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-11 22:00:00+00	2	0	1	0	24.2	86	0.72	0	2026-11-11 20:04:59.999645+00
291	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-11 23:00:00+00	3	0	2	0.01	24.7	84	0.92	16	2026-11-11 20:04:59.999645+00
292	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 00:00:00+00	4	0	2	0.11	26.6	75	0.36	170	2026-11-11 20:04:59.999645+00
293	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 01:00:00+00	5	0	1	0.29	28.4	67	0.76	410	2026-11-11 20:04:59.999645+00
294	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 02:00:00+00	6	0	0	0.44	29.4	65	1.52	591	2026-11-11 20:04:59.999645+00
295	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 03:00:00+00	7	0	2	0.59	30.9	60	2.05	777	2026-11-11 20:04:59.999645+00
296	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 04:00:00+00	8	0.1	10	0.67	32.1	52	2.87	848	2026-11-11 20:04:59.999645+00
297	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 05:00:00+00	9	0.2	21	0.72	32.8	49	3.38	907	2026-11-11 20:04:59.999645+00
298	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 06:00:00+00	10	0.1	35	0.74	33.2	48	3.33	921	2026-11-11 20:04:59.999645+00
299	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 07:00:00+00	11	0	55	0.68	33.6	48	3.06	842	2026-11-11 20:04:59.999645+00
300	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 08:00:00+00	12	0.2	78	0.49	31.4	55	2.62	622	2026-11-11 20:04:59.999645+00
301	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 09:00:00+00	13	5.1	94	0.24	25.9	87	1.35	346	2026-11-11 20:04:59.999645+00
302	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 10:00:00+00	14	7.6	100	0.08	24.9	93	1.91	111	2026-11-11 20:04:59.999645+00
303	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 11:00:00+00	15	0.4	100	0.02	25.2	94	1	22	2026-11-11 20:04:59.999645+00
304	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 12:00:00+00	16	1	96	0	24.7	96	0.41	0	2026-11-11 20:04:59.999645+00
305	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 13:00:00+00	17	0.4	86	0	25	93	0.78	0	2026-11-11 20:04:59.999645+00
306	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 14:00:00+00	18	0.3	71	0	24.9	95	0.05	0	2026-11-11 20:04:59.999645+00
307	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 15:00:00+00	19	0.1	55	0	24.5	98	0.64	0	2026-11-11 20:04:59.999645+00
308	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 16:00:00+00	20	0	38	0	24.4	98	0.25	0	2026-11-11 20:04:59.999645+00
309	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 17:00:00+00	21	0	21	0	24.1	98	0.67	0	2026-11-11 20:04:59.999645+00
310	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 18:00:00+00	22	0	8	0	23.9	97	0.32	0	2026-11-11 20:04:59.999645+00
311	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 19:00:00+00	23	0	3	0	23.8	95	0.22	0	2026-11-11 20:04:59.999645+00
312	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 20:00:00+00	24	0	2	0	23.7	95	0.32	0	2026-11-11 20:04:59.999645+00
313	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 21:00:00+00	25	0	2	0	23.5	93	0.42	0	2026-11-11 20:04:59.999645+00
314	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 22:00:00+00	26	0	2	0	23.6	91	0.07	0	2026-11-11 20:04:59.999645+00
315	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-12 23:00:00+00	27	0	2	0	23.9	91	0.21	14	2026-11-11 20:04:59.999645+00
316	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 00:00:00+00	28	0	2	0.1	25	90	0.18	151	2026-11-11 20:04:59.999645+00
317	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 01:00:00+00	29	0	1	0.24	26.8	81	1.01	349	2026-11-11 20:04:59.999645+00
318	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 02:00:00+00	30	0	0	0.43	28.3	72	1.71	610	2026-11-11 20:04:59.999645+00
319	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 03:00:00+00	31	0	0	0.56	29.3	70	1.23	762	2026-11-11 20:04:59.999645+00
320	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 04:00:00+00	32	0.1	4	0.67	30.7	65	2.06	896	2026-11-11 20:04:59.999645+00
321	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 05:00:00+00	33	0.1	12	0.69	31.3	62	2.15	911	2026-11-11 20:04:59.999645+00
322	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 06:00:00+00	34	0.4	24	0.59	30.2	65	3.33	792	2026-11-11 20:04:59.999645+00
323	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 07:00:00+00	35	0.7	48	0.49	30.7	65	2.01	641	2026-11-11 20:04:59.999645+00
324	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 08:00:00+00	36	0.3	76	0.36	29.1	72	2.68	477	2026-11-11 20:04:59.999645+00
325	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 09:00:00+00	37	1.5	94	0.19	26.9	86	1.19	264	2026-11-11 20:04:59.999645+00
326	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 10:00:00+00	38	0.1	93	0.09	26.9	85	0.46	127	2026-11-11 20:04:59.999645+00
327	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 11:00:00+00	39	0	81	0.02	26	91	0.63	27	2026-11-11 20:04:59.999645+00
328	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 12:00:00+00	40	0	67	0	25.9	92	0.71	0	2026-11-11 20:04:59.999645+00
329	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 13:00:00+00	41	0	50	0	25.6	92	0.46	0	2026-11-11 20:04:59.999645+00
330	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 14:00:00+00	42	0	31	0	25.5	91	0.69	0	2026-11-11 20:04:59.999645+00
331	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 15:00:00+00	43	0	16	0	25.3	90	0.35	0	2026-11-11 20:04:59.999645+00
332	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 16:00:00+00	44	0	11	0	24.9	91	0.67	0	2026-11-11 20:04:59.999645+00
333	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 17:00:00+00	45	0	10	0	24.6	91	0.53	0	2026-11-11 20:04:59.999645+00
334	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 18:00:00+00	46	0	10	0	24.1	92	0.46	0	2026-11-11 20:04:59.999645+00
335	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 19:00:00+00	47	0	8	0	24.2	92	0.34	0	2026-11-11 20:04:59.999645+00
336	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 20:00:00+00	2026-11-13 20:00:00+00	48	0	7	0	23.7	90	1.15	0	2026-11-11 20:04:59.999645+00
337	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-11 22:00:00+00	1	0	1	0	24.2	86	0.72	0	2026-11-11 21:04:59.999369+00
338	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-11 23:00:00+00	2	0	2	0.01	24.7	84	0.92	16	2026-11-11 21:04:59.999369+00
339	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 00:00:00+00	3	0	2	0.11	26.6	75	0.36	170	2026-11-11 21:04:59.999369+00
340	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 01:00:00+00	4	0	1	0.29	28.4	67	0.76	410	2026-11-11 21:04:59.999369+00
341	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 02:00:00+00	5	0	0	0.44	29.4	65	1.52	591	2026-11-11 21:04:59.999369+00
342	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 03:00:00+00	6	0	2	0.59	30.9	60	2.05	777	2026-11-11 21:04:59.999369+00
343	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 04:00:00+00	7	0.1	10	0.67	32.1	52	2.87	848	2026-11-11 21:04:59.999369+00
344	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 05:00:00+00	8	0.2	21	0.72	32.8	49	3.38	907	2026-11-11 21:04:59.999369+00
345	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 06:00:00+00	9	0.1	35	0.74	33.2	48	3.33	921	2026-11-11 21:04:59.999369+00
346	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 07:00:00+00	10	0	55	0.68	33.6	48	3.06	842	2026-11-11 21:04:59.999369+00
347	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 08:00:00+00	11	0.2	78	0.49	31.4	55	2.62	622	2026-11-11 21:04:59.999369+00
348	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 09:00:00+00	12	5.1	94	0.24	25.9	87	1.35	346	2026-11-11 21:04:59.999369+00
349	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 10:00:00+00	13	7.6	100	0.08	24.9	93	1.91	111	2026-11-11 21:04:59.999369+00
350	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 11:00:00+00	14	0.4	100	0.02	25.2	94	1	22	2026-11-11 21:04:59.999369+00
351	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 12:00:00+00	15	1	96	0	24.7	96	0.41	0	2026-11-11 21:04:59.999369+00
352	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 13:00:00+00	16	0.4	86	0	25	93	0.78	0	2026-11-11 21:04:59.999369+00
353	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 14:00:00+00	17	0.3	71	0	24.9	95	0.05	0	2026-11-11 21:04:59.999369+00
354	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 15:00:00+00	18	0.1	55	0	24.5	98	0.64	0	2026-11-11 21:04:59.999369+00
355	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 16:00:00+00	19	0	38	0	24.4	98	0.25	0	2026-11-11 21:04:59.999369+00
356	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 17:00:00+00	20	0	21	0	24.1	98	0.67	0	2026-11-11 21:04:59.999369+00
357	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 18:00:00+00	21	0	8	0	23.9	97	0.32	0	2026-11-11 21:04:59.999369+00
358	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 19:00:00+00	22	0	3	0	23.8	95	0.22	0	2026-11-11 21:04:59.999369+00
359	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 20:00:00+00	23	0	2	0	23.7	95	0.32	0	2026-11-11 21:04:59.999369+00
360	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 21:00:00+00	24	0	2	0	23.5	93	0.42	0	2026-11-11 21:04:59.999369+00
361	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 22:00:00+00	25	0	2	0	23.6	91	0.07	0	2026-11-11 21:04:59.999369+00
362	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-12 23:00:00+00	26	0	2	0	23.9	91	0.21	14	2026-11-11 21:04:59.999369+00
363	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 00:00:00+00	27	0	2	0.1	25	90	0.18	151	2026-11-11 21:04:59.999369+00
364	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 01:00:00+00	28	0	1	0.24	26.8	81	1.01	349	2026-11-11 21:04:59.999369+00
365	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 02:00:00+00	29	0	0	0.43	28.3	72	1.71	610	2026-11-11 21:04:59.999369+00
366	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 03:00:00+00	30	0	0	0.56	29.3	70	1.23	762	2026-11-11 21:04:59.999369+00
367	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 04:00:00+00	31	0.1	4	0.67	30.7	65	2.06	896	2026-11-11 21:04:59.999369+00
368	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 05:00:00+00	32	0.1	12	0.69	31.3	62	2.15	911	2026-11-11 21:04:59.999369+00
369	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 06:00:00+00	33	0.4	24	0.59	30.2	65	3.33	792	2026-11-11 21:04:59.999369+00
370	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 07:00:00+00	34	0.7	48	0.49	30.7	65	2.01	641	2026-11-11 21:04:59.999369+00
371	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 08:00:00+00	35	0.3	76	0.36	29.1	72	2.68	477	2026-11-11 21:04:59.999369+00
372	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 09:00:00+00	36	1.5	94	0.19	26.9	86	1.19	264	2026-11-11 21:04:59.999369+00
373	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 10:00:00+00	37	0.1	93	0.09	26.9	85	0.46	127	2026-11-11 21:04:59.999369+00
374	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 11:00:00+00	38	0	81	0.02	26	91	0.63	27	2026-11-11 21:04:59.999369+00
375	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 12:00:00+00	39	0	67	0	25.9	92	0.71	0	2026-11-11 21:04:59.999369+00
376	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 13:00:00+00	40	0	50	0	25.6	92	0.46	0	2026-11-11 21:04:59.999369+00
377	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 14:00:00+00	41	0	31	0	25.5	91	0.69	0	2026-11-11 21:04:59.999369+00
378	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 15:00:00+00	42	0	16	0	25.3	90	0.35	0	2026-11-11 21:04:59.999369+00
379	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 16:00:00+00	43	0	11	0	24.9	91	0.67	0	2026-11-11 21:04:59.999369+00
380	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 17:00:00+00	44	0	10	0	24.6	91	0.53	0	2026-11-11 21:04:59.999369+00
381	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 18:00:00+00	45	0	10	0	24.1	92	0.46	0	2026-11-11 21:04:59.999369+00
382	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 19:00:00+00	46	0	8	0	24.2	92	0.34	0	2026-11-11 21:04:59.999369+00
383	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 20:00:00+00	47	0	7	0	23.7	90	1.15	0	2026-11-11 21:04:59.999369+00
384	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 21:00:00+00	2026-11-13 21:00:00+00	48	0.1	6	0	23.5	89	0.98	0	2026-11-11 21:04:59.999369+00
385	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-11 23:00:00+00	1	0	2	0.01	24.7	84	0.92	16	2026-11-11 22:05:00.000354+00
386	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 00:00:00+00	2	0	2	0.11	26.6	75	0.36	170	2026-11-11 22:05:00.000354+00
387	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 01:00:00+00	3	0	1	0.29	28.4	67	0.76	410	2026-11-11 22:05:00.000354+00
388	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 02:00:00+00	4	0	0	0.44	29.4	65	1.52	591	2026-11-11 22:05:00.000354+00
389	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 03:00:00+00	5	0	2	0.59	30.9	60	2.05	777	2026-11-11 22:05:00.000354+00
390	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 04:00:00+00	6	0.1	10	0.67	32.1	52	2.87	848	2026-11-11 22:05:00.000354+00
391	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 05:00:00+00	7	0.2	21	0.72	32.8	49	3.38	907	2026-11-11 22:05:00.000354+00
392	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 06:00:00+00	8	0.1	35	0.74	33.2	48	3.33	921	2026-11-11 22:05:00.000354+00
393	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 07:00:00+00	9	0	55	0.68	33.6	48	3.06	842	2026-11-11 22:05:00.000354+00
394	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 08:00:00+00	10	0.2	78	0.49	31.4	55	2.62	622	2026-11-11 22:05:00.000354+00
395	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 09:00:00+00	11	5.1	94	0.24	25.9	87	1.35	346	2026-11-11 22:05:00.000354+00
396	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 10:00:00+00	12	7.6	100	0.08	24.9	93	1.91	111	2026-11-11 22:05:00.000354+00
397	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 11:00:00+00	13	0.4	100	0.02	25.2	94	1	22	2026-11-11 22:05:00.000354+00
398	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 12:00:00+00	14	1	96	0	24.7	96	0.41	0	2026-11-11 22:05:00.000354+00
399	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 13:00:00+00	15	0.4	86	0	25	93	0.78	0	2026-11-11 22:05:00.000354+00
400	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 14:00:00+00	16	0.3	71	0	24.9	95	0.05	0	2026-11-11 22:05:00.000354+00
401	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 15:00:00+00	17	0.1	55	0	24.5	98	0.64	0	2026-11-11 22:05:00.000354+00
402	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 16:00:00+00	18	0	38	0	24.4	98	0.25	0	2026-11-11 22:05:00.000354+00
403	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 17:00:00+00	19	0	21	0	24.1	98	0.67	0	2026-11-11 22:05:00.000354+00
404	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 18:00:00+00	20	0	8	0	23.9	97	0.32	0	2026-11-11 22:05:00.000354+00
405	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 19:00:00+00	21	0	3	0	23.8	95	0.22	0	2026-11-11 22:05:00.000354+00
406	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 20:00:00+00	22	0	2	0	23.7	95	0.32	0	2026-11-11 22:05:00.000354+00
407	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 21:00:00+00	23	0	2	0	23.5	93	0.42	0	2026-11-11 22:05:00.000354+00
408	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 22:00:00+00	24	0	2	0	23.6	91	0.07	0	2026-11-11 22:05:00.000354+00
409	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-12 23:00:00+00	25	0	2	0	23.9	91	0.21	14	2026-11-11 22:05:00.000354+00
410	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 00:00:00+00	26	0	2	0.1	25	90	0.18	151	2026-11-11 22:05:00.000354+00
411	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 01:00:00+00	27	0	1	0.24	26.8	81	1.01	349	2026-11-11 22:05:00.000354+00
412	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 02:00:00+00	28	0	0	0.43	28.3	72	1.71	610	2026-11-11 22:05:00.000354+00
413	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 03:00:00+00	29	0	0	0.56	29.3	70	1.23	762	2026-11-11 22:05:00.000354+00
414	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 04:00:00+00	30	0.1	4	0.67	30.7	65	2.06	896	2026-11-11 22:05:00.000354+00
415	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 05:00:00+00	31	0.1	12	0.69	31.3	62	2.15	911	2026-11-11 22:05:00.000354+00
416	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 06:00:00+00	32	0.4	24	0.59	30.2	65	3.33	792	2026-11-11 22:05:00.000354+00
417	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 07:00:00+00	33	0.7	48	0.49	30.7	65	2.01	641	2026-11-11 22:05:00.000354+00
418	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 08:00:00+00	34	0.3	76	0.36	29.1	72	2.68	477	2026-11-11 22:05:00.000354+00
419	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 09:00:00+00	35	1.5	94	0.19	26.9	86	1.19	264	2026-11-11 22:05:00.000354+00
420	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 10:00:00+00	36	0.1	93	0.09	26.9	85	0.46	127	2026-11-11 22:05:00.000354+00
421	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 11:00:00+00	37	0	81	0.02	26	91	0.63	27	2026-11-11 22:05:00.000354+00
422	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 12:00:00+00	38	0	67	0	25.9	92	0.71	0	2026-11-11 22:05:00.000354+00
423	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 13:00:00+00	39	0	50	0	25.6	92	0.46	0	2026-11-11 22:05:00.000354+00
424	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 14:00:00+00	40	0	31	0	25.5	91	0.69	0	2026-11-11 22:05:00.000354+00
425	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 15:00:00+00	41	0	16	0	25.3	90	0.35	0	2026-11-11 22:05:00.000354+00
426	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 16:00:00+00	42	0	11	0	24.9	91	0.67	0	2026-11-11 22:05:00.000354+00
427	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 17:00:00+00	43	0	10	0	24.6	91	0.53	0	2026-11-11 22:05:00.000354+00
428	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 18:00:00+00	44	0	10	0	24.1	92	0.46	0	2026-11-11 22:05:00.000354+00
429	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 19:00:00+00	45	0	8	0	24.2	92	0.34	0	2026-11-11 22:05:00.000354+00
430	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 20:00:00+00	46	0	7	0	23.7	90	1.15	0	2026-11-11 22:05:00.000354+00
431	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 21:00:00+00	47	0.1	6	0	23.5	89	0.98	0	2026-11-11 22:05:00.000354+00
432	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 22:00:00+00	2026-11-13 22:00:00+00	48	0	5	0	23.6	89	0.82	0	2026-11-11 22:05:00.000354+00
433	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 00:00:00+00	1	0	2	0.11	26.6	75	0.36	170	2026-11-11 23:04:59.99915+00
434	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 01:00:00+00	2	0	1	0.29	28.4	67	0.76	410	2026-11-11 23:04:59.99915+00
435	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 02:00:00+00	3	0	4	0.44	29.4	65	1.52	591	2026-11-11 23:04:59.99915+00
436	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 03:00:00+00	4	0	10	0.59	30.9	60	2.05	777	2026-11-11 23:04:59.99915+00
437	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 04:00:00+00	5	0.1	19	0.67	32.1	52	2.87	848	2026-11-11 23:04:59.99915+00
438	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 05:00:00+00	6	0.2	31	0.72	32.8	49	3.38	907	2026-11-11 23:04:59.99915+00
439	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 06:00:00+00	7	0.1	45	0.74	33.2	48	3.33	921	2026-11-11 23:04:59.99915+00
440	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 07:00:00+00	8	0	64	0.68	33.6	48	3.06	842	2026-11-11 23:04:59.99915+00
441	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 08:00:00+00	9	0.2	85	0.49	31.4	55	2.62	622	2026-11-11 23:04:59.99915+00
442	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 09:00:00+00	10	5.1	100	0.24	25.9	87	1.35	346	2026-11-11 23:04:59.99915+00
443	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 10:00:00+00	11	7.6	100	0.08	24.9	93	1.91	111	2026-11-11 23:04:59.99915+00
444	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 11:00:00+00	12	0.4	100	0.02	25.2	94	1	22	2026-11-11 23:04:59.99915+00
445	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 12:00:00+00	13	1	98	0	24.7	96	0.41	0	2026-11-11 23:04:59.99915+00
446	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 13:00:00+00	14	0.4	89	0	25	93	0.78	0	2026-11-11 23:04:59.99915+00
447	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 14:00:00+00	15	0.3	77	0	24.9	95	0.05	0	2026-11-11 23:04:59.99915+00
448	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 15:00:00+00	16	0.1	63	0	24.5	98	0.64	0	2026-11-11 23:04:59.99915+00
449	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 16:00:00+00	17	0	46	0	24.4	98	0.25	0	2026-11-11 23:04:59.99915+00
450	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 17:00:00+00	18	0	28	0	24.1	98	0.67	0	2026-11-11 23:04:59.99915+00
451	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 18:00:00+00	19	0	14	0	23.9	97	0.32	0	2026-11-11 23:04:59.99915+00
452	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 19:00:00+00	20	0	8	0	23.8	95	0.22	0	2026-11-11 23:04:59.99915+00
453	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 20:00:00+00	21	0	7	0	23.7	95	0.32	0	2026-11-11 23:04:59.99915+00
454	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 21:00:00+00	22	0	6	0	23.5	93	0.42	0	2026-11-11 23:04:59.99915+00
455	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 22:00:00+00	23	0	4	0	23.6	91	0.07	0	2026-11-11 23:04:59.99915+00
456	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-12 23:00:00+00	24	0	3	0	23.9	91	0.21	14	2026-11-11 23:04:59.99915+00
457	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 00:00:00+00	25	0	2	0.1	25	90	0.18	151	2026-11-11 23:04:59.99915+00
458	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 01:00:00+00	26	0	1	0.24	26.8	81	1.01	349	2026-11-11 23:04:59.99915+00
459	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 02:00:00+00	27	0	2	0.43	28.3	72	1.71	610	2026-11-11 23:04:59.99915+00
460	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 03:00:00+00	28	0	6	0.56	29.3	70	1.23	762	2026-11-11 23:04:59.99915+00
461	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 04:00:00+00	29	0.1	16	0.67	30.7	65	2.06	896	2026-11-11 23:04:59.99915+00
462	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 05:00:00+00	30	0.1	30	0.69	31.3	62	2.15	911	2026-11-11 23:04:59.99915+00
463	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 06:00:00+00	31	0.4	45	0.59	30.2	65	3.33	792	2026-11-11 23:04:59.99915+00
464	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 07:00:00+00	32	0.7	63	0.49	30.7	65	2.01	641	2026-11-11 23:04:59.99915+00
465	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 08:00:00+00	33	0.3	83	0.36	29.1	72	2.68	477	2026-11-11 23:04:59.99915+00
466	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 09:00:00+00	34	1.5	92	0.19	26.9	86	1.19	264	2026-11-11 23:04:59.99915+00
467	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 10:00:00+00	35	0.1	83	0.09	26.9	85	0.46	127	2026-11-11 23:04:59.99915+00
468	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 11:00:00+00	36	0	64	0.02	26	91	0.63	27	2026-11-11 23:04:59.99915+00
469	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 12:00:00+00	37	0	47	0	25.9	92	0.71	0	2026-11-11 23:04:59.99915+00
470	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 13:00:00+00	38	0	36	0	25.6	92	0.46	0	2026-11-11 23:04:59.99915+00
471	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 14:00:00+00	39	0	26	0	25.5	91	0.69	0	2026-11-11 23:04:59.99915+00
472	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 15:00:00+00	40	0	20	0	25.3	90	0.35	0	2026-11-11 23:04:59.99915+00
473	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 16:00:00+00	41	0	18	0	24.9	91	0.67	0	2026-11-11 23:04:59.99915+00
474	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 17:00:00+00	42	0	19	0	24.6	91	0.53	0	2026-11-11 23:04:59.99915+00
475	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 18:00:00+00	43	0	20	0	24.1	92	0.46	0	2026-11-11 23:04:59.99915+00
476	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 19:00:00+00	44	0	19	0	24.2	92	0.34	0	2026-11-11 23:04:59.99915+00
477	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 20:00:00+00	45	0	17	0	23.7	90	1.15	0	2026-11-11 23:04:59.99915+00
478	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 21:00:00+00	46	0.1	16	0	23.5	89	0.98	0	2026-11-11 23:04:59.99915+00
479	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 22:00:00+00	47	0	14	0	23.6	89	0.82	0	2026-11-11 23:04:59.99915+00
480	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-11 23:00:00+00	2026-11-13 23:00:00+00	48	0	13	0	24.3	86	0.22	15	2026-11-11 23:04:59.99915+00
481	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 01:00:00+00	1	0	1	0.29	28.4	67	0.76	410	2026-11-12 00:05:00.000676+00
482	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 02:00:00+00	2	0	4	0.44	29.4	65	1.52	591	2026-11-12 00:05:00.000676+00
483	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 03:00:00+00	3	0	10	0.59	30.9	60	2.05	777	2026-11-12 00:05:00.000676+00
484	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 04:00:00+00	4	0.1	19	0.67	32.1	52	2.87	848	2026-11-12 00:05:00.000676+00
485	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 05:00:00+00	5	0.2	31	0.72	32.8	49	3.38	907	2026-11-12 00:05:00.000676+00
486	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 06:00:00+00	6	0.1	45	0.74	33.2	48	3.33	921	2026-11-12 00:05:00.000676+00
487	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 07:00:00+00	7	0	64	0.68	33.6	48	3.06	842	2026-11-12 00:05:00.000676+00
488	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 08:00:00+00	8	0.2	85	0.49	31.4	55	2.62	622	2026-11-12 00:05:00.000676+00
489	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 09:00:00+00	9	5.1	100	0.24	25.9	87	1.35	346	2026-11-12 00:05:00.000676+00
490	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 10:00:00+00	10	7.6	100	0.08	24.9	93	1.91	111	2026-11-12 00:05:00.000676+00
491	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 11:00:00+00	11	0.4	100	0.02	25.2	94	1	22	2026-11-12 00:05:00.000676+00
492	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 12:00:00+00	12	1	98	0	24.7	96	0.41	0	2026-11-12 00:05:00.000676+00
493	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 13:00:00+00	13	0.4	89	0	25	93	0.78	0	2026-11-12 00:05:00.000676+00
494	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 14:00:00+00	14	0.3	77	0	24.9	95	0.05	0	2026-11-12 00:05:00.000676+00
495	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 15:00:00+00	15	0.1	63	0	24.5	98	0.64	0	2026-11-12 00:05:00.000676+00
496	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 16:00:00+00	16	0	46	0	24.4	98	0.25	0	2026-11-12 00:05:00.000676+00
497	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 17:00:00+00	17	0	28	0	24.1	98	0.67	0	2026-11-12 00:05:00.000676+00
498	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 18:00:00+00	18	0	14	0	23.9	97	0.32	0	2026-11-12 00:05:00.000676+00
499	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 19:00:00+00	19	0	8	0	23.8	95	0.22	0	2026-11-12 00:05:00.000676+00
500	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 20:00:00+00	20	0	7	0	23.7	95	0.32	0	2026-11-12 00:05:00.000676+00
501	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 21:00:00+00	21	0	6	0	23.5	93	0.42	0	2026-11-12 00:05:00.000676+00
502	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 22:00:00+00	22	0	4	0	23.6	91	0.07	0	2026-11-12 00:05:00.000676+00
503	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-12 23:00:00+00	23	0	3	0	23.9	91	0.21	14	2026-11-12 00:05:00.000676+00
504	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 00:00:00+00	24	0	2	0.1	25	90	0.18	151	2026-11-12 00:05:00.000676+00
505	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 01:00:00+00	25	0	1	0.24	26.8	81	1.01	349	2026-11-12 00:05:00.000676+00
506	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 02:00:00+00	26	0	2	0.43	28.3	72	1.71	610	2026-11-12 00:05:00.000676+00
507	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 03:00:00+00	27	0	6	0.56	29.3	70	1.23	762	2026-11-12 00:05:00.000676+00
508	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 04:00:00+00	28	0.1	16	0.67	30.7	65	2.06	896	2026-11-12 00:05:00.000676+00
509	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 05:00:00+00	29	0.1	30	0.69	31.3	62	2.15	911	2026-11-12 00:05:00.000676+00
510	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 06:00:00+00	30	0.4	45	0.59	30.2	65	3.33	792	2026-11-12 00:05:00.000676+00
511	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 07:00:00+00	31	0.7	63	0.49	30.7	65	2.01	641	2026-11-12 00:05:00.000676+00
512	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 08:00:00+00	32	0.3	83	0.36	29.1	72	2.68	477	2026-11-12 00:05:00.000676+00
513	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 09:00:00+00	33	1.5	92	0.19	26.9	86	1.19	264	2026-11-12 00:05:00.000676+00
514	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 10:00:00+00	34	0.1	83	0.09	26.9	85	0.46	127	2026-11-12 00:05:00.000676+00
515	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 11:00:00+00	35	0	64	0.02	26	91	0.63	27	2026-11-12 00:05:00.000676+00
516	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 12:00:00+00	36	0	47	0	25.9	92	0.71	0	2026-11-12 00:05:00.000676+00
517	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 13:00:00+00	37	0	36	0	25.6	92	0.46	0	2026-11-12 00:05:00.000676+00
518	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 14:00:00+00	38	0	26	0	25.5	91	0.69	0	2026-11-12 00:05:00.000676+00
519	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 15:00:00+00	39	0	20	0	25.3	90	0.35	0	2026-11-12 00:05:00.000676+00
520	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 16:00:00+00	40	0	18	0	24.9	91	0.67	0	2026-11-12 00:05:00.000676+00
521	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 17:00:00+00	41	0	19	0	24.6	91	0.53	0	2026-11-12 00:05:00.000676+00
522	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 18:00:00+00	42	0	20	0	24.1	92	0.46	0	2026-11-12 00:05:00.000676+00
523	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 19:00:00+00	43	0	19	0	24.2	92	0.34	0	2026-11-12 00:05:00.000676+00
524	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 20:00:00+00	44	0	17	0	23.7	90	1.15	0	2026-11-12 00:05:00.000676+00
525	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 21:00:00+00	45	0.1	16	0	23.5	89	0.98	0	2026-11-12 00:05:00.000676+00
526	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 22:00:00+00	46	0	14	0	23.6	89	0.82	0	2026-11-12 00:05:00.000676+00
527	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-13 23:00:00+00	47	0	13	0	24.3	86	0.22	15	2026-11-12 00:05:00.000676+00
528	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 00:00:00+00	2026-11-14 00:00:00+00	48	0	12	0.1	25.8	81	0.21	155	2026-11-12 00:05:00.000676+00
529	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 02:00:00+00	1	0	4	0.44	29.4	65	1.52	591	2026-11-12 01:05:00.000115+00
530	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 03:00:00+00	2	0	10	0.59	30.9	60	2.05	777	2026-11-12 01:05:00.000115+00
531	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 04:00:00+00	3	0.1	19	0.67	32.1	52	2.87	848	2026-11-12 01:05:00.000115+00
532	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 05:00:00+00	4	0.2	31	0.72	32.8	49	3.38	907	2026-11-12 01:05:00.000115+00
533	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 06:00:00+00	5	0.1	45	0.74	33.2	48	3.33	921	2026-11-12 01:05:00.000115+00
534	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 07:00:00+00	6	0	64	0.68	33.6	48	3.06	842	2026-11-12 01:05:00.000115+00
535	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 08:00:00+00	7	0.2	85	0.49	31.4	55	2.62	622	2026-11-12 01:05:00.000115+00
536	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 09:00:00+00	8	5.1	100	0.24	25.9	87	1.35	346	2026-11-12 01:05:00.000115+00
537	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 10:00:00+00	9	7.6	100	0.08	24.9	93	1.91	111	2026-11-12 01:05:00.000115+00
538	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 11:00:00+00	10	0.4	100	0.02	25.2	94	1	22	2026-11-12 01:05:00.000115+00
539	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 12:00:00+00	11	1	98	0	24.7	96	0.41	0	2026-11-12 01:05:00.000115+00
540	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 13:00:00+00	12	0.4	89	0	25	93	0.78	0	2026-11-12 01:05:00.000115+00
541	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 14:00:00+00	13	0.3	77	0	24.9	95	0.05	0	2026-11-12 01:05:00.000115+00
542	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 15:00:00+00	14	0.1	63	0	24.5	98	0.64	0	2026-11-12 01:05:00.000115+00
543	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 16:00:00+00	15	0	46	0	24.4	98	0.25	0	2026-11-12 01:05:00.000115+00
544	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 17:00:00+00	16	0	28	0	24.1	98	0.67	0	2026-11-12 01:05:00.000115+00
545	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 18:00:00+00	17	0	14	0	23.9	97	0.32	0	2026-11-12 01:05:00.000115+00
546	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 19:00:00+00	18	0	8	0	23.8	95	0.22	0	2026-11-12 01:05:00.000115+00
547	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 20:00:00+00	19	0	7	0	23.7	95	0.32	0	2026-11-12 01:05:00.000115+00
548	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 21:00:00+00	20	0	6	0	23.5	93	0.42	0	2026-11-12 01:05:00.000115+00
549	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 22:00:00+00	21	0	4	0	23.6	91	0.07	0	2026-11-12 01:05:00.000115+00
550	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-12 23:00:00+00	22	0	3	0	23.9	91	0.21	14	2026-11-12 01:05:00.000115+00
551	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 00:00:00+00	23	0	2	0.1	25	90	0.18	151	2026-11-12 01:05:00.000115+00
552	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 01:00:00+00	24	0	1	0.24	26.8	81	1.01	349	2026-11-12 01:05:00.000115+00
553	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 02:00:00+00	25	0	2	0.43	28.3	72	1.71	610	2026-11-12 01:05:00.000115+00
554	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 03:00:00+00	26	0	6	0.56	29.3	70	1.23	762	2026-11-12 01:05:00.000115+00
555	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 04:00:00+00	27	0.1	16	0.67	30.7	65	2.06	896	2026-11-12 01:05:00.000115+00
556	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 05:00:00+00	28	0.1	30	0.69	31.3	62	2.15	911	2026-11-12 01:05:00.000115+00
557	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 06:00:00+00	29	0.4	45	0.59	30.2	65	3.33	792	2026-11-12 01:05:00.000115+00
558	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 07:00:00+00	30	0.7	63	0.49	30.7	65	2.01	641	2026-11-12 01:05:00.000115+00
559	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 08:00:00+00	31	0.3	83	0.36	29.1	72	2.68	477	2026-11-12 01:05:00.000115+00
560	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 09:00:00+00	32	1.5	92	0.19	26.9	86	1.19	264	2026-11-12 01:05:00.000115+00
561	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 10:00:00+00	33	0.1	83	0.09	26.9	85	0.46	127	2026-11-12 01:05:00.000115+00
562	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 11:00:00+00	34	0	64	0.02	26	91	0.63	27	2026-11-12 01:05:00.000115+00
563	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 12:00:00+00	35	0	47	0	25.9	92	0.71	0	2026-11-12 01:05:00.000115+00
564	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 13:00:00+00	36	0	36	0	25.6	92	0.46	0	2026-11-12 01:05:00.000115+00
565	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 14:00:00+00	37	0	26	0	25.5	91	0.69	0	2026-11-12 01:05:00.000115+00
566	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 15:00:00+00	38	0	20	0	25.3	90	0.35	0	2026-11-12 01:05:00.000115+00
567	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 16:00:00+00	39	0	18	0	24.9	91	0.67	0	2026-11-12 01:05:00.000115+00
568	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 17:00:00+00	40	0	19	0	24.6	91	0.53	0	2026-11-12 01:05:00.000115+00
569	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 18:00:00+00	41	0	20	0	24.1	92	0.46	0	2026-11-12 01:05:00.000115+00
570	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 19:00:00+00	42	0	19	0	24.2	92	0.34	0	2026-11-12 01:05:00.000115+00
571	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 20:00:00+00	43	0	17	0	23.7	90	1.15	0	2026-11-12 01:05:00.000115+00
572	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 21:00:00+00	44	0.1	16	0	23.5	89	0.98	0	2026-11-12 01:05:00.000115+00
573	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 22:00:00+00	45	0	14	0	23.6	89	0.82	0	2026-11-12 01:05:00.000115+00
574	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-13 23:00:00+00	46	0	13	0	24.3	86	0.22	15	2026-11-12 01:05:00.000115+00
575	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-14 00:00:00+00	47	0	12	0.1	25.8	81	0.21	155	2026-11-12 01:05:00.000115+00
576	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 01:00:00+00	2026-11-14 01:00:00+00	48	0	11	0.27	27.2	76	1.21	394	2026-11-12 01:05:00.000115+00
577	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 03:00:00+00	1	0.1	10	0.6	31.3	56	2.45	778	2026-11-12 02:05:00.0013+00
578	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 04:00:00+00	2	0.1	19	0.73	32.6	49	3.31	920	2026-11-12 02:05:00.0013+00
579	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 05:00:00+00	3	0.3	31	0.75	32.9	48	3.71	948	2026-11-12 02:05:00.0013+00
580	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 06:00:00+00	4	0.3	45	0.72	32.8	49	3.36	904	2026-11-12 02:05:00.0013+00
581	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 07:00:00+00	5	0.1	64	0.64	33.2	49	2.71	793	2026-11-12 02:05:00.0013+00
582	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 08:00:00+00	6	2.6	85	0.41	28.7	72	3.05	572	2026-11-12 02:05:00.0013+00
583	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 09:00:00+00	7	6.1	100	0.22	27.1	85	1.05	315	2026-11-12 02:05:00.0013+00
584	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 10:00:00+00	8	0.4	100	0.1	26.6	86	1.15	126	2026-11-12 02:05:00.0013+00
585	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 11:00:00+00	9	0.1	100	0.02	25.7	90	0.76	28	2026-11-12 02:05:00.0013+00
586	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 12:00:00+00	10	0.1	98	0	25.3	91	0.3	0	2026-11-12 02:05:00.0013+00
587	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 13:00:00+00	11	0.5	89	0	24.4	97	1.94	0	2026-11-12 02:05:00.0013+00
588	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 14:00:00+00	12	0.2	77	0	24.2	96	0.93	0	2026-11-12 02:05:00.0013+00
589	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 15:00:00+00	13	0.2	63	0	24.3	97	0.95	0	2026-11-12 02:05:00.0013+00
590	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 16:00:00+00	14	0	46	0	24.2	96	0.39	0	2026-11-12 02:05:00.0013+00
591	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 17:00:00+00	15	0	28	0	24	94	0.82	0	2026-11-12 02:05:00.0013+00
592	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 18:00:00+00	16	0	14	0	23.8	93	0.5	0	2026-11-12 02:05:00.0013+00
593	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 19:00:00+00	17	0	8	0	23.9	91	0.27	0	2026-11-12 02:05:00.0013+00
594	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 20:00:00+00	18	0	7	0	23.9	90	0.46	0	2026-11-12 02:05:00.0013+00
595	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 21:00:00+00	19	0	6	0	24	87	0.07	0	2026-11-12 02:05:00.0013+00
596	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 22:00:00+00	20	0	4	0	24	85	0.11	0	2026-11-12 02:05:00.0013+00
597	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-12 23:00:00+00	21	0	3	0.01	24.3	86	0.32	12	2026-11-12 02:05:00.0013+00
598	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 00:00:00+00	22	0	2	0.08	24.7	90	0.36	129	2026-11-12 02:05:00.0013+00
599	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 01:00:00+00	23	0	1	0.2	26.1	83	0.87	291	2026-11-12 02:05:00.0013+00
600	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 02:00:00+00	24	0	2	0.36	27.8	75	1.04	507	2026-11-12 02:05:00.0013+00
601	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 03:00:00+00	25	0	6	0.45	29.4	68	1.54	602	2026-11-12 02:05:00.0013+00
602	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 04:00:00+00	26	0	16	0.55	30.4	65	2.28	720	2026-11-12 02:05:00.0013+00
603	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 05:00:00+00	27	0	30	0.67	31.7	60	2.55	878	2026-11-12 02:05:00.0013+00
604	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 06:00:00+00	28	0.3	45	0.61	31.3	64	2.55	796	2026-11-12 02:05:00.0013+00
605	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 07:00:00+00	29	3.1	63	0.31	28.9	75	1.47	395	2026-11-12 02:05:00.0013+00
606	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 08:00:00+00	30	0	83	0.38	30.1	68	1.35	501	2026-11-12 02:05:00.0013+00
607	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 09:00:00+00	31	3.2	92	0.26	27.6	81	1.68	368	2026-11-12 02:05:00.0013+00
608	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 10:00:00+00	32	0.3	83	0.1	26.4	87	1.67	144	2026-11-12 02:05:00.0013+00
609	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 11:00:00+00	33	0.1	64	0.02	25.8	91	1.24	24	2026-11-12 02:05:00.0013+00
610	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 12:00:00+00	34	0.1	47	0	25.3	94	0.76	0	2026-11-12 02:05:00.0013+00
611	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 13:00:00+00	35	0	36	0	25.3	95	0.36	0	2026-11-12 02:05:00.0013+00
612	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 14:00:00+00	36	0	26	0	25.2	94	0.54	0	2026-11-12 02:05:00.0013+00
613	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 15:00:00+00	37	0	20	0	25	93	0.45	0	2026-11-12 02:05:00.0013+00
614	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 16:00:00+00	38	0	18	0	24.6	91	0.74	0	2026-11-12 02:05:00.0013+00
615	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 17:00:00+00	39	0	19	0	24.2	91	0.68	0	2026-11-12 02:05:00.0013+00
616	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 18:00:00+00	40	0	20	0	23.9	92	0.75	0	2026-11-12 02:05:00.0013+00
617	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 19:00:00+00	41	0	19	0	23.5	92	1.23	0	2026-11-12 02:05:00.0013+00
618	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 20:00:00+00	42	0	17	0	23.4	90	1.27	0	2026-11-12 02:05:00.0013+00
619	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 21:00:00+00	43	0	16	0	23.6	88	0.74	0	2026-11-12 02:05:00.0013+00
620	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 22:00:00+00	44	0	14	0	23.5	88	0.54	0	2026-11-12 02:05:00.0013+00
621	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-13 23:00:00+00	45	0	13	0.01	24.3	85	0.5	15	2026-11-12 02:05:00.0013+00
622	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-14 00:00:00+00	46	0	12	0.1	26.1	79	0.54	161	2026-11-12 02:05:00.0013+00
623	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-14 01:00:00+00	47	0	11	0.27	27.3	76	1.01	380	2026-11-12 02:05:00.0013+00
624	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 02:00:00+00	2026-11-14 02:00:00+00	48	0	11	0.38	28.3	73	1.17	530	2026-11-12 02:05:00.0013+00
625	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 04:00:00+00	1	0.1	23	0.73	32.6	49	3.31	920	2026-11-12 03:04:59.999454+00
626	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 05:00:00+00	2	0.3	49	0.75	32.9	48	3.71	948	2026-11-12 03:04:59.999454+00
627	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 06:00:00+00	3	0.3	71	0.72	32.8	49	3.36	904	2026-11-12 03:04:59.999454+00
628	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 07:00:00+00	4	0.1	84	0.64	33.2	49	2.71	793	2026-11-12 03:04:59.999454+00
629	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 08:00:00+00	5	2.6	93	0.41	28.7	72	3.05	572	2026-11-12 03:04:59.999454+00
630	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 09:00:00+00	6	6.1	98	0.22	27.1	85	1.05	315	2026-11-12 03:04:59.999454+00
631	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 10:00:00+00	7	0.4	99	0.1	26.6	86	1.15	126	2026-11-12 03:04:59.999454+00
632	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 11:00:00+00	8	0.1	97	0.02	25.7	90	0.76	28	2026-11-12 03:04:59.999454+00
633	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 12:00:00+00	9	0.1	92	0	25.3	91	0.3	0	2026-11-12 03:04:59.999454+00
634	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 13:00:00+00	10	0.5	86	0	24.4	97	1.94	0	2026-11-12 03:04:59.999454+00
635	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 14:00:00+00	11	0.2	77	0	24.2	96	0.93	0	2026-11-12 03:04:59.999454+00
636	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 15:00:00+00	12	0.2	65	0	24.3	97	0.95	0	2026-11-12 03:04:59.999454+00
637	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 16:00:00+00	13	0	47	0	24.2	96	0.39	0	2026-11-12 03:04:59.999454+00
638	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 17:00:00+00	14	0	27	0	24	94	0.82	0	2026-11-12 03:04:59.999454+00
639	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 18:00:00+00	15	0	12	0	23.8	93	0.5	0	2026-11-12 03:04:59.999454+00
640	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 19:00:00+00	16	0	8	0	23.9	91	0.27	0	2026-11-12 03:04:59.999454+00
641	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 20:00:00+00	17	0	11	0	23.9	90	0.46	0	2026-11-12 03:04:59.999454+00
642	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 21:00:00+00	18	0	12	0	24	87	0.07	0	2026-11-12 03:04:59.999454+00
643	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 22:00:00+00	19	0	10	0	24	85	0.11	0	2026-11-12 03:04:59.999454+00
644	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-12 23:00:00+00	20	0	7	0.01	24.3	86	0.32	12	2026-11-12 03:04:59.999454+00
645	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 00:00:00+00	21	0	4	0.08	24.7	90	0.36	129	2026-11-12 03:04:59.999454+00
646	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 01:00:00+00	22	0	1	0.2	26.1	83	0.87	291	2026-11-12 03:04:59.999454+00
647	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 02:00:00+00	23	0	0	0.36	27.8	75	1.04	507	2026-11-12 03:04:59.999454+00
648	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 03:00:00+00	24	0	0	0.45	29.4	68	1.54	602	2026-11-12 03:04:59.999454+00
649	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 04:00:00+00	25	0	9	0.55	30.4	65	2.28	720	2026-11-12 03:04:59.999454+00
650	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 05:00:00+00	26	0	23	0.67	31.7	60	2.55	878	2026-11-12 03:04:59.999454+00
651	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 06:00:00+00	27	0.3	39	0.61	31.3	64	2.55	796	2026-11-12 03:04:59.999454+00
652	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 07:00:00+00	28	3.1	61	0.31	28.9	75	1.47	395	2026-11-12 03:04:59.999454+00
653	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 08:00:00+00	29	0	85	0.38	30.1	68	1.35	501	2026-11-12 03:04:59.999454+00
654	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 09:00:00+00	30	3.2	100	0.26	27.6	81	1.68	368	2026-11-12 03:04:59.999454+00
655	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 10:00:00+00	31	0.3	99	0.1	26.4	87	1.67	144	2026-11-12 03:04:59.999454+00
656	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 11:00:00+00	32	0.1	89	0.02	25.8	91	1.24	24	2026-11-12 03:04:59.999454+00
657	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 12:00:00+00	33	0.1	75	0	25.3	94	0.76	0	2026-11-12 03:04:59.999454+00
658	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 13:00:00+00	34	0	56	0	25.3	95	0.36	0	2026-11-12 03:04:59.999454+00
659	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 14:00:00+00	35	0	33	0	25.2	94	0.54	0	2026-11-12 03:04:59.999454+00
660	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 15:00:00+00	36	0	16	0	25	93	0.45	0	2026-11-12 03:04:59.999454+00
661	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 16:00:00+00	37	0	9	0	24.6	91	0.74	0	2026-11-12 03:04:59.999454+00
662	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 17:00:00+00	38	0	7	0	24.2	91	0.68	0	2026-11-12 03:04:59.999454+00
663	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 18:00:00+00	39	0	6	0	23.9	92	0.75	0	2026-11-12 03:04:59.999454+00
664	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 19:00:00+00	40	0	4	0	23.5	92	1.23	0	2026-11-12 03:04:59.999454+00
665	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 20:00:00+00	41	0	3	0	23.4	90	1.27	0	2026-11-12 03:04:59.999454+00
666	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 21:00:00+00	42	0	2	0	23.6	88	0.74	0	2026-11-12 03:04:59.999454+00
667	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 22:00:00+00	43	0	2	0	23.5	88	0.54	0	2026-11-12 03:04:59.999454+00
668	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-13 23:00:00+00	44	0	3	0.01	24.3	85	0.5	15	2026-11-12 03:04:59.999454+00
669	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-14 00:00:00+00	45	0	4	0.1	26.1	79	0.54	161	2026-11-12 03:04:59.999454+00
670	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-14 01:00:00+00	46	0	4	0.27	27.3	76	1.01	380	2026-11-12 03:04:59.999454+00
671	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-14 02:00:00+00	47	0	4	0.38	28.3	73	1.17	530	2026-11-12 03:04:59.999454+00
672	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 03:00:00+00	2026-11-14 03:00:00+00	48	0	8	0.55	29.4	72	1.99	754	2026-11-12 03:04:59.999454+00
673	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 05:00:00+00	1	0.3	49	0.75	32.9	48	3.71	948	2026-11-12 04:04:59.999118+00
674	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 06:00:00+00	2	0.3	71	0.72	32.8	49	3.36	904	2026-11-12 04:04:59.999118+00
675	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 07:00:00+00	3	0.1	84	0.64	33.2	49	2.71	793	2026-11-12 04:04:59.999118+00
676	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 08:00:00+00	4	2.6	93	0.41	28.7	72	3.05	572	2026-11-12 04:04:59.999118+00
677	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 09:00:00+00	5	6.1	98	0.22	27.1	85	1.05	315	2026-11-12 04:04:59.999118+00
678	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 10:00:00+00	6	0.4	99	0.1	26.6	86	1.15	126	2026-11-12 04:04:59.999118+00
679	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 11:00:00+00	7	0.1	97	0.02	25.7	90	0.76	28	2026-11-12 04:04:59.999118+00
680	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 12:00:00+00	8	0.1	92	0	25.3	91	0.3	0	2026-11-12 04:04:59.999118+00
681	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 13:00:00+00	9	0.5	86	0	24.4	97	1.94	0	2026-11-12 04:04:59.999118+00
682	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 14:00:00+00	10	0.2	77	0	24.2	96	0.93	0	2026-11-12 04:04:59.999118+00
683	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 15:00:00+00	11	0.2	65	0	24.3	97	0.95	0	2026-11-12 04:04:59.999118+00
684	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 16:00:00+00	12	0	47	0	24.2	96	0.39	0	2026-11-12 04:04:59.999118+00
685	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 17:00:00+00	13	0	27	0	24	94	0.82	0	2026-11-12 04:04:59.999118+00
686	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 18:00:00+00	14	0	12	0	23.8	93	0.5	0	2026-11-12 04:04:59.999118+00
687	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 19:00:00+00	15	0	8	0	23.9	91	0.27	0	2026-11-12 04:04:59.999118+00
688	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 20:00:00+00	16	0	11	0	23.9	90	0.46	0	2026-11-12 04:04:59.999118+00
689	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 21:00:00+00	17	0	12	0	24	87	0.07	0	2026-11-12 04:04:59.999118+00
690	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 22:00:00+00	18	0	10	0	24	85	0.11	0	2026-11-12 04:04:59.999118+00
691	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-12 23:00:00+00	19	0	7	0.01	24.3	86	0.32	12	2026-11-12 04:04:59.999118+00
692	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 00:00:00+00	20	0	4	0.08	24.7	90	0.36	129	2026-11-12 04:04:59.999118+00
693	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 01:00:00+00	21	0	1	0.2	26.1	83	0.87	291	2026-11-12 04:04:59.999118+00
694	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 02:00:00+00	22	0	0	0.36	27.8	75	1.04	507	2026-11-12 04:04:59.999118+00
695	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 03:00:00+00	23	0	0	0.45	29.4	68	1.54	602	2026-11-12 04:04:59.999118+00
696	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 04:00:00+00	24	0	9	0.55	30.4	65	2.28	720	2026-11-12 04:04:59.999118+00
697	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 05:00:00+00	25	0	23	0.67	31.7	60	2.55	878	2026-11-12 04:04:59.999118+00
698	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 06:00:00+00	26	0.3	39	0.61	31.3	64	2.55	796	2026-11-12 04:04:59.999118+00
699	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 07:00:00+00	27	3.1	61	0.31	28.9	75	1.47	395	2026-11-12 04:04:59.999118+00
700	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 08:00:00+00	28	0	85	0.38	30.1	68	1.35	501	2026-11-12 04:04:59.999118+00
701	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 09:00:00+00	29	3.2	100	0.26	27.6	81	1.68	368	2026-11-12 04:04:59.999118+00
702	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 10:00:00+00	30	0.3	99	0.1	26.4	87	1.67	144	2026-11-12 04:04:59.999118+00
703	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 11:00:00+00	31	0.1	89	0.02	25.8	91	1.24	24	2026-11-12 04:04:59.999118+00
704	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 12:00:00+00	32	0.1	75	0	25.3	94	0.76	0	2026-11-12 04:04:59.999118+00
705	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 13:00:00+00	33	0	56	0	25.3	95	0.36	0	2026-11-12 04:04:59.999118+00
706	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 14:00:00+00	34	0	33	0	25.2	94	0.54	0	2026-11-12 04:04:59.999118+00
707	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 15:00:00+00	35	0	16	0	25	93	0.45	0	2026-11-12 04:04:59.999118+00
708	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 16:00:00+00	36	0	9	0	24.6	91	0.74	0	2026-11-12 04:04:59.999118+00
709	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 17:00:00+00	37	0	7	0	24.2	91	0.68	0	2026-11-12 04:04:59.999118+00
710	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 18:00:00+00	38	0	6	0	23.9	92	0.75	0	2026-11-12 04:04:59.999118+00
711	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 19:00:00+00	39	0	4	0	23.5	92	1.23	0	2026-11-12 04:04:59.999118+00
712	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 20:00:00+00	40	0	3	0	23.4	90	1.27	0	2026-11-12 04:04:59.999118+00
713	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 21:00:00+00	41	0	2	0	23.6	88	0.74	0	2026-11-12 04:04:59.999118+00
714	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 22:00:00+00	42	0	2	0	23.5	88	0.54	0	2026-11-12 04:04:59.999118+00
715	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-13 23:00:00+00	43	0	3	0.01	24.3	85	0.5	15	2026-11-12 04:04:59.999118+00
716	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-14 00:00:00+00	44	0	4	0.1	26.1	79	0.54	161	2026-11-12 04:04:59.999118+00
717	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-14 01:00:00+00	45	0	4	0.27	27.3	76	1.01	380	2026-11-12 04:04:59.999118+00
718	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-14 02:00:00+00	46	0	4	0.38	28.3	73	1.17	530	2026-11-12 04:04:59.999118+00
719	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-14 03:00:00+00	47	0	8	0.55	29.4	72	1.99	754	2026-11-12 04:04:59.999118+00
720	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 04:00:00+00	2026-11-14 04:00:00+00	48	0	19	0.61	29.6	73	1.31	829	2026-11-12 04:04:59.999118+00
721	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 06:00:00+00	1	0.3	71	0.72	32.8	49	3.36	904	2026-11-12 05:04:59.999848+00
722	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 07:00:00+00	2	0.1	84	0.64	33.2	49	2.71	793	2026-11-12 05:04:59.999848+00
723	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 08:00:00+00	3	2.6	93	0.41	28.7	72	3.05	572	2026-11-12 05:04:59.999848+00
724	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 09:00:00+00	4	6.1	98	0.22	27.1	85	1.05	315	2026-11-12 05:04:59.999848+00
725	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 10:00:00+00	5	0.4	99	0.1	26.6	86	1.15	126	2026-11-12 05:04:59.999848+00
726	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 11:00:00+00	6	0.1	97	0.02	25.7	90	0.76	28	2026-11-12 05:04:59.999848+00
727	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 12:00:00+00	7	0.1	92	0	25.3	91	0.3	0	2026-11-12 05:04:59.999848+00
728	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 13:00:00+00	8	0.5	86	0	24.4	97	1.94	0	2026-11-12 05:04:59.999848+00
729	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 14:00:00+00	9	0.2	77	0	24.2	96	0.93	0	2026-11-12 05:04:59.999848+00
730	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 15:00:00+00	10	0.2	65	0	24.3	97	0.95	0	2026-11-12 05:04:59.999848+00
731	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 16:00:00+00	11	0	47	0	24.2	96	0.39	0	2026-11-12 05:04:59.999848+00
732	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 17:00:00+00	12	0	27	0	24	94	0.82	0	2026-11-12 05:04:59.999848+00
733	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 18:00:00+00	13	0	12	0	23.8	93	0.5	0	2026-11-12 05:04:59.999848+00
734	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 19:00:00+00	14	0	8	0	23.9	91	0.27	0	2026-11-12 05:04:59.999848+00
735	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 20:00:00+00	15	0	11	0	23.9	90	0.46	0	2026-11-12 05:04:59.999848+00
736	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 21:00:00+00	16	0	12	0	24	87	0.07	0	2026-11-12 05:04:59.999848+00
737	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 22:00:00+00	17	0	10	0	24	85	0.11	0	2026-11-12 05:04:59.999848+00
738	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-12 23:00:00+00	18	0	7	0.01	24.3	86	0.32	12	2026-11-12 05:04:59.999848+00
739	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 00:00:00+00	19	0	4	0.08	24.7	90	0.36	129	2026-11-12 05:04:59.999848+00
740	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 01:00:00+00	20	0	1	0.2	26.1	83	0.87	291	2026-11-12 05:04:59.999848+00
741	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 02:00:00+00	21	0	0	0.36	27.8	75	1.04	507	2026-11-12 05:04:59.999848+00
742	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 03:00:00+00	22	0	0	0.45	29.4	68	1.54	602	2026-11-12 05:04:59.999848+00
743	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 04:00:00+00	23	0	9	0.55	30.4	65	2.28	720	2026-11-12 05:04:59.999848+00
744	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 05:00:00+00	24	0	23	0.67	31.7	60	2.55	878	2026-11-12 05:04:59.999848+00
745	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 06:00:00+00	25	0.3	39	0.61	31.3	64	2.55	796	2026-11-12 05:04:59.999848+00
746	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 07:00:00+00	26	3.1	61	0.31	28.9	75	1.47	395	2026-11-12 05:04:59.999848+00
747	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 08:00:00+00	27	0	85	0.38	30.1	68	1.35	501	2026-11-12 05:04:59.999848+00
748	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 09:00:00+00	28	3.2	100	0.26	27.6	81	1.68	368	2026-11-12 05:04:59.999848+00
749	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 10:00:00+00	29	0.3	99	0.1	26.4	87	1.67	144	2026-11-12 05:04:59.999848+00
750	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 11:00:00+00	30	0.1	89	0.02	25.8	91	1.24	24	2026-11-12 05:04:59.999848+00
751	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 12:00:00+00	31	0.1	75	0	25.3	94	0.76	0	2026-11-12 05:04:59.999848+00
752	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 13:00:00+00	32	0	56	0	25.3	95	0.36	0	2026-11-12 05:04:59.999848+00
753	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 14:00:00+00	33	0	33	0	25.2	94	0.54	0	2026-11-12 05:04:59.999848+00
754	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 15:00:00+00	34	0	16	0	25	93	0.45	0	2026-11-12 05:04:59.999848+00
755	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 16:00:00+00	35	0	9	0	24.6	91	0.74	0	2026-11-12 05:04:59.999848+00
756	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 17:00:00+00	36	0	7	0	24.2	91	0.68	0	2026-11-12 05:04:59.999848+00
757	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 18:00:00+00	37	0	6	0	23.9	92	0.75	0	2026-11-12 05:04:59.999848+00
758	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 19:00:00+00	38	0	4	0	23.5	92	1.23	0	2026-11-12 05:04:59.999848+00
759	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 20:00:00+00	39	0	3	0	23.4	90	1.27	0	2026-11-12 05:04:59.999848+00
760	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 21:00:00+00	40	0	2	0	23.6	88	0.74	0	2026-11-12 05:04:59.999848+00
761	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 22:00:00+00	41	0	2	0	23.5	88	0.54	0	2026-11-12 05:04:59.999848+00
762	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-13 23:00:00+00	42	0	3	0.01	24.3	85	0.5	15	2026-11-12 05:04:59.999848+00
763	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-14 00:00:00+00	43	0	4	0.1	26.1	79	0.54	161	2026-11-12 05:04:59.999848+00
764	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-14 01:00:00+00	44	0	4	0.27	27.3	76	1.01	380	2026-11-12 05:04:59.999848+00
765	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-14 02:00:00+00	45	0	4	0.38	28.3	73	1.17	530	2026-11-12 05:04:59.999848+00
766	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-14 03:00:00+00	46	0	8	0.55	29.4	72	1.99	754	2026-11-12 05:04:59.999848+00
767	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-14 04:00:00+00	47	0	19	0.61	29.6	73	1.31	829	2026-11-12 05:04:59.999848+00
768	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 05:00:00+00	2026-11-14 05:00:00+00	48	0	34	0.71	31.4	67	1.2	931	2026-11-12 05:04:59.999848+00
769	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 07:00:00+00	1	0.1	84	0.64	33.2	49	2.71	793	2026-11-12 06:05:00.000707+00
770	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 08:00:00+00	2	2.6	93	0.41	28.7	72	3.05	572	2026-11-12 06:05:00.000707+00
771	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 09:00:00+00	3	6.1	98	0.22	27.1	85	1.05	315	2026-11-12 06:05:00.000707+00
772	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 10:00:00+00	4	0.4	99	0.1	26.6	86	1.15	126	2026-11-12 06:05:00.000707+00
773	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 11:00:00+00	5	0.1	97	0.02	25.7	90	0.76	28	2026-11-12 06:05:00.000707+00
774	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 12:00:00+00	6	0.1	92	0	25.3	91	0.3	0	2026-11-12 06:05:00.000707+00
775	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 13:00:00+00	7	0.5	86	0	24.4	97	1.94	0	2026-11-12 06:05:00.000707+00
776	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 14:00:00+00	8	0.2	77	0	24.2	96	0.93	0	2026-11-12 06:05:00.000707+00
777	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 15:00:00+00	9	0.2	65	0	24.3	97	0.95	0	2026-11-12 06:05:00.000707+00
778	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 16:00:00+00	10	0	47	0	24.2	96	0.39	0	2026-11-12 06:05:00.000707+00
779	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 17:00:00+00	11	0	27	0	24	94	0.82	0	2026-11-12 06:05:00.000707+00
780	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 18:00:00+00	12	0	12	0	23.8	93	0.5	0	2026-11-12 06:05:00.000707+00
781	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 19:00:00+00	13	0	8	0	23.9	91	0.27	0	2026-11-12 06:05:00.000707+00
782	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 20:00:00+00	14	0	11	0	23.9	90	0.46	0	2026-11-12 06:05:00.000707+00
783	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 21:00:00+00	15	0	12	0	24	87	0.07	0	2026-11-12 06:05:00.000707+00
784	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 22:00:00+00	16	0	10	0	24	85	0.11	0	2026-11-12 06:05:00.000707+00
785	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-12 23:00:00+00	17	0	7	0.01	24.3	86	0.32	12	2026-11-12 06:05:00.000707+00
786	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 00:00:00+00	18	0	4	0.08	24.7	90	0.36	129	2026-11-12 06:05:00.000707+00
787	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 01:00:00+00	19	0	1	0.2	26.1	83	0.87	291	2026-11-12 06:05:00.000707+00
788	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 02:00:00+00	20	0	0	0.36	27.8	75	1.04	507	2026-11-12 06:05:00.000707+00
789	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 03:00:00+00	21	0	0	0.45	29.4	68	1.54	602	2026-11-12 06:05:00.000707+00
790	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 04:00:00+00	22	0	9	0.55	30.4	65	2.28	720	2026-11-12 06:05:00.000707+00
791	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 05:00:00+00	23	0	23	0.67	31.7	60	2.55	878	2026-11-12 06:05:00.000707+00
792	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 06:00:00+00	24	0.3	39	0.61	31.3	64	2.55	796	2026-11-12 06:05:00.000707+00
793	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 07:00:00+00	25	3.1	61	0.31	28.9	75	1.47	395	2026-11-12 06:05:00.000707+00
794	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 08:00:00+00	26	0	85	0.38	30.1	68	1.35	501	2026-11-12 06:05:00.000707+00
795	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 09:00:00+00	27	3.2	100	0.26	27.6	81	1.68	368	2026-11-12 06:05:00.000707+00
796	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 10:00:00+00	28	0.3	99	0.1	26.4	87	1.67	144	2026-11-12 06:05:00.000707+00
797	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 11:00:00+00	29	0.1	89	0.02	25.8	91	1.24	24	2026-11-12 06:05:00.000707+00
798	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 12:00:00+00	30	0.1	75	0	25.3	94	0.76	0	2026-11-12 06:05:00.000707+00
799	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 13:00:00+00	31	0	56	0	25.3	95	0.36	0	2026-11-12 06:05:00.000707+00
800	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 14:00:00+00	32	0	33	0	25.2	94	0.54	0	2026-11-12 06:05:00.000707+00
801	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 15:00:00+00	33	0	16	0	25	93	0.45	0	2026-11-12 06:05:00.000707+00
802	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 16:00:00+00	34	0	9	0	24.6	91	0.74	0	2026-11-12 06:05:00.000707+00
803	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 17:00:00+00	35	0	7	0	24.2	91	0.68	0	2026-11-12 06:05:00.000707+00
804	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 18:00:00+00	36	0	6	0	23.9	92	0.75	0	2026-11-12 06:05:00.000707+00
805	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 19:00:00+00	37	0	4	0	23.5	92	1.23	0	2026-11-12 06:05:00.000707+00
806	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 20:00:00+00	38	0	3	0	23.4	90	1.27	0	2026-11-12 06:05:00.000707+00
807	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 21:00:00+00	39	0	2	0	23.6	88	0.74	0	2026-11-12 06:05:00.000707+00
808	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 22:00:00+00	40	0	2	0	23.5	88	0.54	0	2026-11-12 06:05:00.000707+00
809	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-13 23:00:00+00	41	0	3	0.01	24.3	85	0.5	15	2026-11-12 06:05:00.000707+00
810	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-14 00:00:00+00	42	0	4	0.1	26.1	79	0.54	161	2026-11-12 06:05:00.000707+00
811	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-14 01:00:00+00	43	0	4	0.27	27.3	76	1.01	380	2026-11-12 06:05:00.000707+00
812	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-14 02:00:00+00	44	0	4	0.38	28.3	73	1.17	530	2026-11-12 06:05:00.000707+00
813	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-14 03:00:00+00	45	0	8	0.55	29.4	72	1.99	754	2026-11-12 06:05:00.000707+00
814	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-14 04:00:00+00	46	0	19	0.61	29.6	73	1.31	829	2026-11-12 06:05:00.000707+00
815	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-14 05:00:00+00	47	0	34	0.71	31.4	67	1.2	931	2026-11-12 06:05:00.000707+00
816	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 06:00:00+00	2026-11-14 06:00:00+00	48	0.1	49	0.62	31.8	63	2.34	810	2026-11-12 06:05:00.000707+00
817	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 08:00:00+00	1	2.6	93	0.41	28.7	72	3.05	572	2026-11-12 07:04:59.999156+00
818	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 09:00:00+00	2	6.1	98	0.22	27.1	85	1.05	315	2026-11-12 07:04:59.999156+00
819	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 10:00:00+00	3	0.4	99	0.1	26.6	86	1.15	126	2026-11-12 07:04:59.999156+00
820	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 11:00:00+00	4	0.1	97	0.02	25.7	90	0.76	28	2026-11-12 07:04:59.999156+00
821	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 12:00:00+00	5	0.1	92	0	25.3	91	0.3	0	2026-11-12 07:04:59.999156+00
822	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 13:00:00+00	6	0.5	86	0	24.4	97	1.94	0	2026-11-12 07:04:59.999156+00
823	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 14:00:00+00	7	0.2	77	0	24.2	96	0.93	0	2026-11-12 07:04:59.999156+00
824	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 15:00:00+00	8	0.2	65	0	24.3	97	0.95	0	2026-11-12 07:04:59.999156+00
825	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 16:00:00+00	9	0	47	0	24.2	96	0.39	0	2026-11-12 07:04:59.999156+00
826	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 17:00:00+00	10	0	27	0	24	94	0.82	0	2026-11-12 07:04:59.999156+00
827	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 18:00:00+00	11	0	12	0	23.8	93	0.5	0	2026-11-12 07:04:59.999156+00
828	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 19:00:00+00	12	0	8	0	23.9	91	0.27	0	2026-11-12 07:04:59.999156+00
829	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 20:00:00+00	13	0	11	0	23.9	90	0.46	0	2026-11-12 07:04:59.999156+00
830	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 21:00:00+00	14	0	12	0	24	87	0.07	0	2026-11-12 07:04:59.999156+00
831	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 22:00:00+00	15	0	10	0	24	85	0.11	0	2026-11-12 07:04:59.999156+00
832	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-12 23:00:00+00	16	0	7	0.01	24.3	86	0.32	12	2026-11-12 07:04:59.999156+00
833	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 00:00:00+00	17	0	4	0.08	24.7	90	0.36	129	2026-11-12 07:04:59.999156+00
834	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 01:00:00+00	18	0	1	0.2	26.1	83	0.87	291	2026-11-12 07:04:59.999156+00
835	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 02:00:00+00	19	0	0	0.36	27.8	75	1.04	507	2026-11-12 07:04:59.999156+00
836	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 03:00:00+00	20	0	0	0.45	29.4	68	1.54	602	2026-11-12 07:04:59.999156+00
837	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 04:00:00+00	21	0	9	0.55	30.4	65	2.28	720	2026-11-12 07:04:59.999156+00
838	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 05:00:00+00	22	0	23	0.67	31.7	60	2.55	878	2026-11-12 07:04:59.999156+00
839	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 06:00:00+00	23	0.3	39	0.61	31.3	64	2.55	796	2026-11-12 07:04:59.999156+00
840	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 07:00:00+00	24	3.1	61	0.31	28.9	75	1.47	395	2026-11-12 07:04:59.999156+00
841	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 08:00:00+00	25	0	85	0.38	30.1	68	1.35	501	2026-11-12 07:04:59.999156+00
842	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 09:00:00+00	26	3.2	100	0.26	27.6	81	1.68	368	2026-11-12 07:04:59.999156+00
843	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 10:00:00+00	27	0.3	99	0.1	26.4	87	1.67	144	2026-11-12 07:04:59.999156+00
844	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 11:00:00+00	28	0.1	89	0.02	25.8	91	1.24	24	2026-11-12 07:04:59.999156+00
845	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 12:00:00+00	29	0.1	75	0	25.3	94	0.76	0	2026-11-12 07:04:59.999156+00
846	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 13:00:00+00	30	0	56	0	25.3	95	0.36	0	2026-11-12 07:04:59.999156+00
847	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 14:00:00+00	31	0	33	0	25.2	94	0.54	0	2026-11-12 07:04:59.999156+00
848	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 15:00:00+00	32	0	16	0	25	93	0.45	0	2026-11-12 07:04:59.999156+00
849	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 16:00:00+00	33	0	9	0	24.6	91	0.74	0	2026-11-12 07:04:59.999156+00
850	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 17:00:00+00	34	0	7	0	24.2	91	0.68	0	2026-11-12 07:04:59.999156+00
851	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 18:00:00+00	35	0	6	0	23.9	92	0.75	0	2026-11-12 07:04:59.999156+00
852	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 19:00:00+00	36	0	4	0	23.5	92	1.23	0	2026-11-12 07:04:59.999156+00
853	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 20:00:00+00	37	0	3	0	23.4	90	1.27	0	2026-11-12 07:04:59.999156+00
854	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 21:00:00+00	38	0	2	0	23.6	88	0.74	0	2026-11-12 07:04:59.999156+00
855	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 22:00:00+00	39	0	2	0	23.5	88	0.54	0	2026-11-12 07:04:59.999156+00
856	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-13 23:00:00+00	40	0	3	0.01	24.3	85	0.5	15	2026-11-12 07:04:59.999156+00
857	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-14 00:00:00+00	41	0	4	0.1	26.1	79	0.54	161	2026-11-12 07:04:59.999156+00
858	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-14 01:00:00+00	42	0	4	0.27	27.3	76	1.01	380	2026-11-12 07:04:59.999156+00
859	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-14 02:00:00+00	43	0	4	0.38	28.3	73	1.17	530	2026-11-12 07:04:59.999156+00
860	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-14 03:00:00+00	44	0	8	0.55	29.4	72	1.99	754	2026-11-12 07:04:59.999156+00
861	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-14 04:00:00+00	45	0	19	0.61	29.6	73	1.31	829	2026-11-12 07:04:59.999156+00
862	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-14 05:00:00+00	46	0	34	0.71	31.4	67	1.2	931	2026-11-12 07:04:59.999156+00
863	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-14 06:00:00+00	47	0.1	49	0.62	31.8	63	2.34	810	2026-11-12 07:04:59.999156+00
864	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 07:00:00+00	2026-11-14 07:00:00+00	48	1.7	67	0.41	29.9	75	1	539	2026-11-12 07:04:59.999156+00
865	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 09:00:00+00	1	1.1	98	0.25	27	81	1.56	347	2026-11-12 08:05:00.00058+00
866	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 10:00:00+00	2	1.2	99	0.11	25.7	90	1.07	156	2026-11-12 08:05:00.00058+00
867	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 11:00:00+00	3	0.7	97	0.02	24.8	97	2.05	24	2026-11-12 08:05:00.00058+00
868	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 12:00:00+00	4	0.1	92	0	24.6	95	0.25	0	2026-11-12 08:05:00.00058+00
869	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 13:00:00+00	5	0	86	0	24.7	96	0.59	0	2026-11-12 08:05:00.00058+00
870	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 14:00:00+00	6	0	77	0	25	94	0.21	0	2026-11-12 08:05:00.00058+00
871	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 15:00:00+00	7	0	65	0	25	93	0.07	0	2026-11-12 08:05:00.00058+00
872	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 16:00:00+00	8	0	47	0	24.7	95	0.35	0	2026-11-12 08:05:00.00058+00
873	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 17:00:00+00	9	0	27	0	24.4	96	0.5	0	2026-11-12 08:05:00.00058+00
874	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 18:00:00+00	10	0	12	0	24	96	0.65	0	2026-11-12 08:05:00.00058+00
875	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 19:00:00+00	11	0	8	0	23.4	97	0.14	0	2026-11-12 08:05:00.00058+00
876	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 20:00:00+00	12	0	11	0	23.4	95	0.35	0	2026-11-12 08:05:00.00058+00
877	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 21:00:00+00	13	0	12	0	23.4	93	0.86	0	2026-11-12 08:05:00.00058+00
878	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 22:00:00+00	14	0	10	0	23.6	91	0.2	0	2026-11-12 08:05:00.00058+00
879	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-12 23:00:00+00	15	0	7	0.01	24.3	89	0.52	14	2026-11-12 08:05:00.00058+00
880	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 00:00:00+00	16	0	4	0.08	25.4	85	0.41	124	2026-11-12 08:05:00.00058+00
881	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 01:00:00+00	17	0	1	0.24	26.8	79	0.87	347	2026-11-12 08:05:00.00058+00
882	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 02:00:00+00	18	0	0	0.37	27.8	76	1.86	521	2026-11-12 08:05:00.00058+00
883	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 03:00:00+00	19	0.1	0	0.4	28.3	75	0.3	544	2026-11-12 08:05:00.00058+00
884	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 04:00:00+00	20	0	9	0.48	29.5	70	1.2	637	2026-11-12 08:05:00.00058+00
885	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 05:00:00+00	21	0.6	23	0.55	29.7	69	2.67	740	2026-11-12 08:05:00.00058+00
886	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 06:00:00+00	22	0.3	39	0.48	29.6	70	0.16	637	2026-11-12 08:05:00.00058+00
887	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 07:00:00+00	23	0	61	0.34	29.2	72	1.41	438	2026-11-12 08:05:00.00058+00
888	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 08:00:00+00	24	1.7	85	0.24	26.6	86	1.98	334	2026-11-12 08:05:00.00058+00
889	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 09:00:00+00	25	2.6	100	0.12	25.8	93	1.71	169	2026-11-12 08:05:00.00058+00
890	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 10:00:00+00	26	0.3	99	0.08	25.5	93	1.15	105	2026-11-12 08:05:00.00058+00
891	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 11:00:00+00	27	0.1	89	0.02	25.1	96	0.64	17	2026-11-12 08:05:00.00058+00
892	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 12:00:00+00	28	0	75	0	25.1	96	0.63	0	2026-11-12 08:05:00.00058+00
893	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 13:00:00+00	29	0	56	0	25.2	94	0.11	0	2026-11-12 08:05:00.00058+00
894	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 14:00:00+00	30	0	33	0	25	93	0.21	0	2026-11-12 08:05:00.00058+00
895	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 15:00:00+00	31	0	16	0	24.9	92	0.25	0	2026-11-12 08:05:00.00058+00
896	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 16:00:00+00	32	0	9	0	24.7	91	0.36	0	2026-11-12 08:05:00.00058+00
897	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 17:00:00+00	33	0	7	0	24.2	91	0.67	0	2026-11-12 08:05:00.00058+00
898	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 18:00:00+00	34	0	6	0	24.1	90	0.69	0	2026-11-12 08:05:00.00058+00
899	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 19:00:00+00	35	0	4	0	23.8	90	0.65	0	2026-11-12 08:05:00.00058+00
900	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 20:00:00+00	36	0	3	0	23.7	90	0.61	0	2026-11-12 08:05:00.00058+00
901	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 21:00:00+00	37	0	2	0	23.7	89	0.67	0	2026-11-12 08:05:00.00058+00
902	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 22:00:00+00	38	0	2	0	23.4	91	0.45	0	2026-11-12 08:05:00.00058+00
903	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-13 23:00:00+00	39	0.1	3	0.01	24	88	0.32	13	2026-11-12 08:05:00.00058+00
904	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 00:00:00+00	40	0	4	0.1	24.6	89	1.09	150	2026-11-12 08:05:00.00058+00
905	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 01:00:00+00	41	0	4	0.25	26.1	83	0.68	368	2026-11-12 08:05:00.00058+00
906	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 02:00:00+00	42	0	4	0.43	28.4	71	0.92	600	2026-11-12 08:05:00.00058+00
907	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 03:00:00+00	43	0	8	0.53	29.4	69	1.84	720	2026-11-12 08:05:00.00058+00
908	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 04:00:00+00	44	0.2	19	0.46	28.5	74	1.7	621	2026-11-12 08:05:00.00058+00
909	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 05:00:00+00	45	0.1	34	0.61	29.8	70	0.32	807	2026-11-12 08:05:00.00058+00
910	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 06:00:00+00	46	0.1	49	0.63	30.4	68	0.9	843	2026-11-12 08:05:00.00058+00
911	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 07:00:00+00	47	0.3	67	0.44	28.9	74	1.8	591	2026-11-12 08:05:00.00058+00
912	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 08:00:00+00	2026-11-14 08:00:00+00	48	2.1	86	0.22	26.2	89	0.67	296	2026-11-12 08:05:00.00058+00
913	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 10:00:00+00	1	1.2	99	0.11	25.7	90	1.07	156	2026-11-12 09:05:00.001186+00
914	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 11:00:00+00	2	0.7	97	0.02	24.8	97	2.05	24	2026-11-12 09:05:00.001186+00
915	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 12:00:00+00	3	0.1	92	0	24.6	95	0.25	0	2026-11-12 09:05:00.001186+00
916	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 13:00:00+00	4	0	86	0	24.7	96	0.59	0	2026-11-12 09:05:00.001186+00
917	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 14:00:00+00	5	0	77	0	25	94	0.21	0	2026-11-12 09:05:00.001186+00
918	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 15:00:00+00	6	0	65	0	25	93	0.07	0	2026-11-12 09:05:00.001186+00
919	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 16:00:00+00	7	0	47	0	24.7	95	0.35	0	2026-11-12 09:05:00.001186+00
920	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 17:00:00+00	8	0	27	0	24.4	96	0.5	0	2026-11-12 09:05:00.001186+00
921	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 18:00:00+00	9	0	12	0	24	96	0.65	0	2026-11-12 09:05:00.001186+00
922	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 19:00:00+00	10	0	8	0	23.4	97	0.14	0	2026-11-12 09:05:00.001186+00
923	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 20:00:00+00	11	0	11	0	23.4	95	0.35	0	2026-11-12 09:05:00.001186+00
924	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 21:00:00+00	12	0	12	0	23.4	93	0.86	0	2026-11-12 09:05:00.001186+00
925	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 22:00:00+00	13	0	10	0	23.6	91	0.2	0	2026-11-12 09:05:00.001186+00
926	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-12 23:00:00+00	14	0	7	0.01	24.3	89	0.52	14	2026-11-12 09:05:00.001186+00
927	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 00:00:00+00	15	0	4	0.08	25.4	85	0.41	124	2026-11-12 09:05:00.001186+00
928	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 01:00:00+00	16	0	1	0.24	26.8	79	0.87	347	2026-11-12 09:05:00.001186+00
929	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 02:00:00+00	17	0	0	0.37	27.8	76	1.86	521	2026-11-12 09:05:00.001186+00
930	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 03:00:00+00	18	0.1	0	0.4	28.3	75	0.3	544	2026-11-12 09:05:00.001186+00
931	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 04:00:00+00	19	0	9	0.48	29.5	70	1.2	637	2026-11-12 09:05:00.001186+00
932	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 05:00:00+00	20	0.6	23	0.55	29.7	69	2.67	740	2026-11-12 09:05:00.001186+00
933	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 06:00:00+00	21	0.3	39	0.48	29.6	70	0.16	637	2026-11-12 09:05:00.001186+00
934	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 07:00:00+00	22	0	61	0.34	29.2	72	1.41	438	2026-11-12 09:05:00.001186+00
935	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 08:00:00+00	23	1.7	85	0.24	26.6	86	1.98	334	2026-11-12 09:05:00.001186+00
936	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 09:00:00+00	24	2.6	100	0.12	25.8	93	1.71	169	2026-11-12 09:05:00.001186+00
937	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 10:00:00+00	25	0.3	99	0.08	25.5	93	1.15	105	2026-11-12 09:05:00.001186+00
938	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 11:00:00+00	26	0.1	89	0.02	25.1	96	0.64	17	2026-11-12 09:05:00.001186+00
939	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 12:00:00+00	27	0	75	0	25.1	96	0.63	0	2026-11-12 09:05:00.001186+00
940	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 13:00:00+00	28	0	56	0	25.2	94	0.11	0	2026-11-12 09:05:00.001186+00
941	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 14:00:00+00	29	0	33	0	25	93	0.21	0	2026-11-12 09:05:00.001186+00
942	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 15:00:00+00	30	0	16	0	24.9	92	0.25	0	2026-11-12 09:05:00.001186+00
943	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 16:00:00+00	31	0	9	0	24.7	91	0.36	0	2026-11-12 09:05:00.001186+00
944	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 17:00:00+00	32	0	7	0	24.2	91	0.67	0	2026-11-12 09:05:00.001186+00
945	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 18:00:00+00	33	0	6	0	24.1	90	0.69	0	2026-11-12 09:05:00.001186+00
946	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 19:00:00+00	34	0	4	0	23.8	90	0.65	0	2026-11-12 09:05:00.001186+00
947	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 20:00:00+00	35	0	3	0	23.7	90	0.61	0	2026-11-12 09:05:00.001186+00
948	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 21:00:00+00	36	0	2	0	23.7	89	0.67	0	2026-11-12 09:05:00.001186+00
949	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 22:00:00+00	37	0	2	0	23.4	91	0.45	0	2026-11-12 09:05:00.001186+00
950	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-13 23:00:00+00	38	0.1	3	0.01	24	88	0.32	13	2026-11-12 09:05:00.001186+00
951	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 00:00:00+00	39	0	4	0.1	24.6	89	1.09	150	2026-11-12 09:05:00.001186+00
952	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 01:00:00+00	40	0	4	0.25	26.1	83	0.68	368	2026-11-12 09:05:00.001186+00
953	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 02:00:00+00	41	0	4	0.43	28.4	71	0.92	600	2026-11-12 09:05:00.001186+00
954	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 03:00:00+00	42	0	8	0.53	29.4	69	1.84	720	2026-11-12 09:05:00.001186+00
955	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 04:00:00+00	43	0.2	19	0.46	28.5	74	1.7	621	2026-11-12 09:05:00.001186+00
956	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 05:00:00+00	44	0.1	34	0.61	29.8	70	0.32	807	2026-11-12 09:05:00.001186+00
957	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 06:00:00+00	45	0.1	49	0.63	30.4	68	0.9	843	2026-11-12 09:05:00.001186+00
958	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 07:00:00+00	46	0.3	67	0.44	28.9	74	1.8	591	2026-11-12 09:05:00.001186+00
959	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 08:00:00+00	47	2.1	86	0.22	26.2	89	0.67	296	2026-11-12 09:05:00.001186+00
960	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 09:00:00+00	2026-11-14 09:00:00+00	48	1	96	0.19	26.1	91	1.66	282	2026-11-12 09:05:00.001186+00
961	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 11:00:00+00	1	0.7	97	0.02	24.8	97	2.05	24	2026-11-12 10:05:00.000535+00
962	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 12:00:00+00	2	0.1	92	0	24.6	95	0.25	0	2026-11-12 10:05:00.000535+00
963	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 13:00:00+00	3	0	86	0	24.7	96	0.59	0	2026-11-12 10:05:00.000535+00
964	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 14:00:00+00	4	0	77	0	25	94	0.21	0	2026-11-12 10:05:00.000535+00
965	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 15:00:00+00	5	0	65	0	25	93	0.07	0	2026-11-12 10:05:00.000535+00
966	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 16:00:00+00	6	0	47	0	24.7	95	0.35	0	2026-11-12 10:05:00.000535+00
967	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 17:00:00+00	7	0	27	0	24.4	96	0.5	0	2026-11-12 10:05:00.000535+00
968	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 18:00:00+00	8	0	12	0	24	96	0.65	0	2026-11-12 10:05:00.000535+00
969	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 19:00:00+00	9	0	8	0	23.4	97	0.14	0	2026-11-12 10:05:00.000535+00
970	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 20:00:00+00	10	0	11	0	23.4	95	0.35	0	2026-11-12 10:05:00.000535+00
971	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 21:00:00+00	11	0	12	0	23.4	93	0.86	0	2026-11-12 10:05:00.000535+00
972	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 22:00:00+00	12	0	10	0	23.6	91	0.2	0	2026-11-12 10:05:00.000535+00
973	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-12 23:00:00+00	13	0	7	0.01	24.3	89	0.52	14	2026-11-12 10:05:00.000535+00
974	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 00:00:00+00	14	0	4	0.08	25.4	85	0.41	124	2026-11-12 10:05:00.000535+00
975	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 01:00:00+00	15	0	1	0.24	26.8	79	0.87	347	2026-11-12 10:05:00.000535+00
976	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 02:00:00+00	16	0	0	0.37	27.8	76	1.86	521	2026-11-12 10:05:00.000535+00
977	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 03:00:00+00	17	0.1	0	0.4	28.3	75	0.3	544	2026-11-12 10:05:00.000535+00
978	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 04:00:00+00	18	0	9	0.48	29.5	70	1.2	637	2026-11-12 10:05:00.000535+00
979	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 05:00:00+00	19	0.6	23	0.55	29.7	69	2.67	740	2026-11-12 10:05:00.000535+00
980	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 06:00:00+00	20	0.3	39	0.48	29.6	70	0.16	637	2026-11-12 10:05:00.000535+00
981	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 07:00:00+00	21	0	61	0.34	29.2	72	1.41	438	2026-11-12 10:05:00.000535+00
982	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 08:00:00+00	22	1.7	85	0.24	26.6	86	1.98	334	2026-11-12 10:05:00.000535+00
983	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 09:00:00+00	23	2.6	100	0.12	25.8	93	1.71	169	2026-11-12 10:05:00.000535+00
984	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 10:00:00+00	24	0.3	99	0.08	25.5	93	1.15	105	2026-11-12 10:05:00.000535+00
985	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 11:00:00+00	25	0.1	89	0.02	25.1	96	0.64	17	2026-11-12 10:05:00.000535+00
986	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 12:00:00+00	26	0	75	0	25.1	96	0.63	0	2026-11-12 10:05:00.000535+00
987	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 13:00:00+00	27	0	56	0	25.2	94	0.11	0	2026-11-12 10:05:00.000535+00
988	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 14:00:00+00	28	0	33	0	25	93	0.21	0	2026-11-12 10:05:00.000535+00
989	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 15:00:00+00	29	0	16	0	24.9	92	0.25	0	2026-11-12 10:05:00.000535+00
990	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 16:00:00+00	30	0	9	0	24.7	91	0.36	0	2026-11-12 10:05:00.000535+00
991	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 17:00:00+00	31	0	7	0	24.2	91	0.67	0	2026-11-12 10:05:00.000535+00
992	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 18:00:00+00	32	0	6	0	24.1	90	0.69	0	2026-11-12 10:05:00.000535+00
993	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 19:00:00+00	33	0	4	0	23.8	90	0.65	0	2026-11-12 10:05:00.000535+00
994	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 20:00:00+00	34	0	3	0	23.7	90	0.61	0	2026-11-12 10:05:00.000535+00
995	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 21:00:00+00	35	0	2	0	23.7	89	0.67	0	2026-11-12 10:05:00.000535+00
996	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 22:00:00+00	36	0	2	0	23.4	91	0.45	0	2026-11-12 10:05:00.000535+00
997	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-13 23:00:00+00	37	0.1	3	0.01	24	88	0.32	13	2026-11-12 10:05:00.000535+00
998	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 00:00:00+00	38	0	4	0.1	24.6	89	1.09	150	2026-11-12 10:05:00.000535+00
999	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 01:00:00+00	39	0	4	0.25	26.1	83	0.68	368	2026-11-12 10:05:00.000535+00
1000	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 02:00:00+00	40	0	4	0.43	28.4	71	0.92	600	2026-11-12 10:05:00.000535+00
1001	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 03:00:00+00	41	0	8	0.53	29.4	69	1.84	720	2026-11-12 10:05:00.000535+00
1002	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 04:00:00+00	42	0.2	19	0.46	28.5	74	1.7	621	2026-11-12 10:05:00.000535+00
1003	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 05:00:00+00	43	0.1	34	0.61	29.8	70	0.32	807	2026-11-12 10:05:00.000535+00
1004	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 06:00:00+00	44	0.1	49	0.63	30.4	68	0.9	843	2026-11-12 10:05:00.000535+00
1005	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 07:00:00+00	45	0.3	67	0.44	28.9	74	1.8	591	2026-11-12 10:05:00.000535+00
1006	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 08:00:00+00	46	2.1	86	0.22	26.2	89	0.67	296	2026-11-12 10:05:00.000535+00
1007	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 09:00:00+00	47	1	96	0.19	26.1	91	1.66	282	2026-11-12 10:05:00.000535+00
1008	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 10:00:00+00	2026-11-14 10:00:00+00	48	0.6	89	0.09	24.8	92	1.82	135	2026-11-12 10:05:00.000535+00
1009	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 12:00:00+00	1	0.1	94	0	24.6	95	0.25	0	2026-11-12 11:05:00.000148+00
1010	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 13:00:00+00	2	0	83	0	24.7	96	0.59	0	2026-11-12 11:05:00.000148+00
1011	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 14:00:00+00	3	0	68	0	25	94	0.21	0	2026-11-12 11:05:00.000148+00
1012	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 15:00:00+00	4	0	53	0	25	93	0.07	0	2026-11-12 11:05:00.000148+00
1013	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 16:00:00+00	5	0	38	0	24.7	95	0.35	0	2026-11-12 11:05:00.000148+00
1014	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 17:00:00+00	6	0	22	0	24.4	96	0.5	0	2026-11-12 11:05:00.000148+00
1015	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 18:00:00+00	7	0	10	0	24	96	0.65	0	2026-11-12 11:05:00.000148+00
1016	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 19:00:00+00	8	0	4	0	23.4	97	0.14	0	2026-11-12 11:05:00.000148+00
1017	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 20:00:00+00	9	0	1	0	23.4	95	0.35	0	2026-11-12 11:05:00.000148+00
1018	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 21:00:00+00	10	0	0	0	23.4	93	0.86	0	2026-11-12 11:05:00.000148+00
1019	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 22:00:00+00	11	0	0	0	23.6	91	0.2	0	2026-11-12 11:05:00.000148+00
1020	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-12 23:00:00+00	12	0	0	0.01	24.3	89	0.52	14	2026-11-12 11:05:00.000148+00
1021	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 00:00:00+00	13	0	2	0.08	25.4	85	0.41	124	2026-11-12 11:05:00.000148+00
1022	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 01:00:00+00	14	0	4	0.24	26.8	79	0.87	347	2026-11-12 11:05:00.000148+00
1023	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 02:00:00+00	15	0	8	0.37	27.8	76	1.86	521	2026-11-12 11:05:00.000148+00
1024	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 03:00:00+00	16	0.1	12	0.4	28.3	75	0.3	544	2026-11-12 11:05:00.000148+00
1025	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 04:00:00+00	17	0	17	0.48	29.5	70	1.2	637	2026-11-12 11:05:00.000148+00
1026	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 05:00:00+00	18	0.6	22	0.55	29.7	69	2.67	740	2026-11-12 11:05:00.000148+00
1027	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 06:00:00+00	19	0.3	33	0.48	29.6	70	0.16	637	2026-11-12 11:05:00.000148+00
1028	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 07:00:00+00	20	0	55	0.34	29.2	72	1.41	438	2026-11-12 11:05:00.000148+00
1029	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 08:00:00+00	21	1.7	81	0.24	26.6	86	1.98	334	2026-11-12 11:05:00.000148+00
1030	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 09:00:00+00	22	2.6	96	0.12	25.8	93	1.71	169	2026-11-12 11:05:00.000148+00
1031	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 10:00:00+00	23	0.3	90	0.08	25.5	93	1.15	105	2026-11-12 11:05:00.000148+00
1032	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 11:00:00+00	24	0.1	72	0.02	25.1	96	0.64	17	2026-11-12 11:05:00.000148+00
1033	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 12:00:00+00	25	0	55	0	25.1	96	0.63	0	2026-11-12 11:05:00.000148+00
1034	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 13:00:00+00	26	0	42	0	25.2	94	0.11	0	2026-11-12 11:05:00.000148+00
1035	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 14:00:00+00	27	0	29	0	25	93	0.21	0	2026-11-12 11:05:00.000148+00
1036	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 15:00:00+00	28	0	20	0	24.9	92	0.25	0	2026-11-12 11:05:00.000148+00
1037	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 16:00:00+00	29	0	16	0	24.7	91	0.36	0	2026-11-12 11:05:00.000148+00
1038	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 17:00:00+00	30	0	15	0	24.2	91	0.67	0	2026-11-12 11:05:00.000148+00
1039	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 18:00:00+00	31	0	14	0	24.1	90	0.69	0	2026-11-12 11:05:00.000148+00
1040	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 19:00:00+00	32	0	10	0	23.8	90	0.65	0	2026-11-12 11:05:00.000148+00
1041	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 20:00:00+00	33	0	5	0	23.7	90	0.61	0	2026-11-12 11:05:00.000148+00
1042	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 21:00:00+00	34	0	2	0	23.7	89	0.67	0	2026-11-12 11:05:00.000148+00
1043	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 22:00:00+00	35	0	3	0	23.4	91	0.45	0	2026-11-12 11:05:00.000148+00
1044	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-13 23:00:00+00	36	0.1	6	0.01	24	88	0.32	13	2026-11-12 11:05:00.000148+00
1045	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 00:00:00+00	37	0	8	0.1	24.6	89	1.09	150	2026-11-12 11:05:00.000148+00
1046	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 01:00:00+00	38	0	7	0.25	26.1	83	0.68	368	2026-11-12 11:05:00.000148+00
1047	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 02:00:00+00	39	0	6	0.43	28.4	71	0.92	600	2026-11-12 11:05:00.000148+00
1048	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 03:00:00+00	40	0	10	0.53	29.4	69	1.84	720	2026-11-12 11:05:00.000148+00
1049	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 04:00:00+00	41	0.2	21	0.46	28.5	74	1.7	621	2026-11-12 11:05:00.000148+00
1050	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 05:00:00+00	42	0.1	37	0.61	29.8	70	0.32	807	2026-11-12 11:05:00.000148+00
1051	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 06:00:00+00	43	0.1	53	0.63	30.4	68	0.9	843	2026-11-12 11:05:00.000148+00
1052	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 07:00:00+00	44	0.3	71	0.44	28.9	74	1.8	591	2026-11-12 11:05:00.000148+00
1053	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 08:00:00+00	45	2.1	90	0.22	26.2	89	0.67	296	2026-11-12 11:05:00.000148+00
1054	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 09:00:00+00	46	1	100	0.19	26.1	91	1.66	282	2026-11-12 11:05:00.000148+00
1055	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 10:00:00+00	47	0.6	94	0.09	24.8	92	1.82	135	2026-11-12 11:05:00.000148+00
1056	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 11:00:00+00	2026-11-14 11:00:00+00	48	1.9	79	0.02	24	98	1.42	19	2026-11-12 11:05:00.000148+00
1057	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 13:00:00+00	1	0	83	0	24.7	96	0.59	0	2026-11-12 12:04:59.999844+00
1058	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 14:00:00+00	2	0	68	0	25	94	0.21	0	2026-11-12 12:04:59.999844+00
1059	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 15:00:00+00	3	0	53	0	25	93	0.07	0	2026-11-12 12:04:59.999844+00
1060	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 16:00:00+00	4	0	38	0	24.7	95	0.35	0	2026-11-12 12:04:59.999844+00
1061	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 17:00:00+00	5	0	22	0	24.4	96	0.5	0	2026-11-12 12:04:59.999844+00
1062	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 18:00:00+00	6	0	10	0	24	96	0.65	0	2026-11-12 12:04:59.999844+00
1063	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 19:00:00+00	7	0	4	0	23.4	97	0.14	0	2026-11-12 12:04:59.999844+00
1064	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 20:00:00+00	8	0	1	0	23.4	95	0.35	0	2026-11-12 12:04:59.999844+00
1065	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 21:00:00+00	9	0	0	0	23.4	93	0.86	0	2026-11-12 12:04:59.999844+00
1066	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 22:00:00+00	10	0	0	0	23.6	91	0.2	0	2026-11-12 12:04:59.999844+00
1067	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-12 23:00:00+00	11	0	0	0.01	24.3	89	0.52	14	2026-11-12 12:04:59.999844+00
1068	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 00:00:00+00	12	0	2	0.08	25.4	85	0.41	124	2026-11-12 12:04:59.999844+00
1069	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 01:00:00+00	13	0	4	0.24	26.8	79	0.87	347	2026-11-12 12:04:59.999844+00
1070	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 02:00:00+00	14	0	8	0.37	27.8	76	1.86	521	2026-11-12 12:04:59.999844+00
1071	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 03:00:00+00	15	0.1	12	0.4	28.3	75	0.3	544	2026-11-12 12:04:59.999844+00
1072	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 04:00:00+00	16	0	17	0.48	29.5	70	1.2	637	2026-11-12 12:04:59.999844+00
1073	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 05:00:00+00	17	0.6	22	0.55	29.7	69	2.67	740	2026-11-12 12:04:59.999844+00
1074	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 06:00:00+00	18	0.3	33	0.48	29.6	70	0.16	637	2026-11-12 12:04:59.999844+00
1075	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 07:00:00+00	19	0	55	0.34	29.2	72	1.41	438	2026-11-12 12:04:59.999844+00
1076	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 08:00:00+00	20	1.7	81	0.24	26.6	86	1.98	334	2026-11-12 12:04:59.999844+00
1077	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 09:00:00+00	21	2.6	96	0.12	25.8	93	1.71	169	2026-11-12 12:04:59.999844+00
1078	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 10:00:00+00	22	0.3	90	0.08	25.5	93	1.15	105	2026-11-12 12:04:59.999844+00
1079	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 11:00:00+00	23	0.1	72	0.02	25.1	96	0.64	17	2026-11-12 12:04:59.999844+00
1080	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 12:00:00+00	24	0	55	0	25.1	96	0.63	0	2026-11-12 12:04:59.999844+00
1081	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 13:00:00+00	25	0	42	0	25.2	94	0.11	0	2026-11-12 12:04:59.999844+00
1082	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 14:00:00+00	26	0	29	0	25	93	0.21	0	2026-11-12 12:04:59.999844+00
1083	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 15:00:00+00	27	0	20	0	24.9	92	0.25	0	2026-11-12 12:04:59.999844+00
1084	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 16:00:00+00	28	0	16	0	24.7	91	0.36	0	2026-11-12 12:04:59.999844+00
1085	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 17:00:00+00	29	0	15	0	24.2	91	0.67	0	2026-11-12 12:04:59.999844+00
1086	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 18:00:00+00	30	0	14	0	24.1	90	0.69	0	2026-11-12 12:04:59.999844+00
1087	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 19:00:00+00	31	0	10	0	23.8	90	0.65	0	2026-11-12 12:04:59.999844+00
1088	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 20:00:00+00	32	0	5	0	23.7	90	0.61	0	2026-11-12 12:04:59.999844+00
1089	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 21:00:00+00	33	0	2	0	23.7	89	0.67	0	2026-11-12 12:04:59.999844+00
1090	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 22:00:00+00	34	0	3	0	23.4	91	0.45	0	2026-11-12 12:04:59.999844+00
1091	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-13 23:00:00+00	35	0.1	6	0.01	24	88	0.32	13	2026-11-12 12:04:59.999844+00
1092	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 00:00:00+00	36	0	8	0.1	24.6	89	1.09	150	2026-11-12 12:04:59.999844+00
1093	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 01:00:00+00	37	0	7	0.25	26.1	83	0.68	368	2026-11-12 12:04:59.999844+00
1094	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 02:00:00+00	38	0	6	0.43	28.4	71	0.92	600	2026-11-12 12:04:59.999844+00
1095	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 03:00:00+00	39	0	10	0.53	29.4	69	1.84	720	2026-11-12 12:04:59.999844+00
1096	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 04:00:00+00	40	0.2	21	0.46	28.5	74	1.7	621	2026-11-12 12:04:59.999844+00
1097	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 05:00:00+00	41	0.1	37	0.61	29.8	70	0.32	807	2026-11-12 12:04:59.999844+00
1098	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 06:00:00+00	42	0.1	53	0.63	30.4	68	0.9	843	2026-11-12 12:04:59.999844+00
1099	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 07:00:00+00	43	0.3	71	0.44	28.9	74	1.8	591	2026-11-12 12:04:59.999844+00
1100	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 08:00:00+00	44	2.1	90	0.22	26.2	89	0.67	296	2026-11-12 12:04:59.999844+00
1101	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 09:00:00+00	45	1	100	0.19	26.1	91	1.66	282	2026-11-12 12:04:59.999844+00
1102	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 10:00:00+00	46	0.6	94	0.09	24.8	92	1.82	135	2026-11-12 12:04:59.999844+00
1103	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 11:00:00+00	47	1.9	79	0.02	24	98	1.42	19	2026-11-12 12:04:59.999844+00
1104	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 12:00:00+00	2026-11-14 12:00:00+00	48	0.2	63	0	23.9	98	0.68	0	2026-11-12 12:04:59.999844+00
1105	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 14:00:00+00	1	0.1	68	0	25.4	93	0.59	0	2026-11-12 13:05:00.001243+00
1106	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 15:00:00+00	2	0	53	0	25.4	91	0.56	0	2026-11-12 13:05:00.001243+00
1107	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 16:00:00+00	3	0	38	0	25.2	91	0.36	0	2026-11-12 13:05:00.001243+00
1108	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 17:00:00+00	4	0	22	0	24.8	91	0.32	0	2026-11-12 13:05:00.001243+00
1109	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 18:00:00+00	5	0	10	0	24.4	92	0.76	0	2026-11-12 13:05:00.001243+00
1110	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 19:00:00+00	6	0	4	0	24	92	0.72	0	2026-11-12 13:05:00.001243+00
1111	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 20:00:00+00	7	0	1	0	23.9	91	0.28	0	2026-11-12 13:05:00.001243+00
1112	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 21:00:00+00	8	0	0	0	23.9	90	0.39	0	2026-11-12 13:05:00.001243+00
1113	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 22:00:00+00	9	0	0	0	23.7	90	0.63	0	2026-11-12 13:05:00.001243+00
1114	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-12 23:00:00+00	10	0	0	0	24.3	88	0.18	14	2026-11-12 13:05:00.001243+00
1115	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 00:00:00+00	11	0	2	0.1	25.7	82	0.92	142	2026-11-12 13:05:00.001243+00
1116	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 01:00:00+00	12	0	4	0.22	27	77	1.28	311	2026-11-12 13:05:00.001243+00
1117	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 02:00:00+00	13	0	8	0.37	28.4	71	1.41	504	2026-11-12 13:05:00.001243+00
1118	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 03:00:00+00	14	0	12	0.45	29.5	67	1.6	594	2026-11-12 13:05:00.001243+00
1119	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 04:00:00+00	15	0	17	0.55	30.4	65	2.01	731	2026-11-12 13:05:00.001243+00
1120	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 05:00:00+00	16	0.1	22	0.53	30.4	65	3.02	691	2026-11-12 13:05:00.001243+00
1121	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 06:00:00+00	17	0.1	33	0.49	31.3	61	1.63	619	2026-11-12 13:05:00.001243+00
1122	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 07:00:00+00	18	0.1	55	0.4	31.1	63	0.91	507	2026-11-12 13:05:00.001243+00
1123	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 08:00:00+00	19	0.2	81	0.28	30.2	66	0.49	352	2026-11-12 13:05:00.001243+00
1124	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 09:00:00+00	20	1.2	96	0.19	28	80	1.19	251	2026-11-12 13:05:00.001243+00
1125	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 10:00:00+00	21	0.4	90	0.09	27.3	84	1.24	106	2026-11-12 13:05:00.001243+00
1126	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 11:00:00+00	22	0	72	0.02	26.6	88	0.74	26	2026-11-12 13:05:00.001243+00
1127	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 12:00:00+00	23	0.2	55	0	25.8	95	1.4	0	2026-11-12 13:05:00.001243+00
1128	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 13:00:00+00	24	0.1	42	0	25.4	94	0.72	0	2026-11-12 13:05:00.001243+00
1129	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 14:00:00+00	25	0.4	29	0	24.5	96	1.82	0	2026-11-12 13:05:00.001243+00
1130	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 15:00:00+00	26	0.3	20	0	24.5	96	1.2	0	2026-11-12 13:05:00.001243+00
1131	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 16:00:00+00	27	0.2	16	0	24.5	96	1.3	0	2026-11-12 13:05:00.001243+00
1132	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 17:00:00+00	28	0	15	0	24.5	96	0.79	0	2026-11-12 13:05:00.001243+00
1133	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 18:00:00+00	29	0	14	0	24.5	93	0.32	0	2026-11-12 13:05:00.001243+00
1134	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 19:00:00+00	30	0	10	0	24.1	94	0.63	0	2026-11-12 13:05:00.001243+00
1135	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 20:00:00+00	31	0	5	0	23.9	94	0.54	0	2026-11-12 13:05:00.001243+00
1136	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 21:00:00+00	32	0	2	0	24.1	92	0.07	0	2026-11-12 13:05:00.001243+00
1137	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 22:00:00+00	33	0.5	3	0	23.7	93	0.39	0	2026-11-12 13:05:00.001243+00
1138	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-13 23:00:00+00	34	0.1	6	0.01	24	93	1.03	13	2026-11-12 13:05:00.001243+00
1139	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 00:00:00+00	35	0	8	0.1	24.8	90	0.96	163	2026-11-12 13:05:00.001243+00
1140	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 01:00:00+00	36	0	7	0.26	26.5	80	0.96	375	2026-11-12 13:05:00.001243+00
1141	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 02:00:00+00	37	0	6	0.44	28.6	71	1.25	610	2026-11-12 13:05:00.001243+00
1142	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 03:00:00+00	38	0	10	0.56	29.8	68	1.86	755	2026-11-12 13:05:00.001243+00
1143	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 04:00:00+00	39	0	21	0.51	29.6	70	1.59	677	2026-11-12 13:05:00.001243+00
1144	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 05:00:00+00	40	0	37	0.64	30.7	67	1.41	853	2026-11-12 13:05:00.001243+00
1145	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 06:00:00+00	41	0.2	53	0.63	31.1	66	1.61	831	2026-11-12 13:05:00.001243+00
1146	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 07:00:00+00	42	0.4	71	0.54	30.5	68	2.65	722	2026-11-12 13:05:00.001243+00
1147	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 08:00:00+00	43	4.9	90	0.25	25.9	91	1.21	360	2026-11-12 13:05:00.001243+00
1148	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 09:00:00+00	44	1.6	100	0.17	26	91	0.67	243	2026-11-12 13:05:00.001243+00
1149	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 10:00:00+00	45	0.9	94	0.1	25.4	94	1.44	159	2026-11-12 13:05:00.001243+00
1150	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 11:00:00+00	46	0.1	79	0.02	24.8	96	1.32	26	2026-11-12 13:05:00.001243+00
1151	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 12:00:00+00	47	0	63	0	24.8	96	0.79	0	2026-11-12 13:05:00.001243+00
1152	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 13:00:00+00	2026-11-14 13:00:00+00	48	0	48	0	24.9	95	0.78	0	2026-11-12 13:05:00.001243+00
1153	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 15:00:00+00	1	0	53	0	25.4	91	0.56	0	2026-11-12 14:04:59.999423+00
1154	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 16:00:00+00	2	0	38	0	25.2	91	0.36	0	2026-11-12 14:04:59.999423+00
1155	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 17:00:00+00	3	0	22	0	24.8	91	0.32	0	2026-11-12 14:04:59.999423+00
1156	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 18:00:00+00	4	0	10	0	24.4	92	0.76	0	2026-11-12 14:04:59.999423+00
1157	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 19:00:00+00	5	0	4	0	24	92	0.72	0	2026-11-12 14:04:59.999423+00
1158	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 20:00:00+00	6	0	1	0	23.9	91	0.28	0	2026-11-12 14:04:59.999423+00
1159	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 21:00:00+00	7	0	0	0	23.9	90	0.39	0	2026-11-12 14:04:59.999423+00
1160	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 22:00:00+00	8	0	0	0	23.7	90	0.63	0	2026-11-12 14:04:59.999423+00
1161	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-12 23:00:00+00	9	0	0	0	24.3	88	0.18	14	2026-11-12 14:04:59.999423+00
1162	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 00:00:00+00	10	0	2	0.1	25.7	82	0.92	142	2026-11-12 14:04:59.999423+00
1163	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 01:00:00+00	11	0	4	0.22	27	77	1.28	311	2026-11-12 14:04:59.999423+00
1164	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 02:00:00+00	12	0	8	0.37	28.4	71	1.41	504	2026-11-12 14:04:59.999423+00
1165	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 03:00:00+00	13	0	12	0.45	29.5	67	1.6	594	2026-11-12 14:04:59.999423+00
1166	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 04:00:00+00	14	0	17	0.55	30.4	65	2.01	731	2026-11-12 14:04:59.999423+00
1167	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 05:00:00+00	15	0.1	22	0.53	30.4	65	3.02	691	2026-11-12 14:04:59.999423+00
1168	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 06:00:00+00	16	0.1	33	0.49	31.3	61	1.63	619	2026-11-12 14:04:59.999423+00
1169	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 07:00:00+00	17	0.1	55	0.4	31.1	63	0.91	507	2026-11-12 14:04:59.999423+00
1170	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 08:00:00+00	18	0.2	81	0.28	30.2	66	0.49	352	2026-11-12 14:04:59.999423+00
1171	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 09:00:00+00	19	1.2	96	0.19	28	80	1.19	251	2026-11-12 14:04:59.999423+00
1172	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 10:00:00+00	20	0.4	90	0.09	27.3	84	1.24	106	2026-11-12 14:04:59.999423+00
1173	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 11:00:00+00	21	0	72	0.02	26.6	88	0.74	26	2026-11-12 14:04:59.999423+00
1174	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 12:00:00+00	22	0.2	55	0	25.8	95	1.4	0	2026-11-12 14:04:59.999423+00
1175	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 13:00:00+00	23	0.1	42	0	25.4	94	0.72	0	2026-11-12 14:04:59.999423+00
1176	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 14:00:00+00	24	0.4	29	0	24.5	96	1.82	0	2026-11-12 14:04:59.999423+00
1177	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 15:00:00+00	25	0.3	20	0	24.5	96	1.2	0	2026-11-12 14:04:59.999423+00
1178	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 16:00:00+00	26	0.2	16	0	24.5	96	1.3	0	2026-11-12 14:04:59.999423+00
1179	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 17:00:00+00	27	0	15	0	24.5	96	0.79	0	2026-11-12 14:04:59.999423+00
1180	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 18:00:00+00	28	0	14	0	24.5	93	0.32	0	2026-11-12 14:04:59.999423+00
1181	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 19:00:00+00	29	0	10	0	24.1	94	0.63	0	2026-11-12 14:04:59.999423+00
1182	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 20:00:00+00	30	0	5	0	23.9	94	0.54	0	2026-11-12 14:04:59.999423+00
1183	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 21:00:00+00	31	0	2	0	24.1	92	0.07	0	2026-11-12 14:04:59.999423+00
1184	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 22:00:00+00	32	0.5	3	0	23.7	93	0.39	0	2026-11-12 14:04:59.999423+00
1185	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-13 23:00:00+00	33	0.1	6	0.01	24	93	1.03	13	2026-11-12 14:04:59.999423+00
1186	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 00:00:00+00	34	0	8	0.1	24.8	90	0.96	163	2026-11-12 14:04:59.999423+00
1187	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 01:00:00+00	35	0	7	0.26	26.5	80	0.96	375	2026-11-12 14:04:59.999423+00
1188	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 02:00:00+00	36	0	6	0.44	28.6	71	1.25	610	2026-11-12 14:04:59.999423+00
1189	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 03:00:00+00	37	0	10	0.56	29.8	68	1.86	755	2026-11-12 14:04:59.999423+00
1190	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 04:00:00+00	38	0	21	0.51	29.6	70	1.59	677	2026-11-12 14:04:59.999423+00
1191	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 05:00:00+00	39	0	37	0.64	30.7	67	1.41	853	2026-11-12 14:04:59.999423+00
1192	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 06:00:00+00	40	0.2	53	0.63	31.1	66	1.61	831	2026-11-12 14:04:59.999423+00
1193	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 07:00:00+00	41	0.4	71	0.54	30.5	68	2.65	722	2026-11-12 14:04:59.999423+00
1194	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 08:00:00+00	42	4.9	90	0.25	25.9	91	1.21	360	2026-11-12 14:04:59.999423+00
1195	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 09:00:00+00	43	1.6	100	0.17	26	91	0.67	243	2026-11-12 14:04:59.999423+00
1196	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 10:00:00+00	44	0.9	94	0.1	25.4	94	1.44	159	2026-11-12 14:04:59.999423+00
1197	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 11:00:00+00	45	0.1	79	0.02	24.8	96	1.32	26	2026-11-12 14:04:59.999423+00
1198	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 12:00:00+00	46	0	63	0	24.8	96	0.79	0	2026-11-12 14:04:59.999423+00
1199	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 13:00:00+00	47	0	48	0	24.9	95	0.78	0	2026-11-12 14:04:59.999423+00
1200	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 14:00:00+00	2026-11-14 14:00:00+00	48	0	33	0	24.8	94	0.49	0	2026-11-12 14:04:59.999423+00
1201	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-12 16:00:00+00	1	0	52	0	25.2	91	0.36	0	2026-11-12 15:05:00.000353+00
1202	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-12 17:00:00+00	2	0	29	0	24.8	91	0.32	0	2026-11-12 15:05:00.000353+00
1203	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-12 18:00:00+00	3	0	12	0	24.4	92	0.76	0	2026-11-12 15:05:00.000353+00
1204	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-12 19:00:00+00	4	0	6	0	24	92	0.72	0	2026-11-12 15:05:00.000353+00
1205	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-12 20:00:00+00	5	0	5	0	23.9	91	0.28	0	2026-11-12 15:05:00.000353+00
1206	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-12 21:00:00+00	6	0	6	0	23.9	90	0.39	0	2026-11-12 15:05:00.000353+00
1207	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-12 22:00:00+00	7	0	8	0	23.7	90	0.63	0	2026-11-12 15:05:00.000353+00
1208	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-12 23:00:00+00	8	0	12	0	24.3	88	0.18	14	2026-11-12 15:05:00.000353+00
1209	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 00:00:00+00	9	0	14	0.1	25.7	82	0.92	142	2026-11-12 15:05:00.000353+00
1210	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 01:00:00+00	10	0	10	0.22	27	77	1.28	311	2026-11-12 15:05:00.000353+00
1211	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 02:00:00+00	11	0	5	0.37	28.4	71	1.41	504	2026-11-12 15:05:00.000353+00
1212	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 03:00:00+00	12	0	4	0.45	29.5	67	1.6	594	2026-11-12 15:05:00.000353+00
1213	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 04:00:00+00	13	0	11	0.55	30.4	65	2.01	731	2026-11-12 15:05:00.000353+00
1214	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 05:00:00+00	14	0.1	23	0.53	30.4	65	3.02	691	2026-11-12 15:05:00.000353+00
1215	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 06:00:00+00	15	0.1	37	0.49	31.3	61	1.63	619	2026-11-12 15:05:00.000353+00
1216	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 07:00:00+00	16	0.1	56	0.4	31.1	63	0.91	507	2026-11-12 15:05:00.000353+00
1217	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 08:00:00+00	17	0.2	78	0.28	30.2	66	0.49	352	2026-11-12 15:05:00.000353+00
1218	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 09:00:00+00	18	1.2	92	0.19	28	80	1.19	251	2026-11-12 15:05:00.000353+00
1219	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 10:00:00+00	19	0.4	93	0.09	27.3	84	1.24	106	2026-11-12 15:05:00.000353+00
1220	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 11:00:00+00	20	0	86	0.02	26.6	88	0.74	26	2026-11-12 15:05:00.000353+00
1221	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 12:00:00+00	21	0.2	78	0	25.8	95	1.4	0	2026-11-12 15:05:00.000353+00
1222	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 13:00:00+00	22	0.1	69	0	25.4	94	0.72	0	2026-11-12 15:05:00.000353+00
1223	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 14:00:00+00	23	0.4	58	0	24.5	96	1.82	0	2026-11-12 15:05:00.000353+00
1224	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 15:00:00+00	24	0.3	47	0	24.5	96	1.2	0	2026-11-12 15:05:00.000353+00
1225	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 16:00:00+00	25	0.2	37	0	24.5	96	1.3	0	2026-11-12 15:05:00.000353+00
1226	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 17:00:00+00	26	0	28	0	24.5	96	0.79	0	2026-11-12 15:05:00.000353+00
1227	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 18:00:00+00	27	0	22	0	24.5	93	0.32	0	2026-11-12 15:05:00.000353+00
1228	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 19:00:00+00	28	0	23	0	24.1	94	0.63	0	2026-11-12 15:05:00.000353+00
1229	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 20:00:00+00	29	0	28	0	23.9	94	0.54	0	2026-11-12 15:05:00.000353+00
1230	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 21:00:00+00	30	0	31	0	24.1	92	0.07	0	2026-11-12 15:05:00.000353+00
1231	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 22:00:00+00	31	0.5	29	0	23.7	93	0.39	0	2026-11-12 15:05:00.000353+00
1232	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-13 23:00:00+00	32	0.1	25	0.01	24	93	1.03	13	2026-11-12 15:05:00.000353+00
1233	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 00:00:00+00	33	0	22	0.1	24.8	90	0.96	163	2026-11-12 15:05:00.000353+00
1234	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 01:00:00+00	34	0	18	0.26	26.5	80	0.96	375	2026-11-12 15:05:00.000353+00
1235	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 02:00:00+00	35	0	15	0.44	28.6	71	1.25	610	2026-11-12 15:05:00.000353+00
1236	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 03:00:00+00	36	0	16	0.56	29.8	68	1.86	755	2026-11-12 15:05:00.000353+00
1237	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 04:00:00+00	37	0	25	0.51	29.6	70	1.59	677	2026-11-12 15:05:00.000353+00
1238	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 05:00:00+00	38	0	39	0.64	30.7	67	1.41	853	2026-11-12 15:05:00.000353+00
1239	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 06:00:00+00	39	0.2	53	0.63	31.1	66	1.61	831	2026-11-12 15:05:00.000353+00
1240	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 07:00:00+00	40	0.4	70	0.54	30.5	68	2.65	722	2026-11-12 15:05:00.000353+00
1241	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 08:00:00+00	41	4.9	87	0.25	25.9	91	1.21	360	2026-11-12 15:05:00.000353+00
1242	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 09:00:00+00	42	1.6	96	0.17	26	91	0.67	243	2026-11-12 15:05:00.000353+00
1243	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 10:00:00+00	43	0.9	91	0.1	25.4	94	1.44	159	2026-11-12 15:05:00.000353+00
1244	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 11:00:00+00	44	0.1	78	0.02	24.8	96	1.32	26	2026-11-12 15:05:00.000353+00
1245	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 12:00:00+00	45	0	63	0	24.8	96	0.79	0	2026-11-12 15:05:00.000353+00
1246	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 13:00:00+00	46	0	48	0	24.9	95	0.78	0	2026-11-12 15:05:00.000353+00
1247	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 14:00:00+00	47	0	32	0	24.8	94	0.49	0	2026-11-12 15:05:00.000353+00
1248	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 15:00:00+00	2026-11-14 15:00:00+00	48	0.1	20	0	24.4	95	1.3	0	2026-11-12 15:05:00.000353+00
1249	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-12 17:00:00+00	1	0	29	0	24.8	91	0.32	0	2026-11-12 16:05:00.000406+00
1250	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-12 18:00:00+00	2	0	12	0	24.4	92	0.76	0	2026-11-12 16:05:00.000406+00
1251	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-12 19:00:00+00	3	0	6	0	24	92	0.72	0	2026-11-12 16:05:00.000406+00
1252	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-12 20:00:00+00	4	0	5	0	23.9	91	0.28	0	2026-11-12 16:05:00.000406+00
1253	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-12 21:00:00+00	5	0	6	0	23.9	90	0.39	0	2026-11-12 16:05:00.000406+00
1254	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-12 22:00:00+00	6	0	8	0	23.7	90	0.63	0	2026-11-12 16:05:00.000406+00
1255	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-12 23:00:00+00	7	0	12	0	24.3	88	0.18	14	2026-11-12 16:05:00.000406+00
1256	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 00:00:00+00	8	0	14	0.1	25.7	82	0.92	142	2026-11-12 16:05:00.000406+00
1257	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 01:00:00+00	9	0	10	0.22	27	77	1.28	311	2026-11-12 16:05:00.000406+00
1258	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 02:00:00+00	10	0	5	0.37	28.4	71	1.41	504	2026-11-12 16:05:00.000406+00
1259	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 03:00:00+00	11	0	4	0.45	29.5	67	1.6	594	2026-11-12 16:05:00.000406+00
1260	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 04:00:00+00	12	0	11	0.55	30.4	65	2.01	731	2026-11-12 16:05:00.000406+00
1261	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 05:00:00+00	13	0.1	23	0.53	30.4	65	3.02	691	2026-11-12 16:05:00.000406+00
1262	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 06:00:00+00	14	0.1	37	0.49	31.3	61	1.63	619	2026-11-12 16:05:00.000406+00
1263	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 07:00:00+00	15	0.1	56	0.4	31.1	63	0.91	507	2026-11-12 16:05:00.000406+00
1264	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 08:00:00+00	16	0.2	78	0.28	30.2	66	0.49	352	2026-11-12 16:05:00.000406+00
1265	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 09:00:00+00	17	1.2	92	0.19	28	80	1.19	251	2026-11-12 16:05:00.000406+00
1266	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 10:00:00+00	18	0.4	93	0.09	27.3	84	1.24	106	2026-11-12 16:05:00.000406+00
1267	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 11:00:00+00	19	0	86	0.02	26.6	88	0.74	26	2026-11-12 16:05:00.000406+00
1268	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 12:00:00+00	20	0.2	78	0	25.8	95	1.4	0	2026-11-12 16:05:00.000406+00
1269	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 13:00:00+00	21	0.1	69	0	25.4	94	0.72	0	2026-11-12 16:05:00.000406+00
1270	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 14:00:00+00	22	0.4	58	0	24.5	96	1.82	0	2026-11-12 16:05:00.000406+00
1271	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 15:00:00+00	23	0.3	47	0	24.5	96	1.2	0	2026-11-12 16:05:00.000406+00
1272	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 16:00:00+00	24	0.2	37	0	24.5	96	1.3	0	2026-11-12 16:05:00.000406+00
1273	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 17:00:00+00	25	0	28	0	24.5	96	0.79	0	2026-11-12 16:05:00.000406+00
1274	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 18:00:00+00	26	0	22	0	24.5	93	0.32	0	2026-11-12 16:05:00.000406+00
1275	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 19:00:00+00	27	0	23	0	24.1	94	0.63	0	2026-11-12 16:05:00.000406+00
1276	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 20:00:00+00	28	0	28	0	23.9	94	0.54	0	2026-11-12 16:05:00.000406+00
1277	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 21:00:00+00	29	0	31	0	24.1	92	0.07	0	2026-11-12 16:05:00.000406+00
1278	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 22:00:00+00	30	0.5	29	0	23.7	93	0.39	0	2026-11-12 16:05:00.000406+00
1279	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-13 23:00:00+00	31	0.1	25	0.01	24	93	1.03	13	2026-11-12 16:05:00.000406+00
1280	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 00:00:00+00	32	0	22	0.1	24.8	90	0.96	163	2026-11-12 16:05:00.000406+00
1281	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 01:00:00+00	33	0	18	0.26	26.5	80	0.96	375	2026-11-12 16:05:00.000406+00
1282	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 02:00:00+00	34	0	15	0.44	28.6	71	1.25	610	2026-11-12 16:05:00.000406+00
1283	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 03:00:00+00	35	0	16	0.56	29.8	68	1.86	755	2026-11-12 16:05:00.000406+00
1284	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 04:00:00+00	36	0	25	0.51	29.6	70	1.59	677	2026-11-12 16:05:00.000406+00
1285	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 05:00:00+00	37	0	39	0.64	30.7	67	1.41	853	2026-11-12 16:05:00.000406+00
1286	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 06:00:00+00	38	0.2	53	0.63	31.1	66	1.61	831	2026-11-12 16:05:00.000406+00
1287	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 07:00:00+00	39	0.4	70	0.54	30.5	68	2.65	722	2026-11-12 16:05:00.000406+00
1288	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 08:00:00+00	40	4.9	87	0.25	25.9	91	1.21	360	2026-11-12 16:05:00.000406+00
1289	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 09:00:00+00	41	1.6	96	0.17	26	91	0.67	243	2026-11-12 16:05:00.000406+00
1290	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 10:00:00+00	42	0.9	91	0.1	25.4	94	1.44	159	2026-11-12 16:05:00.000406+00
1291	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 11:00:00+00	43	0.1	78	0.02	24.8	96	1.32	26	2026-11-12 16:05:00.000406+00
1292	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 12:00:00+00	44	0	63	0	24.8	96	0.79	0	2026-11-12 16:05:00.000406+00
1293	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 13:00:00+00	45	0	48	0	24.9	95	0.78	0	2026-11-12 16:05:00.000406+00
1294	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 14:00:00+00	46	0	32	0	24.8	94	0.49	0	2026-11-12 16:05:00.000406+00
1295	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 15:00:00+00	47	0.1	20	0	24.4	95	1.3	0	2026-11-12 16:05:00.000406+00
1296	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 16:00:00+00	2026-11-14 16:00:00+00	48	0.1	16	0	24.2	95	0.6	0	2026-11-12 16:05:00.000406+00
1297	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-12 18:00:00+00	1	0	12	0	24.4	92	0.76	0	2026-11-12 17:05:00.001359+00
1298	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-12 19:00:00+00	2	0	6	0	24	92	0.72	0	2026-11-12 17:05:00.001359+00
1299	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-12 20:00:00+00	3	0	5	0	23.9	91	0.28	0	2026-11-12 17:05:00.001359+00
1300	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-12 21:00:00+00	4	0	6	0	23.9	90	0.39	0	2026-11-12 17:05:00.001359+00
1301	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-12 22:00:00+00	5	0	8	0	23.7	90	0.63	0	2026-11-12 17:05:00.001359+00
1302	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-12 23:00:00+00	6	0	12	0	24.3	88	0.18	14	2026-11-12 17:05:00.001359+00
1303	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 00:00:00+00	7	0	14	0.1	25.7	82	0.92	142	2026-11-12 17:05:00.001359+00
1304	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 01:00:00+00	8	0	10	0.22	27	77	1.28	311	2026-11-12 17:05:00.001359+00
1305	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 02:00:00+00	9	0	5	0.37	28.4	71	1.41	504	2026-11-12 17:05:00.001359+00
1306	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 03:00:00+00	10	0	4	0.45	29.5	67	1.6	594	2026-11-12 17:05:00.001359+00
1307	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 04:00:00+00	11	0	11	0.55	30.4	65	2.01	731	2026-11-12 17:05:00.001359+00
1308	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 05:00:00+00	12	0.1	23	0.53	30.4	65	3.02	691	2026-11-12 17:05:00.001359+00
1309	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 06:00:00+00	13	0.1	37	0.49	31.3	61	1.63	619	2026-11-12 17:05:00.001359+00
1310	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 07:00:00+00	14	0.1	56	0.4	31.1	63	0.91	507	2026-11-12 17:05:00.001359+00
1311	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 08:00:00+00	15	0.2	78	0.28	30.2	66	0.49	352	2026-11-12 17:05:00.001359+00
1312	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 09:00:00+00	16	1.2	92	0.19	28	80	1.19	251	2026-11-12 17:05:00.001359+00
1313	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 10:00:00+00	17	0.4	93	0.09	27.3	84	1.24	106	2026-11-12 17:05:00.001359+00
1314	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 11:00:00+00	18	0	86	0.02	26.6	88	0.74	26	2026-11-12 17:05:00.001359+00
1315	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 12:00:00+00	19	0.2	78	0	25.8	95	1.4	0	2026-11-12 17:05:00.001359+00
1316	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 13:00:00+00	20	0.1	69	0	25.4	94	0.72	0	2026-11-12 17:05:00.001359+00
1317	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 14:00:00+00	21	0.4	58	0	24.5	96	1.82	0	2026-11-12 17:05:00.001359+00
1318	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 15:00:00+00	22	0.3	47	0	24.5	96	1.2	0	2026-11-12 17:05:00.001359+00
1319	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 16:00:00+00	23	0.2	37	0	24.5	96	1.3	0	2026-11-12 17:05:00.001359+00
1320	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 17:00:00+00	24	0	28	0	24.5	96	0.79	0	2026-11-12 17:05:00.001359+00
1321	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 18:00:00+00	25	0	22	0	24.5	93	0.32	0	2026-11-12 17:05:00.001359+00
1322	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 19:00:00+00	26	0	23	0	24.1	94	0.63	0	2026-11-12 17:05:00.001359+00
1323	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 20:00:00+00	27	0	28	0	23.9	94	0.54	0	2026-11-12 17:05:00.001359+00
1324	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 21:00:00+00	28	0	31	0	24.1	92	0.07	0	2026-11-12 17:05:00.001359+00
1325	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 22:00:00+00	29	0.5	29	0	23.7	93	0.39	0	2026-11-12 17:05:00.001359+00
1326	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-13 23:00:00+00	30	0.1	25	0.01	24	93	1.03	13	2026-11-12 17:05:00.001359+00
1327	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 00:00:00+00	31	0	22	0.1	24.8	90	0.96	163	2026-11-12 17:05:00.001359+00
1328	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 01:00:00+00	32	0	18	0.26	26.5	80	0.96	375	2026-11-12 17:05:00.001359+00
1329	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 02:00:00+00	33	0	15	0.44	28.6	71	1.25	610	2026-11-12 17:05:00.001359+00
1330	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 03:00:00+00	34	0	16	0.56	29.8	68	1.86	755	2026-11-12 17:05:00.001359+00
1331	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 04:00:00+00	35	0	25	0.51	29.6	70	1.59	677	2026-11-12 17:05:00.001359+00
1332	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 05:00:00+00	36	0	39	0.64	30.7	67	1.41	853	2026-11-12 17:05:00.001359+00
1333	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 06:00:00+00	37	0.2	53	0.63	31.1	66	1.61	831	2026-11-12 17:05:00.001359+00
1334	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 07:00:00+00	38	0.4	70	0.54	30.5	68	2.65	722	2026-11-12 17:05:00.001359+00
1335	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 08:00:00+00	39	4.9	87	0.25	25.9	91	1.21	360	2026-11-12 17:05:00.001359+00
1336	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 09:00:00+00	40	1.6	96	0.17	26	91	0.67	243	2026-11-12 17:05:00.001359+00
1337	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 10:00:00+00	41	0.9	91	0.1	25.4	94	1.44	159	2026-11-12 17:05:00.001359+00
1338	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 11:00:00+00	42	0.1	78	0.02	24.8	96	1.32	26	2026-11-12 17:05:00.001359+00
1339	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 12:00:00+00	43	0	63	0	24.8	96	0.79	0	2026-11-12 17:05:00.001359+00
1340	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 13:00:00+00	44	0	48	0	24.9	95	0.78	0	2026-11-12 17:05:00.001359+00
1341	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 14:00:00+00	45	0	32	0	24.8	94	0.49	0	2026-11-12 17:05:00.001359+00
1342	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 15:00:00+00	46	0.1	20	0	24.4	95	1.3	0	2026-11-12 17:05:00.001359+00
1343	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 16:00:00+00	47	0.1	16	0	24.2	95	0.6	0	2026-11-12 17:05:00.001359+00
1344	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 17:00:00+00	2026-11-14 17:00:00+00	48	0	17	0	24	94	0.14	0	2026-11-12 17:05:00.001359+00
1345	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-12 20:00:00+00	1	0	5	0	23.9	91	0.28	0	2026-11-12 19:05:00.000387+00
1346	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-12 21:00:00+00	2	0	6	0	23.9	90	0.39	0	2026-11-12 19:05:00.000387+00
1347	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-12 22:00:00+00	3	0	8	0	23.7	90	0.63	0	2026-11-12 19:05:00.000387+00
1348	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-12 23:00:00+00	4	0	12	0	24.3	88	0.18	14	2026-11-12 19:05:00.000387+00
1349	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 00:00:00+00	5	0	14	0.1	25.7	82	0.92	142	2026-11-12 19:05:00.000387+00
1350	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 01:00:00+00	6	0	10	0.22	27	77	1.28	311	2026-11-12 19:05:00.000387+00
1351	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 02:00:00+00	7	0	5	0.37	28.4	71	1.41	504	2026-11-12 19:05:00.000387+00
1352	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 03:00:00+00	8	0	4	0.45	29.5	67	1.6	594	2026-11-12 19:05:00.000387+00
1353	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 04:00:00+00	9	0	11	0.55	30.4	65	2.01	731	2026-11-12 19:05:00.000387+00
1354	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 05:00:00+00	10	0.1	23	0.53	30.4	65	3.02	691	2026-11-12 19:05:00.000387+00
1355	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 06:00:00+00	11	0.1	37	0.49	31.3	61	1.63	619	2026-11-12 19:05:00.000387+00
1356	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 07:00:00+00	12	0.1	56	0.4	31.1	63	0.91	507	2026-11-12 19:05:00.000387+00
1357	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 08:00:00+00	13	0.2	78	0.28	30.2	66	0.49	352	2026-11-12 19:05:00.000387+00
1358	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 09:00:00+00	14	1.2	92	0.19	28	80	1.19	251	2026-11-12 19:05:00.000387+00
1359	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 10:00:00+00	15	0.4	93	0.09	27.3	84	1.24	106	2026-11-12 19:05:00.000387+00
1360	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 11:00:00+00	16	0	86	0.02	26.6	88	0.74	26	2026-11-12 19:05:00.000387+00
1361	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 12:00:00+00	17	0.2	78	0	25.8	95	1.4	0	2026-11-12 19:05:00.000387+00
1362	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 13:00:00+00	18	0.1	69	0	25.4	94	0.72	0	2026-11-12 19:05:00.000387+00
1363	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 14:00:00+00	19	0.4	58	0	24.5	96	1.82	0	2026-11-12 19:05:00.000387+00
1364	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 15:00:00+00	20	0.3	47	0	24.5	96	1.2	0	2026-11-12 19:05:00.000387+00
1365	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 16:00:00+00	21	0.2	37	0	24.5	96	1.3	0	2026-11-12 19:05:00.000387+00
1366	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 17:00:00+00	22	0	28	0	24.5	96	0.79	0	2026-11-12 19:05:00.000387+00
1367	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 18:00:00+00	23	0	22	0	24.5	93	0.32	0	2026-11-12 19:05:00.000387+00
1368	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 19:00:00+00	24	0	23	0	24.1	94	0.63	0	2026-11-12 19:05:00.000387+00
1369	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 20:00:00+00	25	0	28	0	23.9	94	0.54	0	2026-11-12 19:05:00.000387+00
1370	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 21:00:00+00	26	0	31	0	24.1	92	0.07	0	2026-11-12 19:05:00.000387+00
1371	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 22:00:00+00	27	0.5	29	0	23.7	93	0.39	0	2026-11-12 19:05:00.000387+00
1372	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-13 23:00:00+00	28	0.1	25	0.01	24	93	1.03	13	2026-11-12 19:05:00.000387+00
1373	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 00:00:00+00	29	0	22	0.1	24.8	90	0.96	163	2026-11-12 19:05:00.000387+00
1374	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 01:00:00+00	30	0	18	0.26	26.5	80	0.96	375	2026-11-12 19:05:00.000387+00
1375	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 02:00:00+00	31	0	15	0.44	28.6	71	1.25	610	2026-11-12 19:05:00.000387+00
1376	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 03:00:00+00	32	0	16	0.56	29.8	68	1.86	755	2026-11-12 19:05:00.000387+00
1377	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 04:00:00+00	33	0	25	0.51	29.6	70	1.59	677	2026-11-12 19:05:00.000387+00
1378	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 05:00:00+00	34	0	39	0.64	30.7	67	1.41	853	2026-11-12 19:05:00.000387+00
1379	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 06:00:00+00	35	0.2	53	0.63	31.1	66	1.61	831	2026-11-12 19:05:00.000387+00
1380	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 07:00:00+00	36	0.4	70	0.54	30.5	68	2.65	722	2026-11-12 19:05:00.000387+00
1381	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 08:00:00+00	37	4.9	87	0.25	25.9	91	1.21	360	2026-11-12 19:05:00.000387+00
1382	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 09:00:00+00	38	1.6	96	0.17	26	91	0.67	243	2026-11-12 19:05:00.000387+00
1383	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 10:00:00+00	39	0.9	91	0.1	25.4	94	1.44	159	2026-11-12 19:05:00.000387+00
1384	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 11:00:00+00	40	0.1	78	0.02	24.8	96	1.32	26	2026-11-12 19:05:00.000387+00
1385	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 12:00:00+00	41	0	63	0	24.8	96	0.79	0	2026-11-12 19:05:00.000387+00
1386	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 13:00:00+00	42	0	48	0	24.9	95	0.78	0	2026-11-12 19:05:00.000387+00
1387	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 14:00:00+00	43	0	32	0	24.8	94	0.49	0	2026-11-12 19:05:00.000387+00
1388	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 15:00:00+00	44	0.1	20	0	24.4	95	1.3	0	2026-11-12 19:05:00.000387+00
1389	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 16:00:00+00	45	0.1	16	0	24.2	95	0.6	0	2026-11-12 19:05:00.000387+00
1390	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 17:00:00+00	46	0	17	0	24	94	0.14	0	2026-11-12 19:05:00.000387+00
1391	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 18:00:00+00	47	0.5	16	0	23.5	96	1.11	0	2026-11-12 19:05:00.000387+00
1392	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 19:00:00+00	2026-11-14 19:00:00+00	48	0.2	11	0	23.2	96	0.65	0	2026-11-12 19:05:00.000387+00
1393	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-12 21:00:00+00	1	0	6	0	24.2	87	0.96	0	2026-11-12 20:05:00.000822+00
1394	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-12 22:00:00+00	2	0	8	0	24.7	83	0.6	0	2026-11-12 20:05:00.000822+00
1395	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-12 23:00:00+00	3	0	12	0.01	25.1	84	0.95	13	2026-11-12 20:05:00.000822+00
1396	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 00:00:00+00	4	0	14	0.11	26.6	79	1.12	158	2026-11-12 20:05:00.000822+00
1397	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 01:00:00+00	5	0	10	0.24	28.2	70	0.46	341	2026-11-12 20:05:00.000822+00
1398	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 02:00:00+00	6	0	5	0.41	29.1	68	1.71	554	2026-11-12 20:05:00.000822+00
1399	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 03:00:00+00	7	0	4	0.51	29.7	67	2.26	686	2026-11-12 20:05:00.000822+00
1400	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 04:00:00+00	8	0	11	0.55	30.3	66	2.91	734	2026-11-12 20:05:00.000822+00
1401	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 05:00:00+00	9	0.1	23	0.59	30.5	65	0.61	774	2026-11-12 20:05:00.000822+00
1402	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 06:00:00+00	10	0.1	37	0.6	32	57	0.39	772	2026-11-12 20:05:00.000822+00
1403	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 07:00:00+00	11	0.1	56	0.52	31.4	59	2.78	657	2026-11-12 20:05:00.000822+00
1404	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 08:00:00+00	12	1.2	78	0.24	27.8	79	1.1	309	2026-11-12 20:05:00.000822+00
1405	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 09:00:00+00	13	0.1	92	0.15	27.3	82	1.09	194	2026-11-12 20:05:00.000822+00
1406	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 10:00:00+00	14	0	93	0.1	27	81	1.52	116	2026-11-12 20:05:00.000822+00
1407	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 11:00:00+00	15	0	86	0.02	26.4	85	0.78	26	2026-11-12 20:05:00.000822+00
1408	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 12:00:00+00	16	0	78	0	26.3	89	0.21	0	2026-11-12 20:05:00.000822+00
1409	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 13:00:00+00	17	0	69	0	25.6	92	1.21	0	2026-11-12 20:05:00.000822+00
1410	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 14:00:00+00	18	0.1	58	0	25.3	94	0.9	0	2026-11-12 20:05:00.000822+00
1411	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 15:00:00+00	19	0	47	0	25.1	94	0.27	0	2026-11-12 20:05:00.000822+00
1412	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 16:00:00+00	20	0	37	0	25	92	0.27	0	2026-11-12 20:05:00.000822+00
1413	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 17:00:00+00	21	0	28	0	24.9	90	0.54	0	2026-11-12 20:05:00.000822+00
1414	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 18:00:00+00	22	0	22	0	24.7	89	0.54	0	2026-11-12 20:05:00.000822+00
1415	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 19:00:00+00	23	0.8	23	0	24	94	0.14	0	2026-11-12 20:05:00.000822+00
1416	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 20:00:00+00	24	0.3	28	0	23.7	95	0.57	0	2026-11-12 20:05:00.000822+00
1417	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 21:00:00+00	25	0.1	31	0	23.5	96	0.45	0	2026-11-12 20:05:00.000822+00
1418	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 22:00:00+00	26	0.2	29	0	23.7	94	0.35	0	2026-11-12 20:05:00.000822+00
1419	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-13 23:00:00+00	27	0	25	0.01	23.9	92	0.85	16	2026-11-12 20:05:00.000822+00
1420	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 00:00:00+00	28	0	22	0.11	25.2	86	0.82	167	2026-11-12 20:05:00.000822+00
1421	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 01:00:00+00	29	0	18	0.27	26.6	81	0.94	395	2026-11-12 20:05:00.000822+00
1422	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 02:00:00+00	30	0	15	0.43	28.4	74	1.74	599	2026-11-12 20:05:00.000822+00
1423	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 03:00:00+00	31	0.1	16	0.55	28.3	77	0.7	765	2026-11-12 20:05:00.000822+00
1424	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 04:00:00+00	32	0.1	25	0.6	29.6	73	0.92	809	2026-11-12 20:05:00.000822+00
1425	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 05:00:00+00	33	0.1	39	0.66	30.6	68	0.94	877	2026-11-12 20:05:00.000822+00
1426	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 06:00:00+00	34	0.2	53	0.54	30.9	65	0.61	703	2026-11-12 20:05:00.000822+00
1427	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 07:00:00+00	35	0.2	70	0.44	30.1	68	0.95	577	2026-11-12 20:05:00.000822+00
1428	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 08:00:00+00	36	1.9	87	0.29	26.7	85	1.23	400	2026-11-12 20:05:00.000822+00
1429	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 09:00:00+00	37	0.9	96	0.22	27.2	82	0.79	299	2026-11-12 20:05:00.000822+00
1430	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 10:00:00+00	38	0.4	91	0.09	25.9	89	0.07	130	2026-11-12 20:05:00.000822+00
1431	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 11:00:00+00	39	0.2	78	0.02	25.7	91	0.6	22	2026-11-12 20:05:00.000822+00
1432	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 12:00:00+00	40	0	63	0	25.4	95	0.6	0	2026-11-12 20:05:00.000822+00
1433	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 13:00:00+00	41	0	48	0	25	98	0.5	0	2026-11-12 20:05:00.000822+00
1434	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 14:00:00+00	42	0	32	0	24.9	97	0.28	0	2026-11-12 20:05:00.000822+00
1435	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 15:00:00+00	43	0	20	0	24.5	98	0.2	0	2026-11-12 20:05:00.000822+00
1436	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 16:00:00+00	44	0	16	0	24.2	96	0.72	0	2026-11-12 20:05:00.000822+00
1437	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 17:00:00+00	45	0	17	0	24	94	0.72	0	2026-11-12 20:05:00.000822+00
1438	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 18:00:00+00	46	0	16	0	23.9	92	0.61	0	2026-11-12 20:05:00.000822+00
1439	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 19:00:00+00	47	0	11	0	23.8	91	0.57	0	2026-11-12 20:05:00.000822+00
1440	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 20:00:00+00	2026-11-14 20:00:00+00	48	0	6	0	23.6	90	0.61	0	2026-11-12 20:05:00.000822+00
1441	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-12 22:00:00+00	1	0	8	0	24.7	83	0.6	0	2026-11-12 21:05:00.000084+00
1442	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-12 23:00:00+00	2	0	12	0.01	25.1	84	0.95	13	2026-11-12 21:05:00.000084+00
1443	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 00:00:00+00	3	0	14	0.11	26.6	79	1.12	158	2026-11-12 21:05:00.000084+00
1444	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 01:00:00+00	4	0	10	0.24	28.2	70	0.46	341	2026-11-12 21:05:00.000084+00
1445	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 02:00:00+00	5	0	5	0.41	29.1	68	1.71	554	2026-11-12 21:05:00.000084+00
1446	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 03:00:00+00	6	0	4	0.51	29.7	67	2.26	686	2026-11-12 21:05:00.000084+00
1447	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 04:00:00+00	7	0	11	0.55	30.3	66	2.91	734	2026-11-12 21:05:00.000084+00
1448	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 05:00:00+00	8	0.1	23	0.59	30.5	65	0.61	774	2026-11-12 21:05:00.000084+00
1449	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 06:00:00+00	9	0.1	37	0.6	32	57	0.39	772	2026-11-12 21:05:00.000084+00
1450	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 07:00:00+00	10	0.1	56	0.52	31.4	59	2.78	657	2026-11-12 21:05:00.000084+00
1451	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 08:00:00+00	11	1.2	78	0.24	27.8	79	1.1	309	2026-11-12 21:05:00.000084+00
1452	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 09:00:00+00	12	0.1	92	0.15	27.3	82	1.09	194	2026-11-12 21:05:00.000084+00
1453	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 10:00:00+00	13	0	93	0.1	27	81	1.52	116	2026-11-12 21:05:00.000084+00
1454	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 11:00:00+00	14	0	86	0.02	26.4	85	0.78	26	2026-11-12 21:05:00.000084+00
1455	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 12:00:00+00	15	0	78	0	26.3	89	0.21	0	2026-11-12 21:05:00.000084+00
1456	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 13:00:00+00	16	0	69	0	25.6	92	1.21	0	2026-11-12 21:05:00.000084+00
1457	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 14:00:00+00	17	0.1	58	0	25.3	94	0.9	0	2026-11-12 21:05:00.000084+00
1458	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 15:00:00+00	18	0	47	0	25.1	94	0.27	0	2026-11-12 21:05:00.000084+00
1459	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 16:00:00+00	19	0	37	0	25	92	0.27	0	2026-11-12 21:05:00.000084+00
1460	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 17:00:00+00	20	0	28	0	24.9	90	0.54	0	2026-11-12 21:05:00.000084+00
1461	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 18:00:00+00	21	0	22	0	24.7	89	0.54	0	2026-11-12 21:05:00.000084+00
1462	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 19:00:00+00	22	0.8	23	0	24	94	0.14	0	2026-11-12 21:05:00.000084+00
1463	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 20:00:00+00	23	0.3	28	0	23.7	95	0.57	0	2026-11-12 21:05:00.000084+00
1464	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 21:00:00+00	24	0.1	31	0	23.5	96	0.45	0	2026-11-12 21:05:00.000084+00
1465	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 22:00:00+00	25	0.2	29	0	23.7	94	0.35	0	2026-11-12 21:05:00.000084+00
1466	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-13 23:00:00+00	26	0	25	0.01	23.9	92	0.85	16	2026-11-12 21:05:00.000084+00
1467	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 00:00:00+00	27	0	22	0.11	25.2	86	0.82	167	2026-11-12 21:05:00.000084+00
1468	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 01:00:00+00	28	0	18	0.27	26.6	81	0.94	395	2026-11-12 21:05:00.000084+00
1469	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 02:00:00+00	29	0	15	0.43	28.4	74	1.74	599	2026-11-12 21:05:00.000084+00
1470	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 03:00:00+00	30	0.1	16	0.55	28.3	77	0.7	765	2026-11-12 21:05:00.000084+00
1471	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 04:00:00+00	31	0.1	25	0.6	29.6	73	0.92	809	2026-11-12 21:05:00.000084+00
1472	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 05:00:00+00	32	0.1	39	0.66	30.6	68	0.94	877	2026-11-12 21:05:00.000084+00
1473	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 06:00:00+00	33	0.2	53	0.54	30.9	65	0.61	703	2026-11-12 21:05:00.000084+00
1474	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 07:00:00+00	34	0.2	70	0.44	30.1	68	0.95	577	2026-11-12 21:05:00.000084+00
1475	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 08:00:00+00	35	1.9	87	0.29	26.7	85	1.23	400	2026-11-12 21:05:00.000084+00
1476	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 09:00:00+00	36	0.9	96	0.22	27.2	82	0.79	299	2026-11-12 21:05:00.000084+00
1477	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 10:00:00+00	37	0.4	91	0.09	25.9	89	0.07	130	2026-11-12 21:05:00.000084+00
1478	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 11:00:00+00	38	0.2	78	0.02	25.7	91	0.6	22	2026-11-12 21:05:00.000084+00
1479	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 12:00:00+00	39	0	63	0	25.4	95	0.6	0	2026-11-12 21:05:00.000084+00
1480	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 13:00:00+00	40	0	48	0	25	98	0.5	0	2026-11-12 21:05:00.000084+00
1481	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 14:00:00+00	41	0	32	0	24.9	97	0.28	0	2026-11-12 21:05:00.000084+00
1482	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 15:00:00+00	42	0	20	0	24.5	98	0.2	0	2026-11-12 21:05:00.000084+00
1483	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 16:00:00+00	43	0	16	0	24.2	96	0.72	0	2026-11-12 21:05:00.000084+00
1484	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 17:00:00+00	44	0	17	0	24	94	0.72	0	2026-11-12 21:05:00.000084+00
1485	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 18:00:00+00	45	0	16	0	23.9	92	0.61	0	2026-11-12 21:05:00.000084+00
1486	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 19:00:00+00	46	0	11	0	23.8	91	0.57	0	2026-11-12 21:05:00.000084+00
1487	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 20:00:00+00	47	0	6	0	23.6	90	0.61	0	2026-11-12 21:05:00.000084+00
1488	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 21:00:00+00	2026-11-14 21:00:00+00	48	0	2	0	23.5	91	0.51	0	2026-11-12 21:05:00.000084+00
1489	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-12 23:00:00+00	1	0	12	0.01	25.1	84	0.95	13	2026-11-12 22:04:59.999305+00
1490	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 00:00:00+00	2	0	14	0.11	26.6	79	1.12	158	2026-11-12 22:04:59.999305+00
1491	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 01:00:00+00	3	0	10	0.24	28.2	70	0.46	341	2026-11-12 22:04:59.999305+00
1492	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 02:00:00+00	4	0	5	0.41	29.1	68	1.71	554	2026-11-12 22:04:59.999305+00
1493	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 03:00:00+00	5	0	4	0.51	29.7	67	2.26	686	2026-11-12 22:04:59.999305+00
1494	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 04:00:00+00	6	0	11	0.55	30.3	66	2.91	734	2026-11-12 22:04:59.999305+00
1495	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 05:00:00+00	7	0.1	23	0.59	30.5	65	0.61	774	2026-11-12 22:04:59.999305+00
1496	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 06:00:00+00	8	0.1	37	0.6	32	57	0.39	772	2026-11-12 22:04:59.999305+00
1497	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 07:00:00+00	9	0.1	56	0.52	31.4	59	2.78	657	2026-11-12 22:04:59.999305+00
1498	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 08:00:00+00	10	1.2	78	0.24	27.8	79	1.1	309	2026-11-12 22:04:59.999305+00
1499	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 09:00:00+00	11	0.1	92	0.15	27.3	82	1.09	194	2026-11-12 22:04:59.999305+00
1500	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 10:00:00+00	12	0	93	0.1	27	81	1.52	116	2026-11-12 22:04:59.999305+00
1501	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 11:00:00+00	13	0	86	0.02	26.4	85	0.78	26	2026-11-12 22:04:59.999305+00
1502	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 12:00:00+00	14	0	78	0	26.3	89	0.21	0	2026-11-12 22:04:59.999305+00
1503	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 13:00:00+00	15	0	69	0	25.6	92	1.21	0	2026-11-12 22:04:59.999305+00
1504	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 14:00:00+00	16	0.1	58	0	25.3	94	0.9	0	2026-11-12 22:04:59.999305+00
1505	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 15:00:00+00	17	0	47	0	25.1	94	0.27	0	2026-11-12 22:04:59.999305+00
1506	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 16:00:00+00	18	0	37	0	25	92	0.27	0	2026-11-12 22:04:59.999305+00
1507	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 17:00:00+00	19	0	28	0	24.9	90	0.54	0	2026-11-12 22:04:59.999305+00
1508	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 18:00:00+00	20	0	22	0	24.7	89	0.54	0	2026-11-12 22:04:59.999305+00
1509	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 19:00:00+00	21	0.8	23	0	24	94	0.14	0	2026-11-12 22:04:59.999305+00
1510	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 20:00:00+00	22	0.3	28	0	23.7	95	0.57	0	2026-11-12 22:04:59.999305+00
1511	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 21:00:00+00	23	0.1	31	0	23.5	96	0.45	0	2026-11-12 22:04:59.999305+00
1512	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 22:00:00+00	24	0.2	29	0	23.7	94	0.35	0	2026-11-12 22:04:59.999305+00
1513	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-13 23:00:00+00	25	0	25	0.01	23.9	92	0.85	16	2026-11-12 22:04:59.999305+00
1514	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 00:00:00+00	26	0	22	0.11	25.2	86	0.82	167	2026-11-12 22:04:59.999305+00
1515	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 01:00:00+00	27	0	18	0.27	26.6	81	0.94	395	2026-11-12 22:04:59.999305+00
1516	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 02:00:00+00	28	0	15	0.43	28.4	74	1.74	599	2026-11-12 22:04:59.999305+00
1517	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 03:00:00+00	29	0.1	16	0.55	28.3	77	0.7	765	2026-11-12 22:04:59.999305+00
1518	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 04:00:00+00	30	0.1	25	0.6	29.6	73	0.92	809	2026-11-12 22:04:59.999305+00
1519	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 05:00:00+00	31	0.1	39	0.66	30.6	68	0.94	877	2026-11-12 22:04:59.999305+00
1520	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 06:00:00+00	32	0.2	53	0.54	30.9	65	0.61	703	2026-11-12 22:04:59.999305+00
1521	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 07:00:00+00	33	0.2	70	0.44	30.1	68	0.95	577	2026-11-12 22:04:59.999305+00
1522	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 08:00:00+00	34	1.9	87	0.29	26.7	85	1.23	400	2026-11-12 22:04:59.999305+00
1523	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 09:00:00+00	35	0.9	96	0.22	27.2	82	0.79	299	2026-11-12 22:04:59.999305+00
1524	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 10:00:00+00	36	0.4	91	0.09	25.9	89	0.07	130	2026-11-12 22:04:59.999305+00
1525	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 11:00:00+00	37	0.2	78	0.02	25.7	91	0.6	22	2026-11-12 22:04:59.999305+00
1526	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 12:00:00+00	38	0	63	0	25.4	95	0.6	0	2026-11-12 22:04:59.999305+00
1527	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 13:00:00+00	39	0	48	0	25	98	0.5	0	2026-11-12 22:04:59.999305+00
1528	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 14:00:00+00	40	0	32	0	24.9	97	0.28	0	2026-11-12 22:04:59.999305+00
1529	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 15:00:00+00	41	0	20	0	24.5	98	0.2	0	2026-11-12 22:04:59.999305+00
1530	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 16:00:00+00	42	0	16	0	24.2	96	0.72	0	2026-11-12 22:04:59.999305+00
1531	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 17:00:00+00	43	0	17	0	24	94	0.72	0	2026-11-12 22:04:59.999305+00
1532	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 18:00:00+00	44	0	16	0	23.9	92	0.61	0	2026-11-12 22:04:59.999305+00
1533	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 19:00:00+00	45	0	11	0	23.8	91	0.57	0	2026-11-12 22:04:59.999305+00
1534	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 20:00:00+00	46	0	6	0	23.6	90	0.61	0	2026-11-12 22:04:59.999305+00
1535	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 21:00:00+00	47	0	2	0	23.5	91	0.51	0	2026-11-12 22:04:59.999305+00
1536	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 22:00:00+00	2026-11-14 22:00:00+00	48	0	2	0	23.5	90	0.92	0	2026-11-12 22:04:59.999305+00
1537	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 00:00:00+00	1	0	0	0.11	26.6	79	1.12	158	2026-11-12 23:04:59.999358+00
1538	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 01:00:00+00	2	0	0	0.24	28.2	70	0.46	341	2026-11-12 23:04:59.999358+00
1539	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 02:00:00+00	3	0	0	0.41	29.1	68	1.71	554	2026-11-12 23:04:59.999358+00
1540	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 03:00:00+00	4	0	2	0.51	29.7	67	2.26	686	2026-11-12 23:04:59.999358+00
1541	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 04:00:00+00	5	0	8	0.55	30.3	66	2.91	734	2026-11-12 23:04:59.999358+00
1542	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 05:00:00+00	6	0.1	16	0.59	30.5	65	0.61	774	2026-11-12 23:04:59.999358+00
1543	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 06:00:00+00	7	0.1	29	0.6	32	57	0.39	772	2026-11-12 23:04:59.999358+00
1544	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 07:00:00+00	8	0.1	53	0.52	31.4	59	2.78	657	2026-11-12 23:04:59.999358+00
1545	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 08:00:00+00	9	1.2	82	0.24	27.8	79	1.1	309	2026-11-12 23:04:59.999358+00
1546	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 09:00:00+00	10	0.1	100	0.15	27.3	82	1.09	194	2026-11-12 23:04:59.999358+00
1547	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 10:00:00+00	11	0	97	0.1	27	81	1.52	116	2026-11-12 23:04:59.999358+00
1548	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 11:00:00+00	12	0	82	0.02	26.4	85	0.78	26	2026-11-12 23:04:59.999358+00
1549	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 12:00:00+00	13	0	69	0	26.3	89	0.21	0	2026-11-12 23:04:59.999358+00
1550	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 13:00:00+00	14	0	63	0	25.6	92	1.21	0	2026-11-12 23:04:59.999358+00
1551	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 14:00:00+00	15	0.1	58	0	25.3	94	0.9	0	2026-11-12 23:04:59.999358+00
1552	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 15:00:00+00	16	0	53	0	25.1	94	0.27	0	2026-11-12 23:04:59.999358+00
1553	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 16:00:00+00	17	0	44	0	25	92	0.27	0	2026-11-12 23:04:59.999358+00
1554	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 17:00:00+00	18	0	35	0	24.9	90	0.54	0	2026-11-12 23:04:59.999358+00
1555	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 18:00:00+00	19	0	29	0	24.7	89	0.54	0	2026-11-12 23:04:59.999358+00
1556	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 19:00:00+00	20	0.8	30	0	24	94	0.14	0	2026-11-12 23:04:59.999358+00
1557	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 20:00:00+00	21	0.3	35	0	23.7	95	0.57	0	2026-11-12 23:04:59.999358+00
1558	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 21:00:00+00	22	0.1	37	0	23.5	96	0.45	0	2026-11-12 23:04:59.999358+00
1559	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 22:00:00+00	23	0.2	34	0	23.7	94	0.35	0	2026-11-12 23:04:59.999358+00
1560	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-13 23:00:00+00	24	0	30	0.01	23.9	92	0.85	16	2026-11-12 23:04:59.999358+00
1561	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 00:00:00+00	25	0	25	0.11	25.2	86	0.82	167	2026-11-12 23:04:59.999358+00
1562	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 01:00:00+00	26	0	21	0.27	26.6	81	0.94	395	2026-11-12 23:04:59.999358+00
1563	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 02:00:00+00	27	0	17	0.43	28.4	74	1.74	599	2026-11-12 23:04:59.999358+00
1564	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 03:00:00+00	28	0.1	16	0.55	28.3	77	0.7	765	2026-11-12 23:04:59.999358+00
1565	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 04:00:00+00	29	0.1	18	0.6	29.6	73	0.92	809	2026-11-12 23:04:59.999358+00
1566	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 05:00:00+00	30	0.1	23	0.66	30.6	68	0.94	877	2026-11-12 23:04:59.999358+00
1567	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 06:00:00+00	31	0.2	33	0.54	30.9	65	0.61	703	2026-11-12 23:04:59.999358+00
1568	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 07:00:00+00	32	0.2	55	0.44	30.1	68	0.95	577	2026-11-12 23:04:59.999358+00
1569	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 08:00:00+00	33	1.9	82	0.29	26.7	85	1.23	400	2026-11-12 23:04:59.999358+00
1570	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 09:00:00+00	34	0.9	98	0.22	27.2	82	0.79	299	2026-11-12 23:04:59.999358+00
1571	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 10:00:00+00	35	0.4	93	0.09	25.9	89	0.07	130	2026-11-12 23:04:59.999358+00
1572	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 11:00:00+00	36	0.2	77	0.02	25.7	91	0.6	22	2026-11-12 23:04:59.999358+00
1573	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 12:00:00+00	37	0	61	0	25.4	95	0.6	0	2026-11-12 23:04:59.999358+00
1574	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 13:00:00+00	38	0	46	0	25	98	0.5	0	2026-11-12 23:04:59.999358+00
1575	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 14:00:00+00	39	0	32	0	24.9	97	0.28	0	2026-11-12 23:04:59.999358+00
1576	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 15:00:00+00	40	0	20	0	24.5	98	0.2	0	2026-11-12 23:04:59.999358+00
1577	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 16:00:00+00	41	0	14	0	24.2	96	0.72	0	2026-11-12 23:04:59.999358+00
1578	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 17:00:00+00	42	0	12	0	24	94	0.72	0	2026-11-12 23:04:59.999358+00
1579	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 18:00:00+00	43	0	10	0	23.9	92	0.61	0	2026-11-12 23:04:59.999358+00
1580	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 19:00:00+00	44	0	7	0	23.8	91	0.57	0	2026-11-12 23:04:59.999358+00
1581	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 20:00:00+00	45	0	5	0	23.6	90	0.61	0	2026-11-12 23:04:59.999358+00
1582	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 21:00:00+00	46	0	4	0	23.5	91	0.51	0	2026-11-12 23:04:59.999358+00
1583	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 22:00:00+00	47	0	3	0	23.5	90	0.92	0	2026-11-12 23:04:59.999358+00
1584	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-12 23:00:00+00	2026-11-14 23:00:00+00	48	0	4	0.01	24	88	0.79	16	2026-11-12 23:04:59.999358+00
1585	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 01:00:00+00	1	0	0	0.24	28.2	70	0.46	341	2026-11-13 00:04:59.999591+00
1586	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 02:00:00+00	2	0	0	0.41	29.1	68	1.71	554	2026-11-13 00:04:59.999591+00
1587	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 03:00:00+00	3	0	2	0.51	29.7	67	2.26	686	2026-11-13 00:04:59.999591+00
1588	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 04:00:00+00	4	0	8	0.55	30.3	66	2.91	734	2026-11-13 00:04:59.999591+00
1589	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 05:00:00+00	5	0.1	16	0.59	30.5	65	0.61	774	2026-11-13 00:04:59.999591+00
1590	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 06:00:00+00	6	0.1	29	0.6	32	57	0.39	772	2026-11-13 00:04:59.999591+00
1591	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 07:00:00+00	7	0.1	53	0.52	31.4	59	2.78	657	2026-11-13 00:04:59.999591+00
1592	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 08:00:00+00	8	1.2	82	0.24	27.8	79	1.1	309	2026-11-13 00:04:59.999591+00
1593	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 09:00:00+00	9	0.1	100	0.15	27.3	82	1.09	194	2026-11-13 00:04:59.999591+00
1594	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 10:00:00+00	10	0	97	0.1	27	81	1.52	116	2026-11-13 00:04:59.999591+00
1595	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 11:00:00+00	11	0	82	0.02	26.4	85	0.78	26	2026-11-13 00:04:59.999591+00
1596	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 12:00:00+00	12	0	69	0	26.3	89	0.21	0	2026-11-13 00:04:59.999591+00
1597	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 13:00:00+00	13	0	63	0	25.6	92	1.21	0	2026-11-13 00:04:59.999591+00
1598	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 14:00:00+00	14	0.1	58	0	25.3	94	0.9	0	2026-11-13 00:04:59.999591+00
1599	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 15:00:00+00	15	0	53	0	25.1	94	0.27	0	2026-11-13 00:04:59.999591+00
1600	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 16:00:00+00	16	0	44	0	25	92	0.27	0	2026-11-13 00:04:59.999591+00
1601	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 17:00:00+00	17	0	35	0	24.9	90	0.54	0	2026-11-13 00:04:59.999591+00
1602	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 18:00:00+00	18	0	29	0	24.7	89	0.54	0	2026-11-13 00:04:59.999591+00
1603	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 19:00:00+00	19	0.8	30	0	24	94	0.14	0	2026-11-13 00:04:59.999591+00
1604	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 20:00:00+00	20	0.3	35	0	23.7	95	0.57	0	2026-11-13 00:04:59.999591+00
1605	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 21:00:00+00	21	0.1	37	0	23.5	96	0.45	0	2026-11-13 00:04:59.999591+00
1606	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 22:00:00+00	22	0.2	34	0	23.7	94	0.35	0	2026-11-13 00:04:59.999591+00
1607	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-13 23:00:00+00	23	0	30	0.01	23.9	92	0.85	16	2026-11-13 00:04:59.999591+00
1608	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 00:00:00+00	24	0	25	0.11	25.2	86	0.82	167	2026-11-13 00:04:59.999591+00
1609	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 01:00:00+00	25	0	21	0.27	26.6	81	0.94	395	2026-11-13 00:04:59.999591+00
1610	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 02:00:00+00	26	0	17	0.43	28.4	74	1.74	599	2026-11-13 00:04:59.999591+00
1611	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 03:00:00+00	27	0.1	16	0.55	28.3	77	0.7	765	2026-11-13 00:04:59.999591+00
1612	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 04:00:00+00	28	0.1	18	0.6	29.6	73	0.92	809	2026-11-13 00:04:59.999591+00
1613	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 05:00:00+00	29	0.1	23	0.66	30.6	68	0.94	877	2026-11-13 00:04:59.999591+00
1614	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 06:00:00+00	30	0.2	33	0.54	30.9	65	0.61	703	2026-11-13 00:04:59.999591+00
1615	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 07:00:00+00	31	0.2	55	0.44	30.1	68	0.95	577	2026-11-13 00:04:59.999591+00
1616	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 08:00:00+00	32	1.9	82	0.29	26.7	85	1.23	400	2026-11-13 00:04:59.999591+00
1617	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 09:00:00+00	33	0.9	98	0.22	27.2	82	0.79	299	2026-11-13 00:04:59.999591+00
1618	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 10:00:00+00	34	0.4	93	0.09	25.9	89	0.07	130	2026-11-13 00:04:59.999591+00
1619	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 11:00:00+00	35	0.2	77	0.02	25.7	91	0.6	22	2026-11-13 00:04:59.999591+00
1620	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 12:00:00+00	36	0	61	0	25.4	95	0.6	0	2026-11-13 00:04:59.999591+00
1621	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 13:00:00+00	37	0	46	0	25	98	0.5	0	2026-11-13 00:04:59.999591+00
1622	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 14:00:00+00	38	0	32	0	24.9	97	0.28	0	2026-11-13 00:04:59.999591+00
1623	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 15:00:00+00	39	0	20	0	24.5	98	0.2	0	2026-11-13 00:04:59.999591+00
1624	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 16:00:00+00	40	0	14	0	24.2	96	0.72	0	2026-11-13 00:04:59.999591+00
1625	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 17:00:00+00	41	0	12	0	24	94	0.72	0	2026-11-13 00:04:59.999591+00
1626	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 18:00:00+00	42	0	10	0	23.9	92	0.61	0	2026-11-13 00:04:59.999591+00
1627	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 19:00:00+00	43	0	7	0	23.8	91	0.57	0	2026-11-13 00:04:59.999591+00
1628	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 20:00:00+00	44	0	5	0	23.6	90	0.61	0	2026-11-13 00:04:59.999591+00
1629	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 21:00:00+00	45	0	4	0	23.5	91	0.51	0	2026-11-13 00:04:59.999591+00
1630	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 22:00:00+00	46	0	3	0	23.5	90	0.92	0	2026-11-13 00:04:59.999591+00
1631	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-14 23:00:00+00	47	0	4	0.01	24	88	0.79	16	2026-11-13 00:04:59.999591+00
1632	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 00:00:00+00	2026-11-15 00:00:00+00	48	0	4	0.11	26.4	79	0.57	175	2026-11-13 00:04:59.999591+00
1633	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 02:00:00+00	1	0	0	0.43	29.6	64	1.5	575	2026-11-13 01:05:00.000792+00
1634	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 03:00:00+00	2	0	2	0.56	30.6	61	2.21	737	2026-11-13 01:05:00.000792+00
1635	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 04:00:00+00	3	0	8	0.65	31.6	58	3.15	838	2026-11-13 01:05:00.000792+00
1636	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 05:00:00+00	4	0.2	16	0.67	30.9	62	3.61	897	2026-11-13 01:05:00.000792+00
1637	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 06:00:00+00	5	1.9	29	0.54	31	61	2.24	700	2026-11-13 01:05:00.000792+00
1638	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 07:00:00+00	6	0.9	53	0.51	29.9	68	1.44	683	2026-11-13 01:05:00.000792+00
1639	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 08:00:00+00	7	0.9	82	0.4	29.2	72	1.77	534	2026-11-13 01:05:00.000792+00
1640	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 09:00:00+00	8	0.1	100	0.23	28.2	75	1.66	305	2026-11-13 01:05:00.000792+00
1641	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 10:00:00+00	9	0	97	0.09	27.2	79	0.74	107	2026-11-13 01:05:00.000792+00
1642	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 11:00:00+00	10	0.1	82	0.03	26	87	1.19	20	2026-11-13 01:05:00.000792+00
1643	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 12:00:00+00	11	0	69	0	25.5	92	0.14	0	2026-11-13 01:05:00.000792+00
1644	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 13:00:00+00	12	0	63	0	25.6	91	0.6	0	2026-11-13 01:05:00.000792+00
1645	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 14:00:00+00	13	0	58	0	25.5	91	0.1	0	2026-11-13 01:05:00.000792+00
1646	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 15:00:00+00	14	0	53	0	25.2	92	0.18	0	2026-11-13 01:05:00.000792+00
1647	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 16:00:00+00	15	0	44	0	24.9	91	0.34	0	2026-11-13 01:05:00.000792+00
1648	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 17:00:00+00	16	0	35	0	24.8	89	0.43	0	2026-11-13 01:05:00.000792+00
1649	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 18:00:00+00	17	0	29	0	24.5	89	0.42	0	2026-11-13 01:05:00.000792+00
1650	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 19:00:00+00	18	0	30	0	24.2	90	0.3	0	2026-11-13 01:05:00.000792+00
1651	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 20:00:00+00	19	0	35	0	23.9	89	0.6	0	2026-11-13 01:05:00.000792+00
1652	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 21:00:00+00	20	0	37	0	23.7	88	0.8	0	2026-11-13 01:05:00.000792+00
1653	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 22:00:00+00	21	0	34	0	23.6	87	0.81	0	2026-11-13 01:05:00.000792+00
1654	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-13 23:00:00+00	22	0	30	0	24.3	84	0.25	16	2026-11-13 01:05:00.000792+00
1655	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 00:00:00+00	23	0	25	0.1	26.1	77	0.11	161	2026-11-13 01:05:00.000792+00
1656	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 01:00:00+00	24	0	21	0.28	27.2	76	1.19	397	2026-11-13 01:05:00.000792+00
1657	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 02:00:00+00	25	0	17	0.41	28.5	73	1.52	563	2026-11-13 01:05:00.000792+00
1658	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 03:00:00+00	26	0.1	16	0.51	28.5	77	1.36	709	2026-11-13 01:05:00.000792+00
1659	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 04:00:00+00	27	0.1	18	0.58	29.3	75	1.14	782	2026-11-13 01:05:00.000792+00
1660	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 05:00:00+00	28	0.1	23	0.6	30.2	71	0.8	790	2026-11-13 01:05:00.000792+00
1661	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 06:00:00+00	29	0	33	0.6	30.4	69	0.92	800	2026-11-13 01:05:00.000792+00
1662	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 07:00:00+00	30	0.2	55	0.45	30.9	67	1.32	581	2026-11-13 01:05:00.000792+00
1663	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 08:00:00+00	31	0.9	82	0.35	28	77	2.01	483	2026-11-13 01:05:00.000792+00
1664	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 09:00:00+00	32	1.4	98	0.19	26.7	86	0.86	256	2026-11-13 01:05:00.000792+00
1665	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 10:00:00+00	33	1.1	93	0.07	25.6	93	0.47	100	2026-11-13 01:05:00.000792+00
1666	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 11:00:00+00	34	0.2	77	0.02	25.4	95	0.16	24	2026-11-13 01:05:00.000792+00
1667	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 12:00:00+00	35	0	61	0	25.2	98	0.16	0	2026-11-13 01:05:00.000792+00
1668	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 13:00:00+00	36	0	46	0	25	98	0.22	0	2026-11-13 01:05:00.000792+00
1669	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 14:00:00+00	37	0	32	0	24.9	97	0.71	0	2026-11-13 01:05:00.000792+00
1670	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 15:00:00+00	38	0	20	0	24.7	96	0.73	0	2026-11-13 01:05:00.000792+00
1671	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 16:00:00+00	39	0	14	0	24.5	93	0.81	0	2026-11-13 01:05:00.000792+00
1672	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 17:00:00+00	40	0	12	0	24.3	92	0.68	0	2026-11-13 01:05:00.000792+00
1673	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 18:00:00+00	41	0	10	0	24.2	91	0.35	0	2026-11-13 01:05:00.000792+00
1674	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 19:00:00+00	42	0	7	0	24.1	91	0.35	0	2026-11-13 01:05:00.000792+00
1675	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 20:00:00+00	43	0	5	0	23.7	92	0.58	0	2026-11-13 01:05:00.000792+00
1676	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 21:00:00+00	44	0	4	0	23.5	92	0.51	0	2026-11-13 01:05:00.000792+00
1677	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 22:00:00+00	45	0	3	0	23.6	90	0.42	0	2026-11-13 01:05:00.000792+00
1678	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-14 23:00:00+00	46	0	4	0.01	24.2	90	0.65	16	2026-11-13 01:05:00.000792+00
1679	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-15 00:00:00+00	47	0	4	0.11	26.2	81	0.11	177	2026-11-13 01:05:00.000792+00
1680	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 01:00:00+00	2026-11-15 01:00:00+00	48	0	2	0.28	27.7	75	0.98	408	2026-11-13 01:05:00.000792+00
1681	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 03:00:00+00	1	0	2	0.56	30.6	61	2.21	737	2026-11-13 02:05:00.000695+00
1682	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 04:00:00+00	2	0	8	0.65	31.6	58	3.15	838	2026-11-13 02:05:00.000695+00
1683	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 05:00:00+00	3	0.2	16	0.67	30.9	62	3.61	897	2026-11-13 02:05:00.000695+00
1684	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 06:00:00+00	4	1.9	29	0.54	31	61	2.24	700	2026-11-13 02:05:00.000695+00
1685	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 07:00:00+00	5	0.9	53	0.51	29.9	68	1.44	683	2026-11-13 02:05:00.000695+00
1686	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 08:00:00+00	6	0.9	82	0.4	29.2	72	1.77	534	2026-11-13 02:05:00.000695+00
1687	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 09:00:00+00	7	0.1	100	0.23	28.2	75	1.66	305	2026-11-13 02:05:00.000695+00
1688	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 10:00:00+00	8	0	97	0.09	27.2	79	0.74	107	2026-11-13 02:05:00.000695+00
1689	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 11:00:00+00	9	0.1	82	0.03	26	87	1.19	20	2026-11-13 02:05:00.000695+00
1690	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 12:00:00+00	10	0	69	0	25.5	92	0.14	0	2026-11-13 02:05:00.000695+00
1691	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 13:00:00+00	11	0	63	0	25.6	91	0.6	0	2026-11-13 02:05:00.000695+00
1692	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 14:00:00+00	12	0	58	0	25.5	91	0.1	0	2026-11-13 02:05:00.000695+00
1693	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 15:00:00+00	13	0	53	0	25.2	92	0.18	0	2026-11-13 02:05:00.000695+00
1694	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 16:00:00+00	14	0	44	0	24.9	91	0.34	0	2026-11-13 02:05:00.000695+00
1695	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 17:00:00+00	15	0	35	0	24.8	89	0.43	0	2026-11-13 02:05:00.000695+00
1696	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 18:00:00+00	16	0	29	0	24.5	89	0.42	0	2026-11-13 02:05:00.000695+00
1697	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 19:00:00+00	17	0	30	0	24.2	90	0.3	0	2026-11-13 02:05:00.000695+00
1698	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 20:00:00+00	18	0	35	0	23.9	89	0.6	0	2026-11-13 02:05:00.000695+00
1699	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 21:00:00+00	19	0	37	0	23.7	88	0.8	0	2026-11-13 02:05:00.000695+00
1700	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 22:00:00+00	20	0	34	0	23.6	87	0.81	0	2026-11-13 02:05:00.000695+00
1701	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-13 23:00:00+00	21	0	30	0	24.3	84	0.25	16	2026-11-13 02:05:00.000695+00
1702	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 00:00:00+00	22	0	25	0.1	26.1	77	0.11	161	2026-11-13 02:05:00.000695+00
1703	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 01:00:00+00	23	0	21	0.28	27.2	76	1.19	397	2026-11-13 02:05:00.000695+00
1704	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 02:00:00+00	24	0	17	0.41	28.5	73	1.52	563	2026-11-13 02:05:00.000695+00
1705	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 03:00:00+00	25	0.1	16	0.51	28.5	77	1.36	709	2026-11-13 02:05:00.000695+00
1706	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 04:00:00+00	26	0.1	18	0.58	29.3	75	1.14	782	2026-11-13 02:05:00.000695+00
1707	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 05:00:00+00	27	0.1	23	0.6	30.2	71	0.8	790	2026-11-13 02:05:00.000695+00
1708	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 06:00:00+00	28	0	33	0.6	30.4	69	0.92	800	2026-11-13 02:05:00.000695+00
1709	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 07:00:00+00	29	0.2	55	0.45	30.9	67	1.32	581	2026-11-13 02:05:00.000695+00
1710	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 08:00:00+00	30	0.9	82	0.35	28	77	2.01	483	2026-11-13 02:05:00.000695+00
1711	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 09:00:00+00	31	1.4	98	0.19	26.7	86	0.86	256	2026-11-13 02:05:00.000695+00
1712	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 10:00:00+00	32	1.1	93	0.07	25.6	93	0.47	100	2026-11-13 02:05:00.000695+00
1713	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 11:00:00+00	33	0.2	77	0.02	25.4	95	0.16	24	2026-11-13 02:05:00.000695+00
1714	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 12:00:00+00	34	0	61	0	25.2	98	0.16	0	2026-11-13 02:05:00.000695+00
1715	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 13:00:00+00	35	0	46	0	25	98	0.22	0	2026-11-13 02:05:00.000695+00
1716	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 14:00:00+00	36	0	32	0	24.9	97	0.71	0	2026-11-13 02:05:00.000695+00
1717	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 15:00:00+00	37	0	20	0	24.7	96	0.73	0	2026-11-13 02:05:00.000695+00
1718	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 16:00:00+00	38	0	14	0	24.5	93	0.81	0	2026-11-13 02:05:00.000695+00
1719	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 17:00:00+00	39	0	12	0	24.3	92	0.68	0	2026-11-13 02:05:00.000695+00
1720	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 18:00:00+00	40	0	10	0	24.2	91	0.35	0	2026-11-13 02:05:00.000695+00
1721	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 19:00:00+00	41	0	7	0	24.1	91	0.35	0	2026-11-13 02:05:00.000695+00
1722	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 20:00:00+00	42	0	5	0	23.7	92	0.58	0	2026-11-13 02:05:00.000695+00
1723	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 21:00:00+00	43	0	4	0	23.5	92	0.51	0	2026-11-13 02:05:00.000695+00
1724	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 22:00:00+00	44	0	3	0	23.6	90	0.42	0	2026-11-13 02:05:00.000695+00
1725	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-14 23:00:00+00	45	0	4	0.01	24.2	90	0.65	16	2026-11-13 02:05:00.000695+00
1726	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-15 00:00:00+00	46	0	4	0.11	26.2	81	0.11	177	2026-11-13 02:05:00.000695+00
1727	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-15 01:00:00+00	47	0	2	0.28	27.7	75	0.98	408	2026-11-13 02:05:00.000695+00
1728	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 02:00:00+00	2026-11-15 02:00:00+00	48	0	1	0.45	28.9	71	1.29	631	2026-11-13 02:05:00.000695+00
1729	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 04:00:00+00	1	0	5	0.65	31.6	58	3.15	838	2026-11-13 03:05:00.001269+00
1730	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 05:00:00+00	2	0.2	12	0.67	30.9	62	3.61	897	2026-11-13 03:05:00.001269+00
1731	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 06:00:00+00	3	1.9	25	0.54	31	61	2.24	700	2026-11-13 03:05:00.001269+00
1732	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 07:00:00+00	4	0.9	49	0.51	29.9	68	1.44	683	2026-11-13 03:05:00.001269+00
1733	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 08:00:00+00	5	0.9	79	0.4	29.2	72	1.77	534	2026-11-13 03:05:00.001269+00
1734	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 09:00:00+00	6	0.1	98	0.23	28.2	75	1.66	305	2026-11-13 03:05:00.001269+00
1735	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 10:00:00+00	7	0	97	0.09	27.2	79	0.74	107	2026-11-13 03:05:00.001269+00
1736	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 11:00:00+00	8	0.1	84	0.03	26	87	1.19	20	2026-11-13 03:05:00.001269+00
1737	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 12:00:00+00	9	0	71	0	25.5	92	0.14	0	2026-11-13 03:05:00.001269+00
1738	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 13:00:00+00	10	0	61	0	25.6	91	0.6	0	2026-11-13 03:05:00.001269+00
1739	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 14:00:00+00	11	0	51	0	25.5	91	0.1	0	2026-11-13 03:05:00.001269+00
1740	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 15:00:00+00	12	0	41	0	25.2	92	0.18	0	2026-11-13 03:05:00.001269+00
1741	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 16:00:00+00	13	0	31	0	24.9	91	0.34	0	2026-11-13 03:05:00.001269+00
1742	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 17:00:00+00	14	0	21	0	24.8	89	0.43	0	2026-11-13 03:05:00.001269+00
1743	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 18:00:00+00	15	0	14	0	24.5	89	0.42	0	2026-11-13 03:05:00.001269+00
1744	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 19:00:00+00	16	0	12	0	24.2	90	0.3	0	2026-11-13 03:05:00.001269+00
1745	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 20:00:00+00	17	0	14	0	23.9	89	0.6	0	2026-11-13 03:05:00.001269+00
1746	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 21:00:00+00	18	0	16	0	23.7	88	0.8	0	2026-11-13 03:05:00.001269+00
1747	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 22:00:00+00	19	0	18	0	23.6	87	0.81	0	2026-11-13 03:05:00.001269+00
1748	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-13 23:00:00+00	20	0	21	0	24.3	84	0.25	16	2026-11-13 03:05:00.001269+00
1749	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 00:00:00+00	21	0	22	0.1	26.1	77	0.11	161	2026-11-13 03:05:00.001269+00
1750	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 01:00:00+00	22	0	21	0.28	27.2	76	1.19	397	2026-11-13 03:05:00.001269+00
1751	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 02:00:00+00	23	0	18	0.41	28.5	73	1.52	563	2026-11-13 03:05:00.001269+00
1752	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 03:00:00+00	24	0.1	18	0.51	28.5	77	1.36	709	2026-11-13 03:05:00.001269+00
1753	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 04:00:00+00	25	0.1	21	0.58	29.3	75	1.14	782	2026-11-13 03:05:00.001269+00
1754	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 05:00:00+00	26	0.1	27	0.6	30.2	71	0.8	790	2026-11-13 03:05:00.001269+00
1755	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 06:00:00+00	27	0	37	0.6	30.4	69	0.92	800	2026-11-13 03:05:00.001269+00
1756	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 07:00:00+00	28	0.2	58	0.45	30.9	67	1.32	581	2026-11-13 03:05:00.001269+00
1757	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 08:00:00+00	29	0.9	83	0.35	28	77	2.01	483	2026-11-13 03:05:00.001269+00
1758	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 09:00:00+00	30	1.4	98	0.19	26.7	86	0.86	256	2026-11-13 03:05:00.001269+00
1759	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 10:00:00+00	31	1.1	95	0.07	25.6	93	0.47	100	2026-11-13 03:05:00.001269+00
1760	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 11:00:00+00	32	0.2	81	0.02	25.4	95	0.16	24	2026-11-13 03:05:00.001269+00
1761	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 12:00:00+00	33	0	65	0	25.2	98	0.16	0	2026-11-13 03:05:00.001269+00
1762	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 13:00:00+00	34	0	48	0	25	98	0.22	0	2026-11-13 03:05:00.001269+00
1763	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 14:00:00+00	35	0	29	0	24.9	97	0.71	0	2026-11-13 03:05:00.001269+00
1764	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 15:00:00+00	36	0	16	0	24.7	96	0.73	0	2026-11-13 03:05:00.001269+00
1765	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 16:00:00+00	37	0	13	0	24.5	93	0.81	0	2026-11-13 03:05:00.001269+00
1766	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 17:00:00+00	38	0	15	0	24.3	92	0.68	0	2026-11-13 03:05:00.001269+00
1767	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 18:00:00+00	39	0	16	0	24.2	91	0.35	0	2026-11-13 03:05:00.001269+00
1768	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 19:00:00+00	40	0	13	0	24.1	91	0.35	0	2026-11-13 03:05:00.001269+00
1769	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 20:00:00+00	41	0	8	0	23.7	92	0.58	0	2026-11-13 03:05:00.001269+00
1770	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 21:00:00+00	42	0	4	0	23.5	92	0.51	0	2026-11-13 03:05:00.001269+00
1771	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 22:00:00+00	43	0	3	0	23.6	90	0.42	0	2026-11-13 03:05:00.001269+00
1772	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-14 23:00:00+00	44	0	2	0.01	24.2	90	0.65	16	2026-11-13 03:05:00.001269+00
1773	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-15 00:00:00+00	45	0	2	0.11	26.2	81	0.11	177	2026-11-13 03:05:00.001269+00
1774	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-15 01:00:00+00	46	0	0	0.28	27.7	75	0.98	408	2026-11-13 03:05:00.001269+00
1775	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-15 02:00:00+00	47	0	0	0.45	28.9	71	1.29	631	2026-11-13 03:05:00.001269+00
1776	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 03:00:00+00	2026-11-15 03:00:00+00	48	0	2	0.57	29.8	69	1.27	781	2026-11-13 03:05:00.001269+00
1777	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 06:00:00+00	1	1.9	25	0.54	31	61	2.24	700	2026-11-13 05:05:00.000693+00
1778	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 07:00:00+00	2	0.9	49	0.51	29.9	68	1.44	683	2026-11-13 05:05:00.000693+00
1779	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 08:00:00+00	3	0.9	79	0.4	29.2	72	1.77	534	2026-11-13 05:05:00.000693+00
1780	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 09:00:00+00	4	0.1	98	0.23	28.2	75	1.66	305	2026-11-13 05:05:00.000693+00
1781	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 10:00:00+00	5	0	97	0.09	27.2	79	0.74	107	2026-11-13 05:05:00.000693+00
1782	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 11:00:00+00	6	0.1	84	0.03	26	87	1.19	20	2026-11-13 05:05:00.000693+00
1783	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 12:00:00+00	7	0	71	0	25.5	92	0.14	0	2026-11-13 05:05:00.000693+00
1784	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 13:00:00+00	8	0	61	0	25.6	91	0.6	0	2026-11-13 05:05:00.000693+00
1785	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 14:00:00+00	9	0	51	0	25.5	91	0.1	0	2026-11-13 05:05:00.000693+00
1786	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 15:00:00+00	10	0	41	0	25.2	92	0.18	0	2026-11-13 05:05:00.000693+00
1787	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 16:00:00+00	11	0	31	0	24.9	91	0.34	0	2026-11-13 05:05:00.000693+00
1788	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 17:00:00+00	12	0	21	0	24.8	89	0.43	0	2026-11-13 05:05:00.000693+00
1789	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 18:00:00+00	13	0	14	0	24.5	89	0.42	0	2026-11-13 05:05:00.000693+00
1790	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 19:00:00+00	14	0	12	0	24.2	90	0.3	0	2026-11-13 05:05:00.000693+00
1791	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 20:00:00+00	15	0	14	0	23.9	89	0.6	0	2026-11-13 05:05:00.000693+00
1792	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 21:00:00+00	16	0	16	0	23.7	88	0.8	0	2026-11-13 05:05:00.000693+00
1793	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 22:00:00+00	17	0	18	0	23.6	87	0.81	0	2026-11-13 05:05:00.000693+00
1794	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-13 23:00:00+00	18	0	21	0	24.3	84	0.25	16	2026-11-13 05:05:00.000693+00
1795	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 00:00:00+00	19	0	22	0.1	26.1	77	0.11	161	2026-11-13 05:05:00.000693+00
1796	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 01:00:00+00	20	0	21	0.28	27.2	76	1.19	397	2026-11-13 05:05:00.000693+00
1797	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 02:00:00+00	21	0	18	0.41	28.5	73	1.52	563	2026-11-13 05:05:00.000693+00
1798	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 03:00:00+00	22	0.1	18	0.51	28.5	77	1.36	709	2026-11-13 05:05:00.000693+00
1799	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 04:00:00+00	23	0.1	21	0.58	29.3	75	1.14	782	2026-11-13 05:05:00.000693+00
1800	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 05:00:00+00	24	0.1	27	0.6	30.2	71	0.8	790	2026-11-13 05:05:00.000693+00
1801	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 06:00:00+00	25	0	37	0.6	30.4	69	0.92	800	2026-11-13 05:05:00.000693+00
1802	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 07:00:00+00	26	0.2	58	0.45	30.9	67	1.32	581	2026-11-13 05:05:00.000693+00
1803	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 08:00:00+00	27	0.9	83	0.35	28	77	2.01	483	2026-11-13 05:05:00.000693+00
1804	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 09:00:00+00	28	1.4	98	0.19	26.7	86	0.86	256	2026-11-13 05:05:00.000693+00
1805	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 10:00:00+00	29	1.1	95	0.07	25.6	93	0.47	100	2026-11-13 05:05:00.000693+00
1806	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 11:00:00+00	30	0.2	81	0.02	25.4	95	0.16	24	2026-11-13 05:05:00.000693+00
1807	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 12:00:00+00	31	0	65	0	25.2	98	0.16	0	2026-11-13 05:05:00.000693+00
1808	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 13:00:00+00	32	0	48	0	25	98	0.22	0	2026-11-13 05:05:00.000693+00
1809	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 14:00:00+00	33	0	29	0	24.9	97	0.71	0	2026-11-13 05:05:00.000693+00
1810	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 15:00:00+00	34	0	16	0	24.7	96	0.73	0	2026-11-13 05:05:00.000693+00
1811	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 16:00:00+00	35	0	13	0	24.5	93	0.81	0	2026-11-13 05:05:00.000693+00
1812	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 17:00:00+00	36	0	15	0	24.3	92	0.68	0	2026-11-13 05:05:00.000693+00
1813	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 18:00:00+00	37	0	16	0	24.2	91	0.35	0	2026-11-13 05:05:00.000693+00
1814	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 19:00:00+00	38	0	13	0	24.1	91	0.35	0	2026-11-13 05:05:00.000693+00
1815	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 20:00:00+00	39	0	8	0	23.7	92	0.58	0	2026-11-13 05:05:00.000693+00
1816	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 21:00:00+00	40	0	4	0	23.5	92	0.51	0	2026-11-13 05:05:00.000693+00
1817	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 22:00:00+00	41	0	3	0	23.6	90	0.42	0	2026-11-13 05:05:00.000693+00
1818	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-14 23:00:00+00	42	0	2	0.01	24.2	90	0.65	16	2026-11-13 05:05:00.000693+00
1819	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-15 00:00:00+00	43	0	2	0.11	26.2	81	0.11	177	2026-11-13 05:05:00.000693+00
1820	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-15 01:00:00+00	44	0	0	0.28	27.7	75	0.98	408	2026-11-13 05:05:00.000693+00
1821	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-15 02:00:00+00	45	0	0	0.45	28.9	71	1.29	631	2026-11-13 05:05:00.000693+00
1822	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-15 03:00:00+00	46	0	2	0.57	29.8	69	1.27	781	2026-11-13 05:05:00.000693+00
1823	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-15 04:00:00+00	47	0	19	0.63	30.2	70	1.61	847	2026-11-13 05:05:00.000693+00
1824	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 05:00:00+00	2026-11-15 05:00:00+00	48	0.1	42	0.62	31	66	0.92	811	2026-11-13 05:05:00.000693+00
1825	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 07:00:00+00	1	0.9	49	0.51	29.9	68	1.44	683	2026-11-13 06:04:59.999279+00
1826	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 08:00:00+00	2	0.9	79	0.4	29.2	72	1.77	534	2026-11-13 06:04:59.999279+00
1827	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 09:00:00+00	3	0.1	98	0.23	28.2	75	1.66	305	2026-11-13 06:04:59.999279+00
1828	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 10:00:00+00	4	0	97	0.09	27.2	79	0.74	107	2026-11-13 06:04:59.999279+00
1829	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 11:00:00+00	5	0.1	84	0.03	26	87	1.19	20	2026-11-13 06:04:59.999279+00
1830	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 12:00:00+00	6	0	71	0	25.5	92	0.14	0	2026-11-13 06:04:59.999279+00
1831	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 13:00:00+00	7	0	61	0	25.6	91	0.6	0	2026-11-13 06:04:59.999279+00
1832	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 14:00:00+00	8	0	51	0	25.5	91	0.1	0	2026-11-13 06:04:59.999279+00
1833	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 15:00:00+00	9	0	41	0	25.2	92	0.18	0	2026-11-13 06:04:59.999279+00
1834	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 16:00:00+00	10	0	31	0	24.9	91	0.34	0	2026-11-13 06:04:59.999279+00
1835	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 17:00:00+00	11	0	21	0	24.8	89	0.43	0	2026-11-13 06:04:59.999279+00
1836	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 18:00:00+00	12	0	14	0	24.5	89	0.42	0	2026-11-13 06:04:59.999279+00
1837	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 19:00:00+00	13	0	12	0	24.2	90	0.3	0	2026-11-13 06:04:59.999279+00
1838	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 20:00:00+00	14	0	14	0	23.9	89	0.6	0	2026-11-13 06:04:59.999279+00
1839	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 21:00:00+00	15	0	16	0	23.7	88	0.8	0	2026-11-13 06:04:59.999279+00
1840	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 22:00:00+00	16	0	18	0	23.6	87	0.81	0	2026-11-13 06:04:59.999279+00
1841	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-13 23:00:00+00	17	0	21	0	24.3	84	0.25	16	2026-11-13 06:04:59.999279+00
1842	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 00:00:00+00	18	0	22	0.1	26.1	77	0.11	161	2026-11-13 06:04:59.999279+00
1843	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 01:00:00+00	19	0	21	0.28	27.2	76	1.19	397	2026-11-13 06:04:59.999279+00
1844	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 02:00:00+00	20	0	18	0.41	28.5	73	1.52	563	2026-11-13 06:04:59.999279+00
1845	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 03:00:00+00	21	0.1	18	0.51	28.5	77	1.36	709	2026-11-13 06:04:59.999279+00
1846	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 04:00:00+00	22	0.1	21	0.58	29.3	75	1.14	782	2026-11-13 06:04:59.999279+00
1847	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 05:00:00+00	23	0.1	27	0.6	30.2	71	0.8	790	2026-11-13 06:04:59.999279+00
1848	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 06:00:00+00	24	0	37	0.6	30.4	69	0.92	800	2026-11-13 06:04:59.999279+00
1849	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 07:00:00+00	25	0.2	58	0.45	30.9	67	1.32	581	2026-11-13 06:04:59.999279+00
1850	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 08:00:00+00	26	0.9	83	0.35	28	77	2.01	483	2026-11-13 06:04:59.999279+00
1851	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 09:00:00+00	27	1.4	98	0.19	26.7	86	0.86	256	2026-11-13 06:04:59.999279+00
1852	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 10:00:00+00	28	1.1	95	0.07	25.6	93	0.47	100	2026-11-13 06:04:59.999279+00
1853	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 11:00:00+00	29	0.2	81	0.02	25.4	95	0.16	24	2026-11-13 06:04:59.999279+00
1854	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 12:00:00+00	30	0	65	0	25.2	98	0.16	0	2026-11-13 06:04:59.999279+00
1855	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 13:00:00+00	31	0	48	0	25	98	0.22	0	2026-11-13 06:04:59.999279+00
1856	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 14:00:00+00	32	0	29	0	24.9	97	0.71	0	2026-11-13 06:04:59.999279+00
1857	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 15:00:00+00	33	0	16	0	24.7	96	0.73	0	2026-11-13 06:04:59.999279+00
1858	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 16:00:00+00	34	0	13	0	24.5	93	0.81	0	2026-11-13 06:04:59.999279+00
1859	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 17:00:00+00	35	0	15	0	24.3	92	0.68	0	2026-11-13 06:04:59.999279+00
1860	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 18:00:00+00	36	0	16	0	24.2	91	0.35	0	2026-11-13 06:04:59.999279+00
1861	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 19:00:00+00	37	0	13	0	24.1	91	0.35	0	2026-11-13 06:04:59.999279+00
1862	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 20:00:00+00	38	0	8	0	23.7	92	0.58	0	2026-11-13 06:04:59.999279+00
1863	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 21:00:00+00	39	0	4	0	23.5	92	0.51	0	2026-11-13 06:04:59.999279+00
1864	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 22:00:00+00	40	0	3	0	23.6	90	0.42	0	2026-11-13 06:04:59.999279+00
1865	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-14 23:00:00+00	41	0	2	0.01	24.2	90	0.65	16	2026-11-13 06:04:59.999279+00
1866	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-15 00:00:00+00	42	0	2	0.11	26.2	81	0.11	177	2026-11-13 06:04:59.999279+00
1867	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-15 01:00:00+00	43	0	0	0.28	27.7	75	0.98	408	2026-11-13 06:04:59.999279+00
1868	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-15 02:00:00+00	44	0	0	0.45	28.9	71	1.29	631	2026-11-13 06:04:59.999279+00
1869	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-15 03:00:00+00	45	0	2	0.57	29.8	69	1.27	781	2026-11-13 06:04:59.999279+00
1870	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-15 04:00:00+00	46	0	19	0.63	30.2	70	1.61	847	2026-11-13 06:04:59.999279+00
1871	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-15 05:00:00+00	47	0.1	42	0.62	31	66	0.92	811	2026-11-13 06:04:59.999279+00
1872	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 06:00:00+00	2026-11-15 06:00:00+00	48	0.1	63	0.63	31.7	62	1.32	815	2026-11-13 06:04:59.999279+00
1873	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 08:00:00+00	1	2.7	79	0.46	29.6	71	2.17	626	2026-11-13 07:04:59.998891+00
1874	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 09:00:00+00	2	0.2	98	0.24	28.9	72	1.47	313	2026-11-13 07:04:59.998891+00
1875	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 10:00:00+00	3	0.1	97	0.11	28	76	1.77	127	2026-11-13 07:04:59.998891+00
1876	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 11:00:00+00	4	0.1	84	0.02	27.1	84	0.42	28	2026-11-13 07:04:59.998891+00
1877	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 12:00:00+00	5	0.1	71	0	26.3	90	0.99	0	2026-11-13 07:04:59.998891+00
1878	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 13:00:00+00	6	0.3	61	0	26.1	90	0.75	0	2026-11-13 07:04:59.998891+00
1879	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 14:00:00+00	7	0	51	0	25.8	93	0.67	0	2026-11-13 07:04:59.998891+00
1880	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 15:00:00+00	8	0.2	41	0	25.7	94	0.16	0	2026-11-13 07:04:59.998891+00
1881	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 16:00:00+00	9	0.5	31	0	25.3	95	0.5	0	2026-11-13 07:04:59.998891+00
1882	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 17:00:00+00	10	0.1	21	0	25	94	0.72	0	2026-11-13 07:04:59.998891+00
1883	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 18:00:00+00	11	0.2	14	0	24.6	94	0.75	0	2026-11-13 07:04:59.998891+00
1884	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 19:00:00+00	12	0.6	12	0	24.3	95	0.39	0	2026-11-13 07:04:59.998891+00
1885	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 20:00:00+00	13	0.8	14	0	24	94	0.72	0	2026-11-13 07:04:59.998891+00
1886	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 21:00:00+00	14	0.3	16	0	24.1	94	0.22	0	2026-11-13 07:04:59.998891+00
1887	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 22:00:00+00	15	0	18	0	23.8	94	0.1	0	2026-11-13 07:04:59.998891+00
1888	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-13 23:00:00+00	16	0	21	0	24.1	92	0.21	15	2026-11-13 07:04:59.998891+00
1889	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 00:00:00+00	17	0	22	0.1	24.8	91	0.83	153	2026-11-13 07:04:59.998891+00
1890	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 01:00:00+00	18	0	21	0.26	26.8	81	0.74	383	2026-11-13 07:04:59.998891+00
1891	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 02:00:00+00	19	0	18	0.44	28.6	74	1.5	618	2026-11-13 07:04:59.998891+00
1892	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 03:00:00+00	20	0	18	0.57	29.3	73	2.31	804	2026-11-13 07:04:59.998891+00
1893	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 04:00:00+00	21	0.1	21	0.59	29.7	71	0.85	792	2026-11-13 07:04:59.998891+00
1894	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 05:00:00+00	22	0	27	0.62	31.4	63	1.35	804	2026-11-13 07:04:59.998891+00
1895	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 06:00:00+00	23	0.1	37	0.62	30.9	65	1.28	826	2026-11-13 07:04:59.998891+00
1896	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 07:00:00+00	24	0.9	58	0.41	28.6	76	1.35	548	2026-11-13 07:04:59.998891+00
1897	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 08:00:00+00	25	3	83	0.28	25.9	90	2.82	426	2026-11-13 07:04:59.998891+00
1898	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 09:00:00+00	26	1.7	98	0.16	25.9	89	1.48	231	2026-11-13 07:04:59.998891+00
1899	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 10:00:00+00	27	0.4	95	0.1	26.1	91	1.06	135	2026-11-13 07:04:59.998891+00
1900	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 11:00:00+00	28	0	81	0.02	25.3	95	0.14	32	2026-11-13 07:04:59.998891+00
1901	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 12:00:00+00	29	0	65	0	25.2	97	0.47	0	2026-11-13 07:04:59.998891+00
1902	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 13:00:00+00	30	0	48	0	25.1	96	0.67	0	2026-11-13 07:04:59.998891+00
1903	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 14:00:00+00	31	0	29	0	25	95	0.6	0	2026-11-13 07:04:59.998891+00
1904	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 15:00:00+00	32	0	16	0	24.9	93	0.32	0	2026-11-13 07:04:59.998891+00
1905	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 16:00:00+00	33	0	13	0	24.7	91	0.18	0	2026-11-13 07:04:59.998891+00
1906	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 17:00:00+00	34	0	15	0	24.2	92	0.51	0	2026-11-13 07:04:59.998891+00
1907	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 18:00:00+00	35	0	16	0	23.9	90	0.56	0	2026-11-13 07:04:59.998891+00
1908	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 19:00:00+00	36	0	13	0	23.6	90	0.56	0	2026-11-13 07:04:59.998891+00
1909	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 20:00:00+00	37	0	8	0	23.5	89	0.49	0	2026-11-13 07:04:59.998891+00
1910	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 21:00:00+00	38	0	4	0	23.4	88	0.43	0	2026-11-13 07:04:59.998891+00
1911	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 22:00:00+00	39	0	3	0	23.5	87	0.39	0	2026-11-13 07:04:59.998891+00
1912	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-14 23:00:00+00	40	0	2	0.01	24.2	86	0.81	16	2026-11-13 07:04:59.998891+00
1913	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-15 00:00:00+00	41	0	2	0.11	26.4	78	0.32	175	2026-11-13 07:04:59.998891+00
1914	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-15 01:00:00+00	42	0	0	0.29	27.7	74	0.74	411	2026-11-13 07:04:59.998891+00
1915	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-15 02:00:00+00	43	0	0	0.46	29	70	1.51	639	2026-11-13 07:04:59.998891+00
1916	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-15 03:00:00+00	44	0	2	0.59	29.4	70	1.45	810	2026-11-13 07:04:59.998891+00
1917	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-15 04:00:00+00	45	0.1	19	0.61	30.2	68	1.22	815	2026-11-13 07:04:59.998891+00
1918	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-15 05:00:00+00	46	0.1	42	0.67	30.8	66	1.09	892	2026-11-13 07:04:59.998891+00
1919	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-15 06:00:00+00	47	0.5	63	0.57	29.7	74	1.63	772	2026-11-13 07:04:59.998891+00
1920	00000000-0000-0000-0000-0000000000b1	open_meteo	best_match	2026-11-13 07:00:00+00	2026-11-15 07:00:00+00	48	2.3	79	0.33	28.3	82	1.01	444	2026-11-13 07:04:59.998891+00
\.


--
-- Data for Name: weather_forecasts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.weather_forecasts (id, plot_id, forecast_issued_at, valid_for_timestamp, forecast_rainfall_mm, forecast_temperature_c, forecast_humidity_pct, source, created_at, forecast_eto_mm) FROM stdin;
ef0cc11d-0f8a-43d1-9eff-2a9d5cb713d6	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 06:00:00+00	1	30.4	64	open_meteo	2026-11-11 15:01:17.343168+00	0.61
2faf6b35-21cd-4662-b9fa-0d96b9d53897	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 07:00:00+00	1.2	28.9	71	open_meteo	2026-11-11 15:01:17.343168+00	0.5
f49db5a9-d9f5-4b4a-a45e-5a93d8a03453	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 08:00:00+00	1	28.7	69	open_meteo	2026-11-11 15:01:17.343168+00	0.38
36508e91-de89-43e3-aef0-aefe9089f07f	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 09:00:00+00	0	28.3	70	open_meteo	2026-11-11 15:01:17.343168+00	0.23
abe1a615-1e52-4171-8197-731aec61d2db	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 10:00:00+00	0.1	27.4	74	open_meteo	2026-11-11 15:01:17.343168+00	0.13
f641ee65-44c5-4f1b-adc0-57ea695f561d	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 16:00:00+00	0	24.7	93	open_meteo	2026-11-11 15:01:17.343168+00	0
b143823b-31e2-4411-a6bc-467d0e3453a8	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 17:00:00+00	0	24.9	91	open_meteo	2026-11-11 15:01:17.343168+00	0
e2f511a8-9264-4f9b-8807-b5fa45e7a32f	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 18:00:00+00	0	24.9	87	open_meteo	2026-11-11 15:01:17.343168+00	0
136793da-3f5c-43ed-8d65-b04ffb3e5fe9	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 19:00:00+00	0	24.4	89	open_meteo	2026-11-11 15:01:17.343168+00	0
f955b9e8-dd42-4968-9a24-1494590ec543	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 20:00:00+00	0	24.3	87	open_meteo	2026-11-11 15:01:17.343168+00	0
53fec356-140e-4870-b5e9-727fe2e9cc2d	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 02:00:00+00	0	30.2	64	open_meteo	2026-11-11 15:01:17.343168+00	0.46
4a4bc8a2-8aeb-4c60-94e3-371c9c68809a	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 03:00:00+00	0	30.9	61	open_meteo	2026-11-11 15:01:17.343168+00	0.52
8bcacf73-6bf5-4b1e-a3c9-132eda5b1527	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 04:00:00+00	0	32.1	57	open_meteo	2026-11-11 15:01:17.343168+00	0.66
2282da75-f86e-40c2-9f8d-d6ba43f76f25	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 08:00:00+00	2.7	29.6	71	open_meteo	2026-11-11 15:01:17.343168+00	0.46
2f9825f8-1c61-4c0d-832d-5013402ca6f9	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 09:00:00+00	0.2	28.9	72	open_meteo	2026-11-11 15:01:17.343168+00	0.24
955b7847-b168-46ef-b001-f8a9cbbb1693	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 10:00:00+00	0.1	28	76	open_meteo	2026-11-11 15:01:17.343168+00	0.11
f2fd8118-96e8-444c-aade-63b0638bd966	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 11:00:00+00	0.1	27.1	84	open_meteo	2026-11-11 15:01:17.343168+00	0.02
b3485456-8bf9-471b-8534-55b4bef5a40f	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 16:00:00+00	0.5	25.3	95	open_meteo	2026-11-11 15:01:17.343168+00	0
d2d67715-dcf1-4de4-be20-eb0ef2849d3f	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 17:00:00+00	0.1	25	94	open_meteo	2026-11-11 15:01:17.343168+00	0
b1dcec27-a8d9-43f3-8df1-f6ce41c35ff8	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 18:00:00+00	0.2	24.6	94	open_meteo	2026-11-11 15:01:17.343168+00	0
cf2ed774-fcc8-4bbf-88ff-90763c1a77e5	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 22:00:00+00	0	23.8	94	open_meteo	2026-11-11 15:01:17.343168+00	0
2e8a8d82-4c98-4c98-b2f2-5e1bb0f64989	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 23:00:00+00	0	24.1	92	open_meteo	2026-11-11 15:01:17.343168+00	0
a5ee7b2c-2cf1-4612-b68e-7637b53ed7b3	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 00:00:00+00	0	24.8	91	open_meteo	2026-11-12 00:05:01.036133+00	0.1
bba37969-32e0-4fc0-b582-6576f0d722bf	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 04:00:00+00	0.1	29.7	71	open_meteo	2026-11-12 00:05:01.036133+00	0.59
d83a5c50-d411-45b1-8183-eafee60b20b2	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 05:00:00+00	0	31.4	63	open_meteo	2026-11-12 00:05:01.036133+00	0.62
d2a97d22-b721-4ccf-a59e-8e7b94103481	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 06:00:00+00	0.1	30.9	65	open_meteo	2026-11-12 00:05:01.036133+00	0.62
8d3403ab-b139-4098-9639-4bc692a3765d	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 10:00:00+00	0.4	26.1	91	open_meteo	2026-11-12 00:05:01.036133+00	0.1
9c5b63dc-2f20-4e1d-8994-081d4b1f0ea3	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 11:00:00+00	0	25.3	95	open_meteo	2026-11-12 00:05:01.036133+00	0.02
b809aa1e-bdeb-4b4e-b215-beeb9af9dec5	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 12:00:00+00	0	25.2	97	open_meteo	2026-11-12 00:05:01.036133+00	0
272e137c-a928-4e10-83d7-b3a5e7e1d320	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 16:00:00+00	0	24.7	91	open_meteo	2026-11-12 00:05:01.036133+00	0
a7918356-f5da-4aa2-98b2-9a99a1227a51	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 17:00:00+00	0	24.2	92	open_meteo	2026-11-12 00:05:01.036133+00	0
c92e012c-bfe6-4a6c-9586-55df0d46d149	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 18:00:00+00	0	23.9	90	open_meteo	2026-11-12 00:05:01.036133+00	0
e84da2e1-2aea-46ca-8cd3-7a7eef014ff4	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 19:00:00+00	0	23.6	90	open_meteo	2026-11-12 00:05:01.036133+00	0
b48bce65-12dc-4642-9dcc-49a165e1b1de	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 00:00:00+00	0	27.5	72	open_meteo	2026-11-11 15:01:17.343168+00	0.12
ce537ff4-3702-41a3-925a-4b04993c2771	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 01:00:00+00	0	28	71	open_meteo	2026-11-11 15:01:17.343168+00	0.29
7c23d40e-f6d0-47e2-9273-70283d110216	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 02:00:00+00	0.1	28.8	69	open_meteo	2026-11-11 15:01:17.343168+00	0.41
9b1be986-4104-4f34-9bc1-f6c3831a1c0f	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 03:00:00+00	1.7	26.8	81	open_meteo	2026-11-11 15:01:17.343168+00	0.43
78961b2e-5195-4053-bd55-89d7ae1566c9	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 04:00:00+00	1.6	28.7	76	open_meteo	2026-11-11 15:01:17.343168+00	0.52
f6670d29-abb9-4ce6-8f5c-cd47dc35cb1d	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 05:00:00+00	0.2	30.1	71	open_meteo	2026-11-11 15:01:17.343168+00	0.61
d07ad91a-534c-4c0d-b700-ddf5047f2c49	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 02:00:00+00	0	29.3	62	open_meteo	2026-11-11 15:01:17.343168+00	0.37
6f48d063-bd17-4c91-8450-dfd710b99478	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 03:00:00+00	0	30.4	59	open_meteo	2026-11-11 15:01:17.343168+00	0.51
ad37abaa-9298-4837-87c4-14a465f48639	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 04:00:00+00	0.1	31.7	54	open_meteo	2026-11-11 15:01:17.343168+00	0.68
a46ebe2a-0cc4-4953-815a-c42b7e82c431	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 05:00:00+00	0.1	32.5	49	open_meteo	2026-11-11 15:01:17.343168+00	0.73
c2a6f881-9895-4e1e-9a4f-a418b7c76249	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 06:00:00+00	0.2	33.9	43	open_meteo	2026-11-11 15:01:17.343168+00	0.76
2edb1edb-a689-467b-b3a3-a460dde95c9b	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 12:00:00+00	0.1	26.5	82	open_meteo	2026-11-11 15:01:17.343168+00	0
804a0a5d-6d9d-496e-a75e-0a555f6aebc4	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 13:00:00+00	0	26.2	87	open_meteo	2026-11-11 15:01:17.343168+00	0
8888e93a-dd52-44ef-8fad-c86c17854094	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 14:00:00+00	0	25.9	89	open_meteo	2026-11-11 15:01:17.343168+00	0
e77b762a-eb0d-4742-ad5d-ed2d01bdc677	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 15:00:00+00	0	25.5	89	open_meteo	2026-11-11 15:01:17.343168+00	0.01
fd8f4ecf-f59f-45a7-ae3b-a4278b217818	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 16:00:00+00	0	25.2	87	open_meteo	2026-11-11 15:01:17.343168+00	0.01
81a4f466-e0bc-4dfa-ba85-1c903a33d32c	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 00:00:00+00	0	27.7	68	open_meteo	2026-11-11 15:01:17.343168+00	0.11
e598ab0e-8f86-43d4-80d6-33505d609b3d	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 01:00:00+00	0	27.9	70	open_meteo	2026-11-11 15:01:17.343168+00	0.29
3e87b3eb-054e-47f6-a2e0-6d61d7699e0f	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 02:00:00+00	0	28.7	70	open_meteo	2026-11-11 15:01:17.343168+00	0.45
f2b8772e-b1ea-4888-a7c4-37c6c584eede	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 03:00:00+00	0	30	65	open_meteo	2026-11-11 15:01:17.343168+00	0.58
e0a61620-1697-440b-a32d-5cbbc7f96a3d	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 04:00:00+00	0.2	31	60	open_meteo	2026-11-11 15:01:17.343168+00	0.64
c656b14b-5b4e-4049-9ff2-883b06e86d5b	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 05:00:00+00	0.2	32.1	55	open_meteo	2026-11-11 15:01:17.343168+00	0.72
cba19b95-d5fe-4825-b916-c65f2fe87b96	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 06:00:00+00	0.2	32.9	52	open_meteo	2026-11-11 15:01:17.343168+00	0.66
e57f4458-de25-4767-a629-af75d1a4a85c	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 07:00:00+00	0.2	32.7	53	open_meteo	2026-11-11 15:01:17.343168+00	0.62
b6e5fb57-c802-4db7-8464-8ae85a1deabb	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 08:00:00+00	0.1	32.3	53	open_meteo	2026-11-11 15:01:17.343168+00	0.51
14a971d3-990c-4ab4-8c8b-6cdaad6cc4ba	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 09:00:00+00	0.1	31.5	56	open_meteo	2026-11-11 15:01:17.343168+00	0.35
5f8e7b3a-be19-4fbd-92d6-c8f5f1145891	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 10:00:00+00	0.5	29.8	66	open_meteo	2026-11-11 15:01:17.343168+00	0.16
f742a0db-4658-49f5-baf8-8258eb4fb00f	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 11:00:00+00	0.9	27.5	83	open_meteo	2026-11-11 15:01:17.343168+00	0.02
5241509a-7acc-49e1-8a59-525e3e8abc6d	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 12:00:00+00	0.2	27	79	open_meteo	2026-11-11 15:01:17.343168+00	0
ad5207b5-84e0-4582-82fa-30bb234eb46f	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 13:00:00+00	0	26.4	83	open_meteo	2026-11-11 15:01:17.343168+00	0
849bd554-9b39-4d68-b350-98229a0b21b4	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 14:00:00+00	0	25.9	86	open_meteo	2026-11-11 15:01:17.343168+00	0.01
a3f5dc85-8719-456c-a584-a73637c53865	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 15:00:00+00	0	25.5	86	open_meteo	2026-11-11 15:01:17.343168+00	0.01
3fae3c2b-6f87-4433-879f-cb2296f5d3ec	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 16:00:00+00	0	25.5	84	open_meteo	2026-11-11 15:01:17.343168+00	0.01
f2537996-f7d6-4128-aa6a-83322cbd53e2	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 17:00:00+00	0	25.2	84	open_meteo	2026-11-11 15:01:17.343168+00	0
e3006b7b-830f-44ca-a11b-5a7394a2ab93	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 18:00:00+00	0	25.1	81	open_meteo	2026-11-11 15:01:17.343168+00	0.01
4baef65d-42c4-46b1-ba12-036ab4d9fc0c	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 19:00:00+00	0	24.8	82	open_meteo	2026-11-11 15:01:17.343168+00	0.01
2f8a6fc7-efe6-44c4-b916-2ca18ab60983	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 20:00:00+00	0	24.8	81	open_meteo	2026-11-11 15:01:17.343168+00	0.01
b94e6647-1cd4-4855-bc2b-a7ec06f23e16	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 21:00:00+00	0	24.3	82	open_meteo	2026-11-11 15:01:17.343168+00	0.01
1edfc8e6-7f5c-44a6-9dcf-17b0b0514219	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 22:00:00+00	0	24.3	82	open_meteo	2026-11-11 15:01:17.343168+00	0.01
09c9bfd4-1996-4250-ae5f-f410baa46006	00000000-0000-0000-0000-0000000000b1	2026-11-11 23:04:59.99915+00	2026-11-09 23:00:00+00	0	25	78	open_meteo	2026-11-11 15:01:17.343168+00	0.01
d3becea4-b69d-4b60-8476-8afc661037a0	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 17:00:00+00	0	24.9	85	open_meteo	2026-11-11 15:01:17.343168+00	0.01
fd823457-7552-4876-a3de-987f5f6187b6	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 18:00:00+00	0	24.6	85	open_meteo	2026-11-11 15:01:17.343168+00	0.01
c14d0341-430c-41ee-8b1a-8f102e096d1c	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 19:00:00+00	0	24.2	86	open_meteo	2026-11-11 15:01:17.343168+00	0
1e4023f0-8d6d-42b9-921e-811e49259ad5	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 20:00:00+00	0	23.9	86	open_meteo	2026-11-11 15:01:17.343168+00	0
89c1cda5-f1e3-4bb2-b523-5c17f418a330	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 00:00:00+00	0	27	75	open_meteo	2026-11-11 15:01:17.343168+00	0.12
53bd82f7-474e-4b9b-97ab-b1133d173fe0	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 01:00:00+00	0	28.5	66	open_meteo	2026-11-11 15:01:17.343168+00	0.27
5d23b58b-808c-4af7-9f3f-b48287d8fd86	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 07:00:00+00	0.1	34	42	open_meteo	2026-11-11 15:01:17.343168+00	0.69
55790191-a789-4372-84ec-c3dbbf6757a6	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 08:00:00+00	0	33.4	43	open_meteo	2026-11-11 15:01:17.343168+00	0.59
251c7519-5797-4f01-a35e-c19d5ee03e67	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 09:00:00+00	0.5	29.3	63	open_meteo	2026-11-11 15:01:17.343168+00	0.36
4ae53e63-e7b7-4142-be23-3732b957fbd3	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 10:00:00+00	0.7	27.6	76	open_meteo	2026-11-11 15:01:17.343168+00	0.14
46506704-9bd1-4bdb-876d-1e88552f372c	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 11:00:00+00	0.5	26.8	81	open_meteo	2026-11-11 15:01:17.343168+00	0.03
3557dfbb-6a74-440a-9ac9-51d3ab32de90	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 12:00:00+00	0.1	26.3	90	open_meteo	2026-11-11 15:01:17.343168+00	0
3f646239-615a-4fc8-ac51-c3779db760c2	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 13:00:00+00	0.3	26.1	90	open_meteo	2026-11-11 15:01:17.343168+00	0
9bfd6159-ff86-4b01-a0e6-33992c9a9376	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 14:00:00+00	0	25.8	93	open_meteo	2026-11-11 15:01:17.343168+00	0
7b50f7c9-8fdc-4193-b363-7be1cb382f71	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 15:00:00+00	0.2	25.7	94	open_meteo	2026-11-11 15:01:17.343168+00	0
7fdeddc2-3269-47e1-b575-279cdc717f64	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 19:00:00+00	0.6	24.3	95	open_meteo	2026-11-11 15:01:17.343168+00	0
6df25654-ea6a-4a62-904e-dfd8c523a38a	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 20:00:00+00	0.8	24	94	open_meteo	2026-11-11 15:01:17.343168+00	0
12b195ae-0342-4fd9-8881-de0e1b2a492d	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 21:00:00+00	0.3	24.1	94	open_meteo	2026-11-11 15:01:17.343168+00	0
e57b7db0-5569-4dcd-88dd-e03b2d2a1f7b	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 01:00:00+00	0	26.8	81	open_meteo	2026-11-12 00:05:01.036133+00	0.26
b550799c-b22d-492a-b0ce-c5d49814a232	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 02:00:00+00	0	28.6	74	open_meteo	2026-11-12 00:05:01.036133+00	0.44
d8bbe5f9-57f9-4a81-88fd-a43a4eea1ff3	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 03:00:00+00	0	29.3	73	open_meteo	2026-11-12 00:05:01.036133+00	0.57
06d70f57-09a7-47ba-916d-47a4d56971f7	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 07:00:00+00	0.9	28.6	76	open_meteo	2026-11-12 00:05:01.036133+00	0.41
1fa8dfa9-a49b-4e24-8c9a-90d293bae0ae	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 08:00:00+00	3	25.9	90	open_meteo	2026-11-12 00:05:01.036133+00	0.28
70af76f9-19fd-497b-a601-c2f1e6966efa	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 09:00:00+00	1.7	25.9	89	open_meteo	2026-11-12 00:05:01.036133+00	0.16
215d2bd0-8e66-4e60-a97b-3de6de5b301c	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 13:00:00+00	0	25.1	96	open_meteo	2026-11-12 00:05:01.036133+00	0
51532eec-ec73-4965-b9f1-eabab8abde27	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 14:00:00+00	0	25	95	open_meteo	2026-11-12 00:05:01.036133+00	0
371e8962-34f6-4d20-9980-971934f50c7f	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 15:00:00+00	0	24.9	93	open_meteo	2026-11-12 00:05:01.036133+00	0
611574b1-5d77-4a46-bb4d-052fc736e4b8	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 00:00:00+00	0	26.4	78	open_meteo	2026-11-13 00:05:00.728228+00	0.11
d47a391d-d983-4bfd-a704-ddf03192ddc7	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 01:00:00+00	0	27.7	74	open_meteo	2026-11-13 00:05:00.728228+00	0.29
e6046b3d-6f36-498f-b78e-00f19677944f	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 02:00:00+00	0	29	70	open_meteo	2026-11-13 00:05:00.728228+00	0.46
f750ee32-02c4-4fa0-aeb4-ba8fc71d8c67	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 11:00:00+00	0	26.7	80	open_meteo	2026-11-11 15:01:17.343168+00	0.02
8d6c6175-ff7c-471f-aee4-a4e55bbde155	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 12:00:00+00	0.3	25.6	89	open_meteo	2026-11-11 15:01:17.343168+00	0
6aaca024-90b7-4b9e-893c-5d19f9f5a227	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 13:00:00+00	0.7	25.4	91	open_meteo	2026-11-11 15:01:17.343168+00	0
9b47d9d6-587c-498c-a0ad-355d55390bcb	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 14:00:00+00	0.1	25.2	93	open_meteo	2026-11-11 15:01:17.343168+00	0
28c63b43-ee93-4c5b-bac4-cd9b44e92516	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 15:00:00+00	0	24.9	93	open_meteo	2026-11-11 15:01:17.343168+00	0
7b9a47ef-f29e-43e8-9220-75d1a0377239	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 21:00:00+00	0	24.3	84	open_meteo	2026-11-11 15:01:17.343168+00	0
772b0b0c-8697-49ec-af73-6bef18088b73	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 22:00:00+00	0	24.1	84	open_meteo	2026-11-11 15:01:17.343168+00	0
3d113bfa-3b98-451d-9e94-d586c7f91f0e	00000000-0000-0000-0000-0000000000b1	2026-11-12 23:04:59.999358+00	2026-11-10 23:00:00+00	0	24.8	83	open_meteo	2026-11-11 15:01:17.343168+00	0.01
60e88f11-4378-4d7e-8582-fa67af4d6507	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 21:00:00+00	0	23.7	86	open_meteo	2026-11-11 15:01:17.343168+00	0
f8ceb789-ba38-4fb6-a311-df12d5110c12	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 22:00:00+00	0	23.6	85	open_meteo	2026-11-11 15:01:17.343168+00	0
5fb9cab2-6af0-4a72-ba0f-65d7755b036b	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-11 23:00:00+00	0	24.3	83	open_meteo	2026-11-11 15:01:17.343168+00	0.01
67f8ceff-8a39-4370-a99e-9a704b806a76	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 00:00:00+00	0	27.3	73	open_meteo	2026-11-11 15:01:17.343168+00	0.12
3c3c0676-075c-4ab1-8129-5a549009c6ae	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 01:00:00+00	0	28.7	69	open_meteo	2026-11-11 15:01:17.343168+00	0.3
1ec66fdf-950f-451b-8742-42b93a442c8b	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 02:00:00+00	0	29.8	66	open_meteo	2026-11-11 15:01:17.343168+00	0.44
76497753-0413-43ea-a914-a718f45a1cbc	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 03:00:00+00	0	31.2	61	open_meteo	2026-11-11 15:01:17.343168+00	0.6
3d021d34-8780-4cec-96d6-21e35ecfccdb	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 04:00:00+00	0.1	32.4	54	open_meteo	2026-11-11 15:01:17.343168+00	0.68
ed963850-d5a0-44d0-bdb0-76d99e222d6f	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 05:00:00+00	0.1	33.2	49	open_meteo	2026-11-11 15:01:17.343168+00	0.71
0d3f3cc4-8a09-42cd-bcf5-27a78880cec4	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 06:00:00+00	0.5	34	48	open_meteo	2026-11-11 15:01:17.343168+00	0.73
5e6a0102-9d77-4715-85bb-b782d7d257db	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 07:00:00+00	0.1	33.9	46	open_meteo	2026-11-11 15:01:17.343168+00	0.61
4bb466af-5712-4c8f-9d1a-96feab9a4e17	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 08:00:00+00	1.5	30.3	67	open_meteo	2026-11-11 15:01:17.343168+00	0.42
bf60ac69-95dc-4b73-8fc1-16fb7e5b3c92	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 09:00:00+00	1.1	27.7	77	open_meteo	2026-11-11 15:01:17.343168+00	0.25
1263bd77-4de5-44b1-b9b0-78e413fbf62d	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 10:00:00+00	1	26.7	87	open_meteo	2026-11-11 15:01:17.343168+00	0.12
79a48840-02b9-4cdf-a4be-e648b5b30ece	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 11:00:00+00	0.3	25.6	90	open_meteo	2026-11-11 15:01:17.343168+00	0.02
26bd868e-aa08-4637-942e-ec95ae9874dd	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 12:00:00+00	0.1	24.5	93	open_meteo	2026-11-11 15:01:17.343168+00	0
c522a78e-356b-41a6-97e4-e5f5d810d60f	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 13:00:00+00	0.1	25.2	93	open_meteo	2026-11-11 15:01:17.343168+00	0
4097b50e-be75-4045-8789-57c27197f2d4	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 14:00:00+00	0	25.3	93	open_meteo	2026-11-11 15:01:17.343168+00	0
7990945c-3c75-4ccb-9af0-a1b1a2032ce5	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 15:00:00+00	0	25.8	89	open_meteo	2026-11-11 15:01:17.343168+00	0
b953fc0c-6019-4a75-90f6-a1b5b4a6cbb9	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 16:00:00+00	0	26	84	open_meteo	2026-11-11 15:01:17.343168+00	0
ec056d99-3cf2-4133-9ff7-ab4e7459fa47	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 17:00:00+00	0	25.9	82	open_meteo	2026-11-11 15:01:17.343168+00	0
1b5a0039-9a0f-4cf0-96ff-da638ce9871d	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 18:00:00+00	0	25	87	open_meteo	2026-11-11 15:01:17.343168+00	0
2456e872-76f2-4f55-a66c-f755ac288999	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 19:00:00+00	0	24.5	90	open_meteo	2026-11-11 15:01:17.343168+00	0
b4430989-56a9-4ae9-9fce-95611d35f572	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 20:00:00+00	0	24.2	90	open_meteo	2026-11-11 15:01:17.343168+00	0
28ad044f-0b8f-4d5f-88c4-5bbe88197fe6	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 21:00:00+00	0	24.2	87	open_meteo	2026-11-11 15:01:17.343168+00	0
a0c95f8f-59b5-4a2a-a7fa-80770a54ea0b	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 22:00:00+00	0	24.2	85	open_meteo	2026-11-11 15:01:17.343168+00	0
4c5f2841-8e14-4d03-a59c-65ac47d3f8ed	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-12 23:00:00+00	0	24.9	84	open_meteo	2026-11-11 15:01:17.343168+00	0.01
d7787565-ac0e-47d5-be97-dfaf4d4b1ad1	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 00:00:00+00	0	27.2	78	open_meteo	2026-11-11 15:01:17.343168+00	0.1
51d8da58-040d-4ade-b017-223241776141	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 01:00:00+00	0	29	68	open_meteo	2026-11-11 15:01:17.343168+00	0.27
769cd81a-a4d6-4e63-9a5b-388dc7db45b5	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 05:00:00+00	0	32.7	55	open_meteo	2026-11-11 15:01:17.343168+00	0.73
afc24f0f-0d7d-4b93-8718-30a5480ca0a7	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 06:00:00+00	0	32.9	56	open_meteo	2026-11-11 15:01:17.343168+00	0.65
38779925-dd1e-4f23-bce6-4b3cc0e32420	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-13 07:00:00+00	0	33.5	53	open_meteo	2026-11-11 15:01:17.343168+00	0.65
818c80ce-56b4-4b5a-bbf0-833eb610e00a	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 20:00:00+00	0	23.5	89	open_meteo	2026-11-12 00:05:01.036133+00	0
3bf054ca-96ec-4c74-95ec-7869cbabfa1e	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 21:00:00+00	0	23.4	88	open_meteo	2026-11-12 00:05:01.036133+00	0
816910f6-2a85-4d01-9c98-7dc839cf8991	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 22:00:00+00	0	23.5	87	open_meteo	2026-11-12 00:05:01.036133+00	0
6bb86eac-fc29-439c-ba05-40bcde0432d9	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-14 23:00:00+00	0	24.2	86	open_meteo	2026-11-12 00:05:01.036133+00	0.01
dc679381-fb22-4aa1-91e0-f6bf1ce0d461	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 03:00:00+00	0	29.4	70	open_meteo	2026-11-13 00:05:00.728228+00	0.59
b38da07a-cbc2-45b5-846b-02a9b05e11b1	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 04:00:00+00	0.1	30.2	68	open_meteo	2026-11-13 00:05:00.728228+00	0.61
540d0700-2f23-491e-82f1-01a59350ae15	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 05:00:00+00	0.1	30.8	66	open_meteo	2026-11-13 00:05:00.728228+00	0.67
f154c8eb-ffa2-4846-ab77-2c4628061f42	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 06:00:00+00	0.5	29.7	74	open_meteo	2026-11-13 00:05:00.728228+00	0.57
d9abe9ab-3953-4b31-9e7e-48427bcd3728	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 07:00:00+00	2.3	28.3	82	open_meteo	2026-11-13 00:05:00.728228+00	0.33
d1a36c56-6e9c-466b-82fc-1d8362c70570	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 08:00:00+00	6	25.8	88	open_meteo	2026-11-13 00:05:00.728228+00	0.24
f0104693-5737-4174-8517-5c8a184da9bf	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 09:00:00+00	0.7	25.8	89	open_meteo	2026-11-13 00:05:00.728228+00	0.18
560fd87d-8ec0-4f08-af34-5a777f2ae54d	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 10:00:00+00	0.8	24.7	97	open_meteo	2026-11-13 00:05:00.728228+00	0.09
81a508a0-770f-4301-8a47-301c88b8518b	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 11:00:00+00	0.1	24.3	98	open_meteo	2026-11-13 00:05:00.728228+00	0.01
e9edc8c2-7f8e-4e98-8c35-e4410e10c87f	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 12:00:00+00	0.1	24.1	99	open_meteo	2026-11-13 00:05:00.728228+00	0
1e6c4b89-6325-49b4-836f-626b80fe6ef9	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 13:00:00+00	0.2	23.8	100	open_meteo	2026-11-13 00:05:00.728228+00	0
719186c1-c3fb-4b1e-96cf-e8765e000988	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 14:00:00+00	0.2	24	97	open_meteo	2026-11-13 00:05:00.728228+00	0
66a5ad53-5a3c-4be8-9866-bbdc65256b4a	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 15:00:00+00	0	23.9	98	open_meteo	2026-11-13 00:05:00.728228+00	0
8b65fa28-f9df-4774-9a5b-940b4aec9359	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 16:00:00+00	0	23.9	97	open_meteo	2026-11-13 00:05:00.728228+00	0
4970abc4-673a-452f-98ab-e6f88b97624d	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 17:00:00+00	0.1	23.6	98	open_meteo	2026-11-13 00:05:00.728228+00	0
bd1ff8d3-62a6-4316-a3c2-533233c5ada3	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 18:00:00+00	0	23.3	99	open_meteo	2026-11-13 00:05:00.728228+00	0
1929b015-859c-43ef-8007-c104b50f94df	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 19:00:00+00	0	23.2	98	open_meteo	2026-11-13 00:05:00.728228+00	0
5d2064c3-1811-46d3-819f-112b0d5d3ab1	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 20:00:00+00	0	23.4	96	open_meteo	2026-11-13 00:05:00.728228+00	0
5571ff46-09d4-47ff-b844-a599799e7872	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 21:00:00+00	0	23.3	94	open_meteo	2026-11-13 00:05:00.728228+00	0
8bebe174-5ecb-4c1f-a321-ac02c27b6076	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 22:00:00+00	0	23.3	93	open_meteo	2026-11-13 00:05:00.728228+00	0
7d4ab8a7-836e-4827-a87a-58f3fd923bef	00000000-0000-0000-0000-0000000000b1	2026-11-13 07:04:59.998891+00	2026-11-15 23:00:00+00	0	23.8	90	open_meteo	2026-11-13 00:05:00.728228+00	0
\.


--
-- Data for Name: weather_observed_hourly; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.weather_observed_hourly (id, plot_id, source, "time", precipitation_mm, temperature_2m, relative_humidity_2m, wind_speed_10m, shortwave_radiation, et0_fao_mm, updated_at) FROM stdin;
1	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 00:00:00+00	0	26.2	81	1.05	144	0.1	2026-11-11 20:00:02.684056+00
2	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 01:00:00+00	0	27.9	73	0.55	381	0.27	2026-11-11 20:00:02.684056+00
3	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 02:00:00+00	0	29.2	68	1.15	637	0.46	2026-11-11 20:00:02.684056+00
4	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 03:00:00+00	0	30	67	2.25	786	0.58	2026-11-11 20:00:02.684056+00
5	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 04:00:00+00	0	31	61	2.89	894	0.67	2026-11-11 20:00:02.684056+00
6	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 05:00:00+00	0	31.8	57	2.99	846	0.66	2026-11-11 20:00:02.684056+00
7	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 06:00:00+00	0.3	32.5	50	4.14	941	0.74	2026-11-11 20:00:02.684056+00
8	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 07:00:00+00	1.5	30.4	61	4.11	791	0.59	2026-11-11 20:00:02.684056+00
9	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 08:00:00+00	0.7	30	61	2.77	538	0.42	2026-11-11 20:00:02.684056+00
10	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 09:00:00+00	0	30.2	59	1.87	440	0.34	2026-11-11 20:00:02.684056+00
11	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 10:00:00+00	0.1	28.6	69	1.91	210	0.17	2026-11-11 20:00:02.684056+00
12	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 11:00:00+00	0	26.9	81	0.67	29	0.02	2026-11-11 20:00:02.684056+00
13	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 12:00:00+00	0	25.8	92	0.66	0	0	2026-11-11 20:00:02.684056+00
14	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 13:00:00+00	0	25.5	91	0.72	0	0	2026-11-11 20:00:02.684056+00
15	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 14:00:00+00	0	25	90	1.19	0	0	2026-11-11 20:00:02.684056+00
16	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 15:00:00+00	0	24.7	88	1.14	0	0	2026-11-11 20:00:02.684056+00
17	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 16:00:00+00	0	24.5	85	1.3	0	0.01	2026-11-11 20:00:02.684056+00
18	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 17:00:00+00	0	24.4	84	1.39	0	0.01	2026-11-11 20:00:02.684056+00
19	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 18:00:00+00	0	24	87	1.01	0	0	2026-11-11 20:00:02.684056+00
20	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 19:00:00+00	0	24.1	86	1.55	0	0.01	2026-11-11 20:00:02.684056+00
21	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 20:00:00+00	0	24.1	85	1.75	0	0.01	2026-11-11 20:00:02.684056+00
22	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 21:00:00+00	0	24.3	82	1.59	0	0.01	2026-11-11 20:00:02.684056+00
23	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 22:00:00+00	0	24.2	81	1.23	0	0.01	2026-11-11 20:00:02.684056+00
24	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-02 23:00:00+00	0	24.9	80	0.87	13	0.01	2026-11-11 20:00:02.684056+00
25	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 00:00:00+00	0	27.1	73	0.67	149	0.1	2026-11-12 20:00:01.323727+00
26	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 01:00:00+00	0	28.5	66	0.94	405	0.29	2026-11-12 20:00:01.323727+00
27	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 02:00:00+00	0	29.6	64	1.5	636	0.47	2026-11-12 20:00:01.323727+00
28	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 03:00:00+00	0.1	30.2	62	2.11	782	0.58	2026-11-12 20:00:01.323727+00
29	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 04:00:00+00	0.1	31.1	57	1.82	892	0.67	2026-11-12 20:00:01.323727+00
30	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 05:00:00+00	0.1	32.1	51	2.1	831	0.65	2026-11-12 20:00:01.323727+00
31	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 06:00:00+00	0.3	32.6	47	4.3	876	0.71	2026-11-12 20:00:01.323727+00
32	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 07:00:00+00	0.2	32.6	47	4.12	800	0.66	2026-11-12 20:00:01.323727+00
33	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 08:00:00+00	0	32.4	47	4.68	654	0.56	2026-11-12 20:00:01.323727+00
34	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 09:00:00+00	0	30.8	55	5.01	422	0.38	2026-11-12 20:00:01.323727+00
35	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 10:00:00+00	0	29.5	59	3.43	198	0.2	2026-11-12 20:00:01.323727+00
36	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 11:00:00+00	0	27.9	64	1.48	32	0.05	2026-11-12 20:00:01.323727+00
37	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 12:00:00+00	0	27.7	71	0.76	0	0.01	2026-11-12 20:00:01.323727+00
38	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 13:00:00+00	0	27.2	72	0.16	0	0	2026-11-12 20:00:01.323727+00
39	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 14:00:00+00	0	26.3	77	0.35	0	0	2026-11-12 20:00:01.323727+00
40	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 15:00:00+00	0	25.3	81	0.96	0	0.01	2026-11-12 20:00:01.323727+00
41	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 16:00:00+00	0	24.8	84	1.61	0	0.01	2026-11-12 20:00:01.323727+00
42	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 17:00:00+00	0	24.2	85	1.6	0	0.01	2026-11-12 20:00:01.323727+00
43	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 18:00:00+00	0	24.1	86	1.17	0	0	2026-11-12 20:00:01.323727+00
44	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 19:00:00+00	0	23.9	84	1.42	0	0.01	2026-11-12 20:00:01.323727+00
45	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 20:00:00+00	0	23.7	83	1.23	0	0.01	2026-11-12 20:00:01.323727+00
46	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 21:00:00+00	0	24.2	80	1.27	0	0.01	2026-11-12 20:00:01.323727+00
47	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 22:00:00+00	0	24	80	1.26	0	0.01	2026-11-12 20:00:01.323727+00
48	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-03 23:00:00+00	0	25.1	76	0.91	15	0.01	2026-11-12 20:00:01.323727+00
49	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 00:00:00+00	0	27	70	0.76	172	0.12	2026-11-12 20:00:01.323727+00
50	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 01:00:00+00	0	28.4	68	0.98	397	0.28	2026-11-12 20:00:01.323727+00
51	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 02:00:00+00	0	29.6	66	1.34	606	0.45	2026-11-12 20:00:01.323727+00
52	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 03:00:00+00	0.1	29.8	66	1.39	782	0.58	2026-11-12 20:00:01.323727+00
53	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 04:00:00+00	0	30.7	62	1.89	753	0.57	2026-11-12 20:00:01.323727+00
54	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 05:00:00+00	0	32.2	56	3.16	965	0.74	2026-11-12 20:00:01.323727+00
55	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 06:00:00+00	0.3	32.9	47	4.53	904	0.73	2026-11-12 20:00:01.323727+00
56	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 07:00:00+00	0.1	33.1	45	4.72	813	0.68	2026-11-12 20:00:01.323727+00
57	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 08:00:00+00	0.8	29.1	65	4.18	587	0.44	2026-11-12 20:00:01.323727+00
58	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 09:00:00+00	0.2	28.9	65	1.09	320	0.25	2026-11-12 20:00:01.323727+00
59	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 10:00:00+00	0.1	28.3	70	1.08	144	0.12	2026-11-12 20:00:01.323727+00
60	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 11:00:00+00	0	27.3	81	0.6	30	0.02	2026-11-12 20:00:01.323727+00
61	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 12:00:00+00	0	27.3	76	1.12	0	0.01	2026-11-12 20:00:01.323727+00
62	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 13:00:00+00	0	26.5	80	0.18	0	0	2026-11-12 20:00:01.323727+00
63	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 14:00:00+00	0	25.9	82	0.27	0	0	2026-11-12 20:00:01.323727+00
64	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 15:00:00+00	0	25.3	80	0.89	0	0.01	2026-11-12 20:00:01.323727+00
65	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 16:00:00+00	0	24.9	78	1.12	0	0.01	2026-11-12 20:00:01.323727+00
66	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 17:00:00+00	0	24.5	79	1.31	0	0.01	2026-11-12 20:00:01.323727+00
67	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 18:00:00+00	0	24.4	81	1.15	0	0.01	2026-11-12 20:00:01.323727+00
68	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 19:00:00+00	0	24.2	81	1.52	0	0.01	2026-11-12 20:00:01.323727+00
69	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 20:00:00+00	0	24.5	80	1.81	0	0.02	2026-11-12 20:00:01.323727+00
70	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 21:00:00+00	0	24.6	79	1.69	0	0.02	2026-11-12 20:00:01.323727+00
71	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 22:00:00+00	0	24.3	80	1.31	0	0.01	2026-11-12 20:00:01.323727+00
72	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-04 23:00:00+00	0	24.9	78	1.53	16	0.02	2026-11-12 20:00:01.323727+00
73	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 00:00:00+00	0	26.6	75	1.8	168	0.12	2026-11-12 20:00:01.323727+00
74	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 01:00:00+00	0	28.3	71	1.55	410	0.29	2026-11-12 20:00:01.323727+00
75	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 02:00:00+00	0	29.8	65	1.32	624	0.46	2026-11-12 20:00:01.323727+00
76	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 03:00:00+00	0.3	30.8	61	1.71	795	0.6	2026-11-12 20:00:01.323727+00
77	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 04:00:00+00	0.4	31	58	2.14	899	0.68	2026-11-12 20:00:01.323727+00
78	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 05:00:00+00	0.2	31.5	57	2.09	875	0.67	2026-11-12 20:00:01.323727+00
79	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 06:00:00+00	0	33.5	46	1.36	912	0.72	2026-11-12 20:00:01.323727+00
80	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 07:00:00+00	0.2	33.8	45	0.22	810	0.62	2026-11-12 20:00:01.323727+00
81	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 08:00:00+00	0.1	33.8	45	0.54	634	0.49	2026-11-12 20:00:01.323727+00
82	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 09:00:00+00	0.5	29	68	3.47	394	0.31	2026-11-12 20:00:01.323727+00
83	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 10:00:00+00	0.1	27.3	74	2.41	140	0.13	2026-11-12 20:00:01.323727+00
84	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 11:00:00+00	0	26.8	78	1.71	25	0.04	2026-11-12 20:00:01.323727+00
85	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 12:00:00+00	0	26.5	93	1.48	0	0	2026-11-12 20:00:01.323727+00
86	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 13:00:00+00	0	26	94	1.57	0	0	2026-11-12 20:00:01.323727+00
87	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 14:00:00+00	0	25.5	94	1.3	0	0	2026-11-12 20:00:01.323727+00
88	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 15:00:00+00	0	25.1	92	1.12	0	0	2026-11-12 20:00:01.323727+00
89	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 16:00:00+00	0	24.7	90	1.09	0	0	2026-11-12 20:00:01.323727+00
90	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 17:00:00+00	0	24.5	87	1.49	0	0.01	2026-11-12 20:00:01.323727+00
91	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 18:00:00+00	0	24.2	87	1.44	0	0.01	2026-11-12 20:00:01.323727+00
92	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 19:00:00+00	0	24.2	88	1.42	0	0.01	2026-11-12 20:00:01.323727+00
93	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 20:00:00+00	0	24.3	87	1.55	0	0.01	2026-11-12 20:00:01.323727+00
94	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 21:00:00+00	0	24.2	85	1.61	0	0.01	2026-11-12 20:00:01.323727+00
95	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 22:00:00+00	0	23.9	85	1.07	0	0	2026-11-12 20:00:01.323727+00
96	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-05 23:00:00+00	0	24.6	82	0.93	15	0.01	2026-11-12 20:00:01.323727+00
97	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 00:00:00+00	0	26.8	75	0.92	159	0.11	2026-11-12 20:00:01.323727+00
98	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 01:00:00+00	0	28	72	0.65	367	0.26	2026-11-12 20:00:01.323727+00
99	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 02:00:00+00	0	29.1	69	1.3	609	0.44	2026-11-12 20:00:01.323727+00
100	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 03:00:00+00	0.2	29.6	68	1.28	697	0.52	2026-11-12 20:00:01.323727+00
101	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 04:00:00+00	0.1	30.1	68	1.25	823	0.61	2026-11-12 20:00:01.323727+00
102	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 05:00:00+00	0.1	30.9	67	1.66	916	0.69	2026-11-12 20:00:01.323727+00
103	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 06:00:00+00	0.1	32.2	54	3.13	770	0.62	2026-11-12 20:00:01.323727+00
104	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 07:00:00+00	0.2	33	48	3.51	802	0.65	2026-11-12 20:00:01.323727+00
105	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 08:00:00+00	0.2	32.9	45	3.89	669	0.57	2026-11-12 20:00:01.323727+00
106	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 09:00:00+00	0.4	29.6	64	4.56	422	0.35	2026-11-12 20:00:01.323727+00
107	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 10:00:00+00	0	28.1	71	2.19	174	0.15	2026-11-12 20:00:01.323727+00
108	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 11:00:00+00	0	26.6	82	0.46	33	0.02	2026-11-12 20:00:01.323727+00
109	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 12:00:00+00	0	24.8	91	1.2	0	0	2026-11-12 20:00:01.323727+00
110	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 13:00:00+00	0.1	25.1	93	1.1	0	0	2026-11-12 20:00:01.323727+00
111	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 14:00:00+00	0	25.1	91	1.42	0	0	2026-11-12 20:00:01.323727+00
112	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 15:00:00+00	0.2	24.7	91	1.85	0	0.01	2026-11-12 20:00:01.323727+00
113	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 16:00:00+00	0.1	24.2	91	1.55	0	0	2026-11-12 20:00:01.323727+00
114	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 17:00:00+00	0.5	24	94	1.61	0	0	2026-11-12 20:00:01.323727+00
115	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 18:00:00+00	0.3	24.2	90	0.97	0	0	2026-11-12 20:00:01.323727+00
116	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 19:00:00+00	0	24.3	89	1.05	0	0	2026-11-12 20:00:01.323727+00
117	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 20:00:00+00	0	24.4	86	1.11	0	0	2026-11-12 20:00:01.323727+00
118	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 21:00:00+00	0	24.1	85	0.96	0	0	2026-11-12 20:00:01.323727+00
119	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 22:00:00+00	0	24.1	85	1.07	0	0	2026-11-12 20:00:01.323727+00
120	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-06 23:00:00+00	0	24.7	83	1.19	16	0.01	2026-11-12 20:00:01.323727+00
121	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 00:00:00+00	0	26.8	75	1.7	154	0.12	2026-11-12 20:00:01.323727+00
122	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 01:00:00+00	0	28.2	69	1.58	348	0.26	2026-11-12 20:00:01.323727+00
123	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 02:00:00+00	0	29.8	61	0.57	572	0.42	2026-11-12 20:00:01.323727+00
124	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 03:00:00+00	0	30.7	57	1.4	782	0.59	2026-11-12 20:00:01.323727+00
125	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 04:00:00+00	0	31.6	53	1.87	920	0.7	2026-11-12 20:00:01.323727+00
126	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 05:00:00+00	0.1	32.4	50	2.28	974	0.75	2026-11-12 20:00:01.323727+00
127	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 06:00:00+00	0.1	33.2	47	1.68	892	0.7	2026-11-12 20:00:01.323727+00
128	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 07:00:00+00	0.1	33.3	48	1.08	773	0.61	2026-11-12 20:00:01.323727+00
129	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 08:00:00+00	0	32.8	48	1.2	549	0.44	2026-11-12 20:00:01.323727+00
130	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 09:00:00+00	1.1	28.4	74	2.55	398	0.29	2026-11-12 20:00:01.323727+00
131	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 10:00:00+00	0.6	27.4	84	0.8	130	0.1	2026-11-12 20:00:01.323727+00
132	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 11:00:00+00	0	26.5	86	1.2	27	0.02	2026-11-12 20:00:01.323727+00
133	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 12:00:00+00	0	26.8	85	1.08	0	0.01	2026-11-12 20:00:01.323727+00
134	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 13:00:00+00	0	26.1	89	0.57	0	0	2026-11-12 20:00:01.323727+00
135	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 14:00:00+00	0.1	25.7	89	0.83	0	0	2026-11-12 20:00:01.323727+00
136	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 15:00:00+00	0	25	89	0.96	0	0	2026-11-12 20:00:01.323727+00
137	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 16:00:00+00	0	24.6	89	1.12	0	0	2026-11-12 20:00:01.323727+00
138	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 17:00:00+00	0	24.4	88	1.1	0	0	2026-11-12 20:00:01.323727+00
139	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 18:00:00+00	0	24.1	89	0.67	0	0	2026-11-12 20:00:01.323727+00
140	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 19:00:00+00	0	23.8	89	0.65	0	0	2026-11-12 20:00:01.323727+00
141	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 20:00:00+00	0	23.6	89	0.92	0	0	2026-11-12 20:00:01.323727+00
142	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 21:00:00+00	0	23.6	88	1.16	0	0	2026-11-12 20:00:01.323727+00
143	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 22:00:00+00	0	23.4	88	1.22	0	0	2026-11-12 20:00:01.323727+00
144	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-07 23:00:00+00	0	23.9	86	1.25	16	0.01	2026-11-12 20:00:01.323727+00
145	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 00:00:00+00	0	26.4	81	1	151	0.1	2026-11-12 20:00:01.323727+00
146	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 01:00:00+00	0	28.2	70	0.5	406	0.28	2026-11-12 20:00:01.323727+00
147	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 02:00:00+00	0	29.5	64	1.21	615	0.45	2026-11-12 20:00:01.323727+00
148	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 03:00:00+00	0	31	58	2.45	810	0.61	2026-11-12 20:00:01.323727+00
149	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 04:00:00+00	0	32.2	51	3.19	912	0.71	2026-11-12 20:00:01.323727+00
150	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 05:00:00+00	0.2	32.6	49	3.94	936	0.74	2026-11-12 20:00:01.323727+00
151	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 06:00:00+00	0.2	33.6	43	4.14	910	0.75	2026-11-12 20:00:01.323727+00
152	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 07:00:00+00	0	34.2	39	3.71	831	0.71	2026-11-12 20:00:01.323727+00
153	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 08:00:00+00	0	34.1	40	3.98	684	0.6	2026-11-12 20:00:01.323727+00
154	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 09:00:00+00	0	33.2	43	4.03	417	0.42	2026-11-12 20:00:01.323727+00
155	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 10:00:00+00	0	31.3	53	3.15	211	0.22	2026-11-12 20:00:01.323727+00
156	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 11:00:00+00	0	29.1	68	0.5	33	0.02	2026-11-12 20:00:01.323727+00
157	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 12:00:00+00	0	27.6	75	1.21	0	0.01	2026-11-12 20:00:01.323727+00
158	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 13:00:00+00	0	26.3	82	1.11	0	0.01	2026-11-12 20:00:01.323727+00
159	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 14:00:00+00	0	25.8	86	0.25	0	0	2026-11-12 20:00:01.323727+00
160	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 15:00:00+00	0	25.4	85	0.88	0	0	2026-11-12 20:00:01.323727+00
161	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 16:00:00+00	0	25.2	84	0.78	0	0	2026-11-12 20:00:01.323727+00
162	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 17:00:00+00	0	24.9	84	0.81	0	0	2026-11-12 20:00:01.323727+00
163	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 18:00:00+00	0	25	83	0.96	0	0	2026-11-12 20:00:01.323727+00
164	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 19:00:00+00	0	24.6	84	1.17	0	0.01	2026-11-12 20:00:01.323727+00
165	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 20:00:00+00	0.1	24.5	85	0.83	0	0	2026-11-12 20:00:01.323727+00
166	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 21:00:00+00	0	24.3	85	0.67	0	0	2026-11-12 20:00:01.323727+00
167	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 22:00:00+00	0	24	85	0.74	0	0	2026-11-12 20:00:01.323727+00
168	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-08 23:00:00+00	0	24.9	82	0.51	16	0.01	2026-11-12 20:00:01.323727+00
169	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 00:00:00+00	0	27.7	68	0.97	154	0.11	2026-11-12 20:00:01.323727+00
170	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 01:00:00+00	0	27.9	70	2.03	397	0.29	2026-11-12 20:00:01.323727+00
171	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 02:00:00+00	0	28.7	70	2.12	627	0.45	2026-11-12 20:00:01.323727+00
172	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 03:00:00+00	0	30	65	2	780	0.58	2026-11-12 20:00:01.323727+00
173	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 04:00:00+00	0.2	31	60	2.1	848	0.64	2026-11-12 20:00:01.323727+00
174	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 05:00:00+00	0.2	32.1	55	2.08	939	0.72	2026-11-12 20:00:01.323727+00
175	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 06:00:00+00	0.2	32.9	52	1.22	840	0.66	2026-11-12 20:00:01.323727+00
176	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 07:00:00+00	0.2	32.7	53	1.7	798	0.62	2026-11-12 20:00:01.323727+00
177	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 08:00:00+00	0.1	32.3	53	2.06	641	0.51	2026-11-12 20:00:01.323727+00
178	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 09:00:00+00	0.1	31.5	56	1.39	444	0.35	2026-11-12 20:00:01.323727+00
179	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 10:00:00+00	0.5	29.8	66	1.18	205	0.16	2026-11-12 20:00:01.323727+00
180	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 11:00:00+00	0.9	27.5	83	0.82	32	0.02	2026-11-12 20:00:01.323727+00
181	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 12:00:00+00	0.2	27	79	0.27	0	0	2026-11-12 20:00:01.323727+00
182	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 13:00:00+00	0	26.4	83	0.6	0	0	2026-11-12 20:00:01.323727+00
183	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 14:00:00+00	0	25.9	86	1.71	0	0.01	2026-11-12 20:00:01.323727+00
184	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 15:00:00+00	0	25.5	86	1.67	0	0.01	2026-11-12 20:00:01.323727+00
185	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 16:00:00+00	0	25.5	84	1.5	0	0.01	2026-11-12 20:00:01.323727+00
186	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 17:00:00+00	0	25.2	84	0.97	0	0	2026-11-12 20:00:01.323727+00
187	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 18:00:00+00	0	25.1	81	1.45	0	0.01	2026-11-12 20:00:01.323727+00
188	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 19:00:00+00	0	24.8	82	1.61	0	0.01	2026-11-12 20:00:01.323727+00
189	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 20:00:00+00	0	24.8	81	1.43	0	0.01	2026-11-12 20:00:01.323727+00
190	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 21:00:00+00	0	24.3	82	1.07	0	0.01	2026-11-12 20:00:01.323727+00
191	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 22:00:00+00	0	24.3	82	1.07	0	0.01	2026-11-12 20:00:01.323727+00
192	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-09 23:00:00+00	0	25	78	0.87	15	0.01	2026-11-12 20:00:01.323727+00
193	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 00:00:00+00	0	27.5	72	0.78	169	0.12	2026-11-12 20:00:01.323727+00
194	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 01:00:00+00	0	28	71	2.31	391	0.29	2026-11-12 20:00:01.323727+00
195	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 02:00:00+00	0.1	28.8	69	1.9	563	0.41	2026-11-12 20:00:01.323727+00
196	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 03:00:00+00	1.7	26.8	81	1.82	625	0.43	2026-11-12 20:00:01.323727+00
197	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 04:00:00+00	1.6	28.7	76	0.92	712	0.52	2026-11-12 20:00:01.323727+00
198	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 05:00:00+00	0.2	30.1	71	0.6	809	0.61	2026-11-12 20:00:01.323727+00
199	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 06:00:00+00	1	30.4	64	1.13	816	0.61	2026-11-12 20:00:01.323727+00
200	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 07:00:00+00	1.2	28.9	71	2.86	695	0.5	2026-11-12 20:00:01.323727+00
201	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 08:00:00+00	1	28.7	69	1.87	513	0.38	2026-11-12 20:00:01.323727+00
202	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 09:00:00+00	0	28.3	70	1.69	300	0.23	2026-11-12 20:00:01.323727+00
203	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 10:00:00+00	0.1	27.4	74	1.24	179	0.13	2026-11-12 20:00:01.323727+00
204	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 11:00:00+00	0	26.7	80	0.56	23	0.02	2026-11-12 20:00:01.323727+00
205	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 12:00:00+00	0.3	25.6	89	0.27	0	0	2026-11-12 20:00:01.323727+00
206	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 13:00:00+00	0.7	25.4	91	0.59	0	0	2026-11-12 20:00:01.323727+00
207	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 14:00:00+00	0.1	25.2	93	0.81	0	0	2026-11-12 20:00:01.323727+00
208	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 15:00:00+00	0	24.9	93	1.22	0	0	2026-11-12 20:00:01.323727+00
209	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 16:00:00+00	0	24.7	93	0.96	0	0	2026-11-12 20:00:01.323727+00
210	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 17:00:00+00	0	24.9	91	0.28	0	0	2026-11-12 20:00:01.323727+00
211	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 18:00:00+00	0	24.9	87	0.81	0	0	2026-11-12 20:00:01.323727+00
212	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 19:00:00+00	0	24.4	89	1.1	0	0	2026-11-12 20:00:01.323727+00
213	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 20:00:00+00	0	24.3	87	0.86	0	0	2026-11-12 20:00:01.323727+00
214	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 21:00:00+00	0	24.3	84	0.84	0	0	2026-11-12 20:00:01.323727+00
215	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 22:00:00+00	0	24.1	84	1.06	0	0	2026-11-12 20:00:01.323727+00
216	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-10 23:00:00+00	0	24.8	83	0.83	16	0.01	2026-11-12 20:00:01.323727+00
217	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 00:00:00+00	0	27	75	1.38	169	0.12	2026-11-12 20:00:01.323727+00
218	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 01:00:00+00	0	28.5	66	0.49	382	0.27	2026-11-12 20:00:01.323727+00
219	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 02:00:00+00	0	29.3	62	0.9	491	0.37	2026-11-12 20:00:01.323727+00
220	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 03:00:00+00	0	30.4	59	1.81	666	0.51	2026-11-12 20:00:01.323727+00
221	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 04:00:00+00	0.1	31.7	54	2.37	888	0.68	2026-11-12 20:00:01.323727+00
222	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 05:00:00+00	0.1	32.5	49	3.34	922	0.73	2026-11-12 20:00:01.323727+00
223	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 06:00:00+00	0.2	33.9	43	3.85	917	0.76	2026-11-12 20:00:01.323727+00
224	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 07:00:00+00	0.1	34	42	3.62	820	0.69	2026-11-12 20:00:01.323727+00
225	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 08:00:00+00	0	33.4	43	4.57	673	0.59	2026-11-12 20:00:01.323727+00
226	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 09:00:00+00	0.5	29.3	63	4.01	460	0.36	2026-11-12 20:00:01.323727+00
227	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 10:00:00+00	0.7	27.6	76	2.8	154	0.14	2026-11-12 20:00:01.323727+00
228	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 11:00:00+00	0.5	26.8	81	1.46	29	0.03	2026-11-12 20:00:01.323727+00
229	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 12:00:00+00	0.1	26.5	82	0.36	0	0	2026-11-12 20:00:01.323727+00
230	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 13:00:00+00	0	26.2	87	0.8	0	0	2026-11-12 20:00:01.323727+00
231	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 14:00:00+00	0	25.9	89	0.97	0	0	2026-11-12 20:00:01.323727+00
232	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 15:00:00+00	0	25.5	89	1.47	0	0.01	2026-11-12 20:00:01.323727+00
233	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 16:00:00+00	0	25.2	87	1.59	0	0.01	2026-11-12 20:00:01.323727+00
234	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 17:00:00+00	0	24.9	85	1.22	0	0.01	2026-11-12 20:00:01.323727+00
235	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 18:00:00+00	0	24.6	85	1.21	0	0.01	2026-11-12 20:00:01.323727+00
236	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 19:00:00+00	0	24.2	86	1.01	0	0	2026-11-12 20:00:01.323727+00
237	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 20:00:00+00	0	23.9	86	1.21	0	0	2026-11-12 20:00:01.323727+00
238	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 21:00:00+00	0	23.7	86	1.23	0	0	2026-11-12 20:00:01.323727+00
239	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 22:00:00+00	0	23.6	85	0.97	0	0	2026-11-12 20:00:01.323727+00
240	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-11 23:00:00+00	0	24.3	83	1.07	16	0.01	2026-11-12 20:00:01.323727+00
457	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 00:00:00+00	0	27.3	73	0.75	176	0.12	2026-11-12 20:00:01.323727+00
458	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 01:00:00+00	0	28.7	69	1.5	408	0.3	2026-11-12 20:00:01.323727+00
459	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 02:00:00+00	0	29.8	66	1.35	598	0.44	2026-11-12 20:00:01.323727+00
460	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 03:00:00+00	0	31.2	61	2	799	0.6	2026-11-12 20:00:01.323727+00
461	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 04:00:00+00	0.1	32.4	54	2.9	870	0.68	2026-11-12 20:00:01.323727+00
462	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 05:00:00+00	0.1	33.2	49	3.57	876	0.71	2026-11-12 20:00:01.323727+00
463	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 06:00:00+00	0.5	34	48	3.83	884	0.73	2026-11-12 20:00:01.323727+00
464	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 07:00:00+00	0.1	33.9	46	3.3	713	0.61	2026-11-12 20:00:01.323727+00
465	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 08:00:00+00	1.5	30.3	67	2.91	540	0.42	2026-11-12 20:00:01.323727+00
466	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 09:00:00+00	1.1	27.7	77	2.95	333	0.25	2026-11-12 20:00:01.323727+00
467	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 10:00:00+00	1	26.7	87	2.1	170	0.12	2026-11-12 20:00:01.323727+00
468	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 11:00:00+00	0.3	25.6	90	1.39	25	0.02	2026-11-12 20:00:01.323727+00
469	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 12:00:00+00	0.1	24.5	93	1.11	0	0	2026-11-12 20:00:01.323727+00
470	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 13:00:00+00	0.1	25.2	93	1.05	0	0	2026-11-12 20:00:01.323727+00
471	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 14:00:00+00	0	25.3	93	0.72	0	0	2026-11-12 20:00:01.323727+00
472	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 15:00:00+00	0	25.8	89	0.28	0	0	2026-11-12 20:00:01.323727+00
473	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 16:00:00+00	0	26	84	0.34	0	0	2026-11-12 20:00:01.323727+00
474	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 17:00:00+00	0	25.9	82	0.22	0	0	2026-11-12 20:00:01.323727+00
475	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 18:00:00+00	0	25.3	84	0.65	0	0	2026-11-12 20:00:01.323727+00
476	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 19:00:00+00	0	24.6	87	1.17	0	0	2026-11-12 20:00:01.323727+00
477	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 20:00:00+00	0	24.1	88	1.12	0	0	2026-11-12 20:00:01.323727+00
478	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 21:00:00+00	0	24.2	87	0.96	0	0	2026-11-12 20:00:01.323727+00
479	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 22:00:00+00	0	24.7	83	0.6	0	0	2026-11-12 20:00:01.323727+00
480	00000000-0000-0000-0000-0000000000b1	open_meteo_archive	2026-11-12 23:00:00+00	0	25.1	84	0.95	13	0.01	2026-11-12 20:00:01.323727+00
\.


--
-- Name: clock_events_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.clock_events_id_seq', 4, true);


--
-- Name: ingest_rejects_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.ingest_rejects_id_seq', 1, true);


--
-- Name: sensor_raw_readings_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.sensor_raw_readings_id_seq', 544, true);


--
-- Name: water_balance_ledger_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.water_balance_ledger_id_seq', 2016, true);


--
-- Name: weather_forecast_snapshots_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.weather_forecast_snapshots_id_seq', 1920, true);


--
-- Name: weather_observed_hourly_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.weather_observed_hourly_id_seq', 480, true);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: auth; Owner: postgres
--

ALTER TABLE ONLY auth.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: actuator_commands actuator_commands_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.actuator_commands
    ADD CONSTRAINT actuator_commands_pkey PRIMARY KEY (id);


--
-- Name: clock_events clock_events_node_segment_uq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clock_events
    ADD CONSTRAINT clock_events_node_segment_uq UNIQUE (node_id, clock_segment);


--
-- Name: clock_events clock_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clock_events
    ADD CONSTRAINT clock_events_pkey PRIMARY KEY (id);


--
-- Name: fertigation_actions fertigation_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_actions
    ADD CONSTRAINT fertigation_actions_pkey PRIMARY KEY (id);


--
-- Name: fertigation_recommendations fertigation_recommendations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_recommendations
    ADD CONSTRAINT fertigation_recommendations_pkey PRIMARY KEY (id);


--
-- Name: fertilizer_products fertilizer_products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertilizer_products
    ADD CONSTRAINT fertilizer_products_pkey PRIMARY KEY (id);


--
-- Name: ingest_rejects ingest_rejects_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ingest_rejects
    ADD CONSTRAINT ingest_rejects_pkey PRIMARY KEY (id);


--
-- Name: irrigation_actions irrigation_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_actions
    ADD CONSTRAINT irrigation_actions_pkey PRIMARY KEY (id);


--
-- Name: irrigation_predictions irrigation_predictions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_predictions
    ADD CONSTRAINT irrigation_predictions_pkey PRIMARY KEY (id);


--
-- Name: model_registries model_registries_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.model_registries
    ADD CONSTRAINT model_registries_pkey PRIMARY KEY (id);


--
-- Name: node_actuator_config node_actuator_config_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.node_actuator_config
    ADD CONSTRAINT node_actuator_config_pkey PRIMARY KEY (node_id);


--
-- Name: nodes nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nodes
    ADD CONSTRAINT nodes_pkey PRIMARY KEY (id);


--
-- Name: nutrient_batch_items nutrient_batch_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nutrient_batch_items
    ADD CONSTRAINT nutrient_batch_items_pkey PRIMARY KEY (id);


--
-- Name: nutrient_batches nutrient_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nutrient_batches
    ADD CONSTRAINT nutrient_batches_pkey PRIMARY KEY (id);


--
-- Name: plot_soil_water_params plot_soil_water_params_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.plot_soil_water_params
    ADD CONSTRAINT plot_soil_water_params_pkey PRIMARY KEY (id);


--
-- Name: plots plots_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.plots
    ADD CONSTRAINT plots_pkey PRIMARY KEY (id);


--
-- Name: sensor_calibrations sensor_calibrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sensor_calibrations
    ADD CONSTRAINT sensor_calibrations_pkey PRIMARY KEY (id);


--
-- Name: sensor_raw_readings sensor_raw_readings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sensor_raw_readings
    ADD CONSTRAINT sensor_raw_readings_pkey PRIMARY KEY (id);


--
-- Name: water_balance_ledger water_balance_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.water_balance_ledger
    ADD CONSTRAINT water_balance_ledger_pkey PRIMARY KEY (id);


--
-- Name: water_balance_ledger wbl_unique_period; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.water_balance_ledger
    ADD CONSTRAINT wbl_unique_period UNIQUE (plot_id, period_end);


--
-- Name: weather_forecast_snapshots weather_forecast_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weather_forecast_snapshots
    ADD CONSTRAINT weather_forecast_snapshots_pkey PRIMARY KEY (id);


--
-- Name: weather_forecasts weather_forecasts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weather_forecasts
    ADD CONSTRAINT weather_forecasts_pkey PRIMARY KEY (id);


--
-- Name: weather_observed_hourly weather_observed_hourly_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weather_observed_hourly
    ADD CONSTRAINT weather_observed_hourly_pkey PRIMARY KEY (id);


--
-- Name: weather_forecast_snapshots wfs_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weather_forecast_snapshots
    ADD CONSTRAINT wfs_unique UNIQUE (plot_id, source, issued_at, valid_time);


--
-- Name: weather_observed_hourly woh_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weather_observed_hourly
    ADD CONSTRAINT woh_unique UNIQUE (plot_id, source, "time");


--
-- Name: idx_actuator_commands_node_time; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_actuator_commands_node_time ON public.actuator_commands USING btree (node_id, created_at DESC);


--
-- Name: idx_actuator_commands_pending; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_actuator_commands_pending ON public.actuator_commands USING btree (node_id, created_at) WHERE (status = 'pending'::text);


--
-- Name: idx_nutrient_batch_items_batch; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_nutrient_batch_items_batch ON public.nutrient_batch_items USING btree (batch_id);


--
-- Name: ingest_rejects_node_received_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX ingest_rejects_node_received_idx ON public.ingest_rejects USING btree (node_id, received_at);


--
-- Name: ip_plot_ts_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX ip_plot_ts_idx ON public.irrigation_predictions USING btree (plot_id, prediction_timestamp DESC);


--
-- Name: pswp_plot_valid_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX pswp_plot_valid_idx ON public.plot_soil_water_params USING btree (plot_id, valid_from DESC);


--
-- Name: sc_node_param_valid_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX sc_node_param_valid_idx ON public.sensor_calibrations USING btree (node_id, parameter, valid_from DESC);


--
-- Name: sensor_raw_readings_identity_uq; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX sensor_raw_readings_identity_uq ON public.sensor_raw_readings USING btree (node_id, clock_segment, reading_timestamp_raw);


--
-- Name: sensor_raw_readings_node_ts_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX sensor_raw_readings_node_ts_idx ON public.sensor_raw_readings USING btree (node_id, reading_timestamp);


--
-- Name: sensor_raw_readings_plot_ts_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX sensor_raw_readings_plot_ts_idx ON public.sensor_raw_readings USING btree (plot_id, reading_timestamp);


--
-- Name: uq_fertigation_actions_device_event; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_fertigation_actions_device_event ON public.fertigation_actions USING btree (node_id, device_event_id) WHERE (device_event_id IS NOT NULL);


--
-- Name: uq_irrigation_actions_device_event; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_irrigation_actions_device_event ON public.irrigation_actions USING btree (node_id, device_event_id) WHERE (device_event_id IS NOT NULL);


--
-- Name: uq_nutrient_batches_one_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_nutrient_batches_one_active ON public.nutrient_batches USING btree (node_id) WHERE is_active;


--
-- Name: weather_forecasts_plot_valid_source_uq; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX weather_forecasts_plot_valid_source_uq ON public.weather_forecasts USING btree (plot_id, valid_for_timestamp, source);


--
-- Name: wf_plot_valid_issued_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX wf_plot_valid_issued_idx ON public.weather_forecasts USING btree (plot_id, valid_for_timestamp, forecast_issued_at DESC);


--
-- Name: wfs_fetched_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX wfs_fetched_idx ON public.weather_forecast_snapshots USING btree (fetched_at DESC);


--
-- Name: wfs_plot_valid_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX wfs_plot_valid_idx ON public.weather_forecast_snapshots USING btree (plot_id, valid_time);


--
-- Name: woh_updated_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX woh_updated_idx ON public.weather_observed_hourly USING btree (updated_at DESC);


--
-- Name: nutrient_batch_concentration _RETURN; Type: RULE; Schema: public; Owner: postgres
--

CREATE OR REPLACE VIEW public.nutrient_batch_concentration WITH (security_invoker='true') AS
 SELECT b.id AS batch_id,
    b.node_id,
    b.is_active,
    b.solution_volume_l,
    (COALESCE(sum(((m.mass_g * p.n_pct) / (100)::double precision)), (0)::double precision) / (b.solution_volume_l * (1000)::double precision)) AS n_g_per_ml,
    (COALESCE(sum(((m.mass_g * p.p_pct) / (100)::double precision)), (0)::double precision) / (b.solution_volume_l * (1000)::double precision)) AS p2o5_g_per_ml,
    (COALESCE(sum(((m.mass_g * p.k_pct) / (100)::double precision)), (0)::double precision) / (b.solution_volume_l * (1000)::double precision)) AS k2o_g_per_ml,
    count(i.id) AS item_count,
    COALESCE(bool_and(p.is_verified), false) AS all_products_verified,
    (b.measured_ec_uscm IS NOT NULL) AS ec_measured
   FROM (((public.nutrient_batches b
     LEFT JOIN public.nutrient_batch_items i ON ((i.batch_id = b.id)))
     LEFT JOIN public.fertilizer_products p ON ((p.id = i.product_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(i.amount_g, (i.amount_ml * p.density_g_per_ml)) AS mass_g) m ON (true))
  GROUP BY b.id;


--
-- Name: nutrient_batches trg_activate_nutrient_batch; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_activate_nutrient_batch BEFORE INSERT OR UPDATE OF is_active ON public.nutrient_batches FOR EACH ROW EXECUTE FUNCTION public.smile_activate_nutrient_batch();


--
-- Name: node_actuator_config trg_bump_config_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_bump_config_version BEFORE UPDATE ON public.node_actuator_config FOR EACH ROW EXECUTE FUNCTION public.smile_bump_config_version();


--
-- Name: fertigation_actions trg_fertigation_actions_sync_node; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_fertigation_actions_sync_node AFTER INSERT ON public.fertigation_actions FOR EACH ROW EXECUTE FUNCTION public.sync_node_pump_state();


--
-- Name: actuator_commands trg_guard_actuator_command; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_guard_actuator_command BEFORE INSERT ON public.actuator_commands FOR EACH ROW EXECUTE FUNCTION public.smile_guard_actuator_command();


--
-- Name: nutrient_batch_items trg_guard_batch_item; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_guard_batch_item BEFORE INSERT OR UPDATE ON public.nutrient_batch_items FOR EACH ROW EXECUTE FUNCTION public.smile_guard_batch_item();


--
-- Name: fertilizer_products trg_guard_fertilizer_product; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_guard_fertilizer_product BEFORE INSERT OR UPDATE ON public.fertilizer_products FOR EACH ROW EXECUTE FUNCTION public.smile_guard_fertilizer_product();


--
-- Name: irrigation_actions trg_irrigation_actions_sync_node; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_irrigation_actions_sync_node AFTER INSERT ON public.irrigation_actions FOR EACH ROW EXECUTE FUNCTION public.sync_node_valve_state();


--
-- Name: node_actuator_config trg_nac_refresh_auto; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_nac_refresh_auto AFTER UPDATE OF thresholds_auto ON public.node_actuator_config FOR EACH ROW WHEN ((new.thresholds_auto AND (NOT old.thresholds_auto))) EXECUTE FUNCTION public.smile_trg_refresh_from_config();


--
-- Name: node_actuator_config trg_nac_refresh_ins; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_nac_refresh_ins AFTER INSERT ON public.node_actuator_config FOR EACH ROW EXECUTE FUNCTION public.smile_trg_refresh_from_config();


--
-- Name: plot_soil_water_params trg_pswp_refresh; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_pswp_refresh AFTER INSERT OR UPDATE ON public.plot_soil_water_params FOR EACH ROW EXECUTE FUNCTION public.smile_trg_refresh_from_params();


--
-- Name: sensor_calibrations trg_sc_refresh; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sc_refresh AFTER INSERT OR UPDATE ON public.sensor_calibrations FOR EACH ROW EXECUTE FUNCTION public.smile_trg_refresh_from_calibration();


--
-- Name: actuator_commands actuator_commands_fertigation_recommendation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.actuator_commands
    ADD CONSTRAINT actuator_commands_fertigation_recommendation_id_fkey FOREIGN KEY (fertigation_recommendation_id) REFERENCES public.fertigation_recommendations(id);


--
-- Name: actuator_commands actuator_commands_irrigation_prediction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.actuator_commands
    ADD CONSTRAINT actuator_commands_irrigation_prediction_id_fkey FOREIGN KEY (irrigation_prediction_id) REFERENCES public.irrigation_predictions(id);


--
-- Name: actuator_commands actuator_commands_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.actuator_commands
    ADD CONSTRAINT actuator_commands_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id);


--
-- Name: actuator_commands actuator_commands_nutrient_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.actuator_commands
    ADD CONSTRAINT actuator_commands_nutrient_batch_id_fkey FOREIGN KEY (nutrient_batch_id) REFERENCES public.nutrient_batches(id);


--
-- Name: actuator_commands actuator_commands_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.actuator_commands
    ADD CONSTRAINT actuator_commands_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id);


--
-- Name: clock_events clock_events_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clock_events
    ADD CONSTRAINT clock_events_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id);


--
-- Name: fertigation_actions fertigation_actions_command_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_actions
    ADD CONSTRAINT fertigation_actions_command_id_fkey FOREIGN KEY (command_id) REFERENCES public.actuator_commands(id);


--
-- Name: fertigation_actions fertigation_actions_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_actions
    ADD CONSTRAINT fertigation_actions_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id);


--
-- Name: fertigation_actions fertigation_actions_nutrient_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_actions
    ADD CONSTRAINT fertigation_actions_nutrient_batch_id_fkey FOREIGN KEY (nutrient_batch_id) REFERENCES public.nutrient_batches(id);


--
-- Name: fertigation_actions fertigation_actions_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_actions
    ADD CONSTRAINT fertigation_actions_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id);


--
-- Name: fertigation_actions fertigation_actions_recommendation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_actions
    ADD CONSTRAINT fertigation_actions_recommendation_id_fkey FOREIGN KEY (recommendation_id) REFERENCES public.fertigation_recommendations(id);


--
-- Name: fertigation_recommendations fertigation_recommendations_dispatched_command_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_recommendations
    ADD CONSTRAINT fertigation_recommendations_dispatched_command_id_fkey FOREIGN KEY (dispatched_command_id) REFERENCES public.actuator_commands(id);


--
-- Name: fertigation_recommendations fertigation_recommendations_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_recommendations
    ADD CONSTRAINT fertigation_recommendations_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.model_registries(id);


--
-- Name: fertigation_recommendations fertigation_recommendations_nutrient_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_recommendations
    ADD CONSTRAINT fertigation_recommendations_nutrient_batch_id_fkey FOREIGN KEY (nutrient_batch_id) REFERENCES public.nutrient_batches(id);


--
-- Name: fertigation_recommendations fertigation_recommendations_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertigation_recommendations
    ADD CONSTRAINT fertigation_recommendations_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id);


--
-- Name: fertilizer_products fertilizer_products_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.fertilizer_products
    ADD CONSTRAINT fertilizer_products_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: ingest_rejects ingest_rejects_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ingest_rejects
    ADD CONSTRAINT ingest_rejects_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id);


--
-- Name: irrigation_actions irrigation_actions_command_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_actions
    ADD CONSTRAINT irrigation_actions_command_id_fkey FOREIGN KEY (command_id) REFERENCES public.actuator_commands(id);


--
-- Name: irrigation_actions irrigation_actions_irrigation_prediction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_actions
    ADD CONSTRAINT irrigation_actions_irrigation_prediction_id_fkey FOREIGN KEY (irrigation_prediction_id) REFERENCES public.irrigation_predictions(id);


--
-- Name: irrigation_actions irrigation_actions_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_actions
    ADD CONSTRAINT irrigation_actions_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id);


--
-- Name: irrigation_actions irrigation_actions_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_actions
    ADD CONSTRAINT irrigation_actions_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id);


--
-- Name: irrigation_predictions irrigation_predictions_dispatched_command_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_predictions
    ADD CONSTRAINT irrigation_predictions_dispatched_command_id_fkey FOREIGN KEY (dispatched_command_id) REFERENCES public.actuator_commands(id);


--
-- Name: irrigation_predictions irrigation_predictions_ledger_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_predictions
    ADD CONSTRAINT irrigation_predictions_ledger_id_fkey FOREIGN KEY (ledger_id) REFERENCES public.water_balance_ledger(id) ON DELETE SET NULL;


--
-- Name: irrigation_predictions irrigation_predictions_model_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_predictions
    ADD CONSTRAINT irrigation_predictions_model_id_fkey FOREIGN KEY (model_id) REFERENCES public.model_registries(id);


--
-- Name: irrigation_predictions irrigation_predictions_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.irrigation_predictions
    ADD CONSTRAINT irrigation_predictions_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id);


--
-- Name: node_actuator_config node_actuator_config_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.node_actuator_config
    ADD CONSTRAINT node_actuator_config_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE;


--
-- Name: nodes nodes_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nodes
    ADD CONSTRAINT nodes_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id);


--
-- Name: nodes nodes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nodes
    ADD CONSTRAINT nodes_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: nutrient_batch_items nutrient_batch_items_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nutrient_batch_items
    ADD CONSTRAINT nutrient_batch_items_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.nutrient_batches(id) ON DELETE CASCADE;


--
-- Name: nutrient_batch_items nutrient_batch_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nutrient_batch_items
    ADD CONSTRAINT nutrient_batch_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.fertilizer_products(id);


--
-- Name: nutrient_batches nutrient_batches_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nutrient_batches
    ADD CONSTRAINT nutrient_batches_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE;


--
-- Name: plot_soil_water_params plot_soil_water_params_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.plot_soil_water_params
    ADD CONSTRAINT plot_soil_water_params_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id) ON DELETE CASCADE;


--
-- Name: plots plots_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.plots
    ADD CONSTRAINT plots_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: sensor_calibrations sensor_calibrations_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sensor_calibrations
    ADD CONSTRAINT sensor_calibrations_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE CASCADE;


--
-- Name: sensor_raw_readings sensor_raw_readings_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sensor_raw_readings
    ADD CONSTRAINT sensor_raw_readings_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id);


--
-- Name: sensor_raw_readings sensor_raw_readings_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sensor_raw_readings
    ADD CONSTRAINT sensor_raw_readings_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id);


--
-- Name: water_balance_ledger water_balance_ledger_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.water_balance_ledger
    ADD CONSTRAINT water_balance_ledger_node_id_fkey FOREIGN KEY (node_id) REFERENCES public.nodes(id) ON DELETE SET NULL;


--
-- Name: water_balance_ledger water_balance_ledger_params_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.water_balance_ledger
    ADD CONSTRAINT water_balance_ledger_params_id_fkey FOREIGN KEY (params_id) REFERENCES public.plot_soil_water_params(id);


--
-- Name: water_balance_ledger water_balance_ledger_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.water_balance_ledger
    ADD CONSTRAINT water_balance_ledger_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id) ON DELETE CASCADE;


--
-- Name: weather_forecast_snapshots weather_forecast_snapshots_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weather_forecast_snapshots
    ADD CONSTRAINT weather_forecast_snapshots_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id) ON DELETE CASCADE;


--
-- Name: weather_forecasts weather_forecasts_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weather_forecasts
    ADD CONSTRAINT weather_forecasts_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: weather_observed_hourly weather_observed_hourly_plot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.weather_observed_hourly
    ADD CONSTRAINT weather_observed_hourly_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES public.plots(id) ON DELETE CASCADE;


--
-- Name: actuator_commands; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.actuator_commands ENABLE ROW LEVEL SECURITY;

--
-- Name: clock_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.clock_events ENABLE ROW LEVEL SECURITY;

--
-- Name: clock_events clock_events_ingest_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY clock_events_ingest_all ON public.clock_events TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: fertigation_actions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.fertigation_actions ENABLE ROW LEVEL SECURITY;

--
-- Name: fertigation_recommendations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.fertigation_recommendations ENABLE ROW LEVEL SECURITY;

--
-- Name: fertilizer_products; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.fertilizer_products ENABLE ROW LEVEL SECURITY;

--
-- Name: actuator_commands ingest_all_commands; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_all_commands ON public.actuator_commands TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: nutrient_batch_items ingest_read_batch_items; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_read_batch_items ON public.nutrient_batch_items FOR SELECT TO smile_ingest USING (true);


--
-- Name: nutrient_batches ingest_read_batches; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_read_batches ON public.nutrient_batches FOR SELECT TO smile_ingest USING (true);


--
-- Name: node_actuator_config ingest_read_config; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_read_config ON public.node_actuator_config FOR SELECT TO smile_ingest USING (true);


--
-- Name: fertilizer_products ingest_read_products; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_read_products ON public.fertilizer_products FOR SELECT TO smile_ingest USING (true);


--
-- Name: ingest_rejects; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.ingest_rejects ENABLE ROW LEVEL SECURITY;

--
-- Name: ingest_rejects ingest_rejects_ingest_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_rejects_ingest_insert ON public.ingest_rejects FOR INSERT TO smile_ingest WITH CHECK (true);


--
-- Name: fertigation_actions ingest_v8_fertigation_actions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_v8_fertigation_actions ON public.fertigation_actions TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: fertigation_recommendations ingest_v8_fertigation_recommendations; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_v8_fertigation_recommendations ON public.fertigation_recommendations TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: irrigation_actions ingest_v8_irrigation_actions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_v8_irrigation_actions ON public.irrigation_actions TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: irrigation_predictions ingest_v8_irrigation_predictions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_v8_irrigation_predictions ON public.irrigation_predictions TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: nodes ingest_v8_nodes; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY ingest_v8_nodes ON public.nodes TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: irrigation_actions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.irrigation_actions ENABLE ROW LEVEL SECURITY;

--
-- Name: irrigation_predictions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.irrigation_predictions ENABLE ROW LEVEL SECURITY;

--
-- Name: node_actuator_config; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.node_actuator_config ENABLE ROW LEVEL SECURITY;

--
-- Name: nodes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.nodes ENABLE ROW LEVEL SECURITY;

--
-- Name: nodes nodes_ingest_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY nodes_ingest_read ON public.nodes FOR SELECT TO smile_ingest USING (true);


--
-- Name: nodes nodes_ingest_touch; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY nodes_ingest_touch ON public.nodes FOR UPDATE TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: nutrient_batch_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.nutrient_batch_items ENABLE ROW LEVEL SECURITY;

--
-- Name: nutrient_batches; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.nutrient_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: nutrient_batch_items owner_batch_items; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY owner_batch_items ON public.nutrient_batch_items TO authenticated USING ((EXISTS ( SELECT 1
   FROM (public.nutrient_batches b
     JOIN public.nodes n ON ((n.id = b.node_id)))
  WHERE ((b.id = nutrient_batch_items.batch_id) AND (n.user_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (public.nutrient_batches b
     JOIN public.nodes n ON ((n.id = b.node_id)))
  WHERE ((b.id = nutrient_batch_items.batch_id) AND (n.user_id = auth.uid())))));


--
-- Name: nutrient_batches owner_batches; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY owner_batches ON public.nutrient_batches TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.nodes n
  WHERE ((n.id = nutrient_batches.node_id) AND (n.user_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.nodes n
  WHERE ((n.id = nutrient_batches.node_id) AND (n.user_id = auth.uid())))));


--
-- Name: actuator_commands owner_insert_manual_commands; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY owner_insert_manual_commands ON public.actuator_commands FOR INSERT TO authenticated WITH CHECK (((trigger = 'manual'::text) AND (EXISTS ( SELECT 1
   FROM public.nodes n
  WHERE ((n.id = actuator_commands.node_id) AND (n.user_id = auth.uid()))))));


--
-- Name: node_actuator_config owner_rw_config; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY owner_rw_config ON public.node_actuator_config TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.nodes n
  WHERE ((n.id = node_actuator_config.node_id) AND (n.user_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.nodes n
  WHERE ((n.id = node_actuator_config.node_id) AND (n.user_id = auth.uid())))));


--
-- Name: actuator_commands owner_select_commands; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY owner_select_commands ON public.actuator_commands FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.nodes n
  WHERE ((n.id = actuator_commands.node_id) AND (n.user_id = auth.uid())))));


--
-- Name: plot_soil_water_params; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.plot_soil_water_params ENABLE ROW LEVEL SECURITY;

--
-- Name: plots; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.plots ENABLE ROW LEVEL SECURITY;

--
-- Name: plots plots_ingest_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY plots_ingest_select ON public.plots FOR SELECT TO smile_ingest USING (true);


--
-- Name: plot_soil_water_params pswp_ingest_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pswp_ingest_select ON public.plot_soil_water_params FOR SELECT TO smile_ingest USING (true);


--
-- Name: plot_soil_water_params pswp_owner_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pswp_owner_insert ON public.plot_soil_water_params FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.plots p
  WHERE ((p.id = plot_soil_water_params.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: plot_soil_water_params pswp_owner_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY pswp_owner_select ON public.plot_soil_water_params FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.plots p
  WHERE ((p.id = plot_soil_water_params.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: fertilizer_products read_global_or_own_products; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY read_global_or_own_products ON public.fertilizer_products FOR SELECT TO authenticated USING (((owner_user_id IS NULL) OR (owner_user_id = auth.uid())));


--
-- Name: sensor_calibrations sc_ingest_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sc_ingest_select ON public.sensor_calibrations FOR SELECT TO smile_ingest USING (true);


--
-- Name: sensor_calibrations sc_owner_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sc_owner_insert ON public.sensor_calibrations FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.nodes n
  WHERE ((n.id = sensor_calibrations.node_id) AND (n.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: sensor_calibrations sc_owner_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sc_owner_select ON public.sensor_calibrations FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.nodes n
  WHERE ((n.id = sensor_calibrations.node_id) AND (n.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: sensor_calibrations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sensor_calibrations ENABLE ROW LEVEL SECURITY;

--
-- Name: sensor_raw_readings sensor_raw_readings_ingest_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY sensor_raw_readings_ingest_all ON public.sensor_raw_readings TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: water_balance_ledger; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.water_balance_ledger ENABLE ROW LEVEL SECURITY;

--
-- Name: water_balance_ledger wbl_ingest_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY wbl_ingest_all ON public.water_balance_ledger TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: water_balance_ledger wbl_owner_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY wbl_owner_select ON public.water_balance_ledger FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.plots p
  WHERE ((p.id = water_balance_ledger.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: weather_forecast_snapshots; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.weather_forecast_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: weather_forecasts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.weather_forecasts ENABLE ROW LEVEL SECURITY;

--
-- Name: weather_observed_hourly; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.weather_observed_hourly ENABLE ROW LEVEL SECURITY;

--
-- Name: weather_forecasts wf_ingest_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY wf_ingest_insert ON public.weather_forecasts FOR INSERT TO smile_ingest WITH CHECK (true);


--
-- Name: weather_forecasts wf_ingest_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY wf_ingest_select ON public.weather_forecasts FOR SELECT TO smile_ingest USING (true);


--
-- Name: weather_forecasts wf_ingest_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY wf_ingest_update ON public.weather_forecasts FOR UPDATE TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: weather_forecast_snapshots wfs_ingest_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY wfs_ingest_insert ON public.weather_forecast_snapshots FOR INSERT TO smile_ingest WITH CHECK (true);


--
-- Name: weather_forecast_snapshots wfs_ingest_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY wfs_ingest_select ON public.weather_forecast_snapshots FOR SELECT TO smile_ingest USING (true);


--
-- Name: weather_forecast_snapshots wfs_owner_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY wfs_owner_select ON public.weather_forecast_snapshots FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.plots p
  WHERE ((p.id = weather_forecast_snapshots.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: weather_observed_hourly woh_ingest_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY woh_ingest_all ON public.weather_observed_hourly TO smile_ingest USING (true) WITH CHECK (true);


--
-- Name: weather_observed_hourly woh_owner_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY woh_owner_select ON public.weather_observed_hourly FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.plots p
  WHERE ((p.id = weather_observed_hourly.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: fertilizer_products write_own_products; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY write_own_products ON public.fertilizer_products TO authenticated USING ((owner_user_id = auth.uid())) WITH CHECK ((owner_user_id = auth.uid()));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO smile_ingest;


--
-- Name: FUNCTION create_nutrient_batch(p_node_id uuid, p_solution_volume_l double precision, p_items jsonb, p_name text, p_measured_ec_uscm double precision, p_measured_ph double precision, p_notes text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.create_nutrient_batch(p_node_id uuid, p_solution_volume_l double precision, p_items jsonb, p_name text, p_measured_ec_uscm double precision, p_measured_ph double precision, p_notes text) TO authenticated;


--
-- Name: FUNCTION smile_calibrate(p_node uuid, p_param text, p_raw double precision, p_at timestamp with time zone); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.smile_calibrate(p_node uuid, p_param text, p_raw double precision, p_at timestamp with time zone) TO smile_ingest;


--
-- Name: FUNCTION smile_corrected_ts(ts_raw timestamp with time zone, delta_s integer, start_verified boolean, seg_start timestamp with time zone, rtc_before timestamp with time zone); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.smile_corrected_ts(ts_raw timestamp with time zone, delta_s integer, start_verified boolean, seg_start timestamp with time zone, rtc_before timestamp with time zone) TO smile_ingest;


--
-- Name: FUNCTION smile_dose_seconds(p_batch_id uuid, p_n_g double precision, p_p2o5_g double precision, p_k2o_g double precision, p_flow_ml_per_s double precision); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.smile_dose_seconds(p_batch_id uuid, p_n_g double precision, p_p2o5_g double precision, p_k2o_g double precision, p_flow_ml_per_s double precision) TO authenticated;
GRANT ALL ON FUNCTION public.smile_dose_seconds(p_batch_id uuid, p_n_g double precision, p_p2o5_g double precision, p_k2o_g double precision, p_flow_ml_per_s double precision) TO smile_ingest;


--
-- Name: FUNCTION smile_raw_for_calibrated(p_node uuid, p_param text, p_target double precision); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.smile_raw_for_calibrated(p_node uuid, p_param text, p_target double precision) TO smile_ingest;


--
-- Name: FUNCTION smile_refresh_node_thresholds(p_node uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.smile_refresh_node_thresholds(p_node uuid) FROM PUBLIC;


--
-- Name: FUNCTION smile_time_status(delta_s integer, start_verified boolean, device_flags integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.smile_time_status(delta_s integer, start_verified boolean, device_flags integer) TO smile_ingest;


--
-- Name: TABLE actuator_commands; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.actuator_commands TO authenticated;
GRANT SELECT,INSERT,UPDATE ON TABLE public.actuator_commands TO smile_ingest;


--
-- Name: TABLE clock_events; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.clock_events TO anon;
GRANT ALL ON TABLE public.clock_events TO authenticated;
GRANT SELECT,INSERT ON TABLE public.clock_events TO smile_ingest;


--
-- Name: TABLE fertigation_actions; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.fertigation_actions TO smile_ingest;


--
-- Name: TABLE nutrient_batch_concentration; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.nutrient_batch_concentration TO anon;
GRANT ALL ON TABLE public.nutrient_batch_concentration TO authenticated;
GRANT SELECT ON TABLE public.nutrient_batch_concentration TO smile_ingest;


--
-- Name: TABLE fertigation_delivered; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.fertigation_delivered TO anon;
GRANT ALL ON TABLE public.fertigation_delivered TO authenticated;
GRANT SELECT ON TABLE public.fertigation_delivered TO smile_ingest;


--
-- Name: TABLE fertigation_recommendations; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.fertigation_recommendations TO smile_ingest;


--
-- Name: COLUMN fertigation_recommendations.dispatched_command_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(dispatched_command_id) ON TABLE public.fertigation_recommendations TO smile_ingest;


--
-- Name: COLUMN fertigation_recommendations.dispatch_note; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(dispatch_note) ON TABLE public.fertigation_recommendations TO smile_ingest;


--
-- Name: COLUMN fertigation_recommendations.nutrient_batch_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(nutrient_batch_id) ON TABLE public.fertigation_recommendations TO smile_ingest;


--
-- Name: TABLE fertilizer_products; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.fertilizer_products TO authenticated;
GRANT SELECT ON TABLE public.fertilizer_products TO smile_ingest;


--
-- Name: TABLE ingest_rejects; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.ingest_rejects TO anon;
GRANT ALL ON TABLE public.ingest_rejects TO authenticated;
GRANT INSERT ON TABLE public.ingest_rejects TO smile_ingest;


--
-- Name: TABLE irrigation_actions; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.irrigation_actions TO smile_ingest;


--
-- Name: TABLE irrigation_predictions; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.irrigation_predictions TO smile_ingest;


--
-- Name: COLUMN irrigation_predictions.dispatched_command_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(dispatched_command_id) ON TABLE public.irrigation_predictions TO smile_ingest;


--
-- Name: COLUMN irrigation_predictions.dispatch_note; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(dispatch_note) ON TABLE public.irrigation_predictions TO smile_ingest;


--
-- Name: TABLE node_actuator_config; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.node_actuator_config TO authenticated;
GRANT SELECT ON TABLE public.node_actuator_config TO smile_ingest;


--
-- Name: COLUMN nodes.id; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(id) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.user_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(user_id) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.plot_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(plot_id) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.firmware_version; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(firmware_version) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.status; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(status) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.created_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(created_at) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.valve_is_on; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(valve_is_on),UPDATE(valve_is_on) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.valve_mode; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(valve_mode) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.valve_updated_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(valve_updated_at) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.pump_is_on; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(pump_is_on),UPDATE(pump_is_on) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.pump_mode; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(pump_mode) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.pump_updated_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(pump_updated_at) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.api_token_hash; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(api_token_hash) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.last_seen_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(last_seen_at) ON TABLE public.nodes TO smile_ingest;


--
-- Name: COLUMN nodes.rain_mm_per_tip; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(rain_mm_per_tip) ON TABLE public.nodes TO smile_ingest;


--
-- Name: TABLE nutrient_batch_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.nutrient_batch_items TO authenticated;
GRANT SELECT ON TABLE public.nutrient_batch_items TO smile_ingest;


--
-- Name: TABLE nutrient_batches; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.nutrient_batches TO authenticated;
GRANT SELECT ON TABLE public.nutrient_batches TO smile_ingest;


--
-- Name: TABLE plot_soil_water_params; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.plot_soil_water_params TO anon;
GRANT ALL ON TABLE public.plot_soil_water_params TO authenticated;
GRANT SELECT ON TABLE public.plot_soil_water_params TO smile_ingest;


--
-- Name: TABLE plot_water_params_current; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.plot_water_params_current TO anon;
GRANT ALL ON TABLE public.plot_water_params_current TO authenticated;
GRANT SELECT ON TABLE public.plot_water_params_current TO smile_ingest;


--
-- Name: COLUMN plots.id; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(id) ON TABLE public.plots TO smile_ingest;


--
-- Name: COLUMN plots.location_lat; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(location_lat) ON TABLE public.plots TO smile_ingest;


--
-- Name: COLUMN plots.location_lng; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(location_lng) ON TABLE public.plots TO smile_ingest;


--
-- Name: TABLE sensor_calibrations; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sensor_calibrations TO anon;
GRANT ALL ON TABLE public.sensor_calibrations TO authenticated;
GRANT SELECT ON TABLE public.sensor_calibrations TO smile_ingest;


--
-- Name: TABLE sensor_raw_readings; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.sensor_raw_readings TO smile_ingest;


--
-- Name: TABLE water_balance_ledger; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.water_balance_ledger TO anon;
GRANT ALL ON TABLE public.water_balance_ledger TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_balance_ledger TO smile_ingest;


--
-- Name: TABLE weather_forecast_snapshots; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.weather_forecast_snapshots TO authenticated;
GRANT SELECT,INSERT ON TABLE public.weather_forecast_snapshots TO smile_ingest;


--
-- Name: TABLE weather_forecasts; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.weather_forecasts TO smile_ingest;


--
-- Name: TABLE weather_observed_hourly; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.weather_observed_hourly TO authenticated;
GRANT SELECT,INSERT,UPDATE ON TABLE public.weather_observed_hourly TO smile_ingest;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;


--
-- PostgreSQL database dump complete
--

\unrestrict UhFnfirdUMWJx4x8qEsn40Y2hVKGvSf7gypVyuLCgKOuAF4AYvh5SwxieycCQVU

