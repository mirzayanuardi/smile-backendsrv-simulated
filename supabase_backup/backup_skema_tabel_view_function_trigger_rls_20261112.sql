


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."device_status" AS ENUM (
    'normal',
    'maintenance',
    'broken'
);


ALTER TYPE "public"."device_status" OWNER TO "postgres";


CREATE TYPE "public"."execution_status" AS ENUM (
    'success',
    'failed',
    'skipped',
    'overridden'
);


ALTER TYPE "public"."execution_status" OWNER TO "postgres";


CREATE TYPE "public"."fertigation_action_type" AS ENUM (
    'auto',
    'manual'
);


ALTER TYPE "public"."fertigation_action_type" OWNER TO "postgres";


CREATE TYPE "public"."fertigation_recommendation_type" AS ENUM (
    'naikkan',
    'normal',
    'tunda',
    'blokir'
);


ALTER TYPE "public"."fertigation_recommendation_type" OWNER TO "postgres";


CREATE TYPE "public"."model_status" AS ENUM (
    'reliable',
    'uncertain',
    'fallback'
);


ALTER TYPE "public"."model_status" OWNER TO "postgres";


CREATE TYPE "public"."model_type" AS ENUM (
    'random_forest',
    'xgboost',
    'persistence_baseline',
    'quantile_rf'
);


ALTER TYPE "public"."model_type" OWNER TO "postgres";


CREATE TYPE "public"."node_status" AS ENUM (
    'active',
    'retired',
    'maintenance'
);


ALTER TYPE "public"."node_status" OWNER TO "postgres";


CREATE TYPE "public"."plant_phase" AS ENUM (
    'immature',
    'early_bearing',
    'mature_bearing'
);


ALTER TYPE "public"."plant_phase" OWNER TO "postgres";


CREATE TYPE "public"."sensor_type" AS ENUM (
    '7in1',
    'rainfall'
);


ALTER TYPE "public"."sensor_type" OWNER TO "postgres";


CREATE TYPE "public"."source_type" AS ENUM (
    'BMKG',
    'NASA_POWER',
    'ERA5',
    'onsite_station',
    'open_meteo'
);


ALTER TYPE "public"."source_type" OWNER TO "postgres";


CREATE TYPE "public"."task_type" AS ENUM (
    'irrigation',
    'fertigation'
);


ALTER TYPE "public"."task_type" OWNER TO "postgres";


CREATE TYPE "public"."trigger_type" AS ENUM (
    'rule_engine',
    'manual',
    'schedule',
    'local_fallback'
);


ALTER TYPE "public"."trigger_type" OWNER TO "postgres";


CREATE TYPE "public"."valve_action_status" AS ENUM (
    'open',
    'close'
);


ALTER TYPE "public"."valve_action_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_fertigation_recommendation"("p_recommendation_id" "uuid", "p_action" "text", "p_volume_ml" double precision DEFAULT NULL::double precision, "p_reason" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    SET "lock_timeout" TO '5s'
    SET "statement_timeout" TO '20s'
    AS $$
DECLARE uid uuid:=auth.uid(); r public.fertigation_recommendations%ROWTYPE; d public.fertigation_decisions%ROWTYPE;
 c public.fertigation_config%ROWTYPE; n public.node_actuator_config%ROWTYPE; s record;
 vol double precision; target double precision; ratio double precision; dur integer; used bigint; cmd uuid; rain double precision; forecast double precision;
BEGIN
 IF uid IS NULL THEN RAISE EXCEPTION 'Harus login' USING ERRCODE='42501'; END IF;
 IF p_action IS NULL OR p_action NOT IN('approve','modify','reject') THEN RAISE EXCEPTION 'Aksi tidak valid'; END IF;
 SELECT * INTO r FROM public.fertigation_recommendations WHERE id=p_recommendation_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Rekomendasi tidak ditemukan'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.plots WHERE id=r.plot_id AND user_id=uid) THEN RAISE EXCEPTION 'Bukan pemilik petak' USING ERRCODE='42501'; END IF;
 IF r.approval_status<>'pending' OR r.dispatched_command_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.actuator_commands WHERE fertigation_recommendation_id=r.id) THEN RAISE EXCEPTION 'Sudah diputuskan/terikat command'; END IF;
 IF p_action='reject' THEN UPDATE public.fertigation_recommendations SET approval_status='rejected',approved_by=uid,approved_at=now() WHERE id=r.id; RETURN NULL; END IF;
 SELECT * INTO d FROM public.fertigation_decisions WHERE id=r.decision_id;
 SELECT * INTO c FROM public.fertigation_config WHERE id=d.config_id;
 IF c.id IS NULL OR d.origin<>'real' OR d.node_id IS DISTINCT FROM c.node_id OR d.plot_id IS DISTINCT FROM c.plot_id OR r.plot_id IS DISTINCT FROM c.plot_id
 OR d.decision_timestamp>now() OR c.valid_from>d.decision_timestamp OR d.decision_timestamp<now()-make_interval(hours=>c.recommendation_valid_hours)
 OR r.recommendation_timestamp<d.decision_timestamp OR r.recommendation_timestamp>now()
 OR r.valid_until IS NULL OR r.valid_until<=now() OR r.valid_until>d.decision_timestamp+make_interval(hours=>c.recommendation_valid_hours)
 OR d.g1_pass IS NOT TRUE OR d.g2_pass IS NOT TRUE OR (d.g3_pass IS NOT TRUE AND NOT(c.operation_mode='manual_initial' AND d.outcome='recommend_uncalibrated'))
 OR d.outcome NOT IN('recommend','recommend_uncalibrated') THEN RAISE EXCEPTION 'Keputusan/gate/TTL tidak valid'; END IF;
 IF (c.operation_mode='calibrated' AND d.outcome<>'recommend') OR c.operation_mode NOT IN('calibrated','manual_initial')
 OR NOT public.fertigation_finite(c.ec_base_uscm) OR c.ec_base_uscm<=0
 OR NOT public.fertigation_finite(c.ec_max_factor) OR c.ec_max_factor<=1
 OR NOT c.parameters_approved OR c.rain_observed_max_mm IS NULL OR c.rain_forecast_max_mm IS NULL
 OR NOT public.fertigation_finite(c.v_dasar_ml) OR NOT public.fertigation_finite(c.v_maks_ml)
 OR c.nutrient_batch_id IS NULL OR r.nutrient_batch_id IS DISTINCT FROM c.nutrient_batch_id
 OR NOT EXISTS(SELECT 1 FROM public.nutrient_batches WHERE id=c.nutrient_batch_id AND node_id=c.node_id AND is_active)
 OR NOT EXISTS(SELECT 1 FROM public.nodes WHERE id=c.node_id AND plot_id=c.plot_id AND status::text='active') THEN RAISE EXCEPTION 'Konfigurasi/batch/node belum siap'; END IF;
 SELECT * INTO n FROM public.node_actuator_config WHERE node_id=c.node_id FOR UPDATE;
 IF NOT FOUND OR NOT n.has_fertigation OR NOT public.fertigation_finite(n.dose_flow_ml_per_s) OR n.dose_flow_ml_per_s<=0 THEN RAISE EXCEPTION 'Pompa tidak siap'; END IF;
 SELECT * INTO s FROM public.fertigation_ec_adj_config(c.id,now());
 rain:=public.fertigation_rain_config(c.id,now(),false); forecast:=public.fertigation_rain_config(c.id,now(),true);
 IF s.theta_valid IS NOT TRUE OR rain IS NULL OR forecast IS NULL OR rain>c.rain_observed_max_mm OR forecast>c.rain_forecast_max_mm THEN RAISE EXCEPTION 'Sensor/hujan terkini tidak lolos'; END IF;
 IF d.decision_source IS DISTINCT FROM c.decision_source OR r.decision_source IS DISTINCT FROM d.decision_source THEN RAISE EXCEPTION 'Sumber keputusan tidak cocok'; END IF;
 IF c.operation_mode='manual_initial' THEN
 IF c.decision_source<>'rule' OR d.outcome<>'recommend_uncalibrated' THEN RAISE EXCEPTION 'Mode uji manual eksplisit diperlukan'; END IF;
 target:=least(c.v_dasar_ml,c.v_maks_ml);
 ELSE
 IF NOT public.fertigation_finite(c.k_ec_per_ml) OR c.k_ec_per_ml<=0 THEN RAISE EXCEPTION 'k wajib terkalibrasi'; END IF;
 IF c.decision_source='rf' THEN
 IF r.model_id IS NULL OR d.model_id IS DISTINCT FROM r.model_id OR NOT public.fertigation_rf_is_eligible(d.model_id)
 OR NOT EXISTS(SELECT 1 FROM public.model_registries WHERE id=d.model_id AND is_active)
 OR NOT public.fertigation_finite(d.r_rf) OR NOT public.fertigation_finite(d.rf_spread)
 OR c.rf_spread_max IS NULL OR d.rf_spread<0 OR d.rf_spread>c.rf_spread_max THEN RAISE EXCEPTION 'RF tidak layak'; END IF;
 ratio:=d.r_rf;
 ELSE ratio:=(c.ec_base_uscm+c.k_ec_per_ml*c.v_dasar_ml-s.ec_adj_uscm)/(c.k_ec_per_ml*c.v_dasar_ml); END IF;
 IF NOT public.fertigation_finite(ratio) OR ratio<c.r_min THEN RAISE EXCEPTION 'Tidak perlu dosis'; END IF;
 target:=least(least(ratio,c.r_max)*c.v_dasar_ml,c.v_maks_ml);
 END IF;
 IF p_action='modify' AND (NOT public.fertigation_finite(p_volume_ml) OR nullif(trim(p_reason),'') IS NULL) THEN RAISE EXCEPTION 'Modifikasi butuh volume dan alasan'; END IF;
 vol:=CASE WHEN p_action='approve' THEN r.volume_pump_ml ELSE p_volume_ml END;
 IF NOT public.fertigation_finite(vol) OR vol<=0 OR vol>least(c.r_max*c.v_dasar_ml,c.v_maks_ml)
 OR (p_action='approve' AND abs(vol-target)>0.000001) THEN RAISE EXCEPTION 'Volume tidak sesuai rumus/batas'; END IF;
 IF c.operation_mode<>'manual_initial' AND s.ec_adj_uscm+c.k_ec_per_ml*vol>c.ec_base_uscm+c.ec_max_factor*c.k_ec_per_ml*c.v_dasar_ml THEN RAISE EXCEPTION 'G3 prediksi EC maksimum'; END IF;
 dur:=floor(vol/n.dose_flow_ml_per_s)::integer;
 IF dur<1 OR dur>n.max_run_s THEN RAISE EXCEPTION 'Durasi tidak aman'; END IF;
 -- Semua status dicadangkan konservatif; actual tidak boleh mengurangi reservasi.
 SELECT coalesce(sum(greatest(coalesce(dose_s,0),coalesce(actual_dose_s,0))),0) INTO used FROM public.actuator_commands
 WHERE node_id=c.node_id AND command='fertigate' AND (created_at>=(date_trunc('day',now() AT TIME ZONE 'Asia/Jakarta') AT TIME ZONE 'Asia/Jakarta')
 OR greatest(started_at,finished_at)>=(date_trunc('day',now() AT TIME ZONE 'Asia/Jakarta') AT TIME ZONE 'Asia/Jakarta') OR status IN('pending','sent','running'));
 IF used+dur>n.max_dose_day_s THEN RAISE EXCEPTION 'Kuota harian habis'; END IF;
 IF EXISTS(SELECT 1 FROM public.actuator_commands WHERE node_id=c.node_id AND command='fertigate'
 AND (status IN('pending','sent','running') OR greatest(created_at,started_at,finished_at)+make_interval(secs=>coalesce(dose_s,0)+n.min_gap_s)>now())) THEN RAISE EXCEPTION 'Jeda minimum/busy'; END IF;
 INSERT INTO public.actuator_commands(node_id,plot_id,command,dose_s,trigger,fertigation_recommendation_id,reason,nutrient_batch_id,status,created_by,expires_at)
 VALUES(c.node_id,c.plot_id,'fertigate',dur,'manual',r.id,coalesce(p_reason,'Disetujui petani'),c.nutrient_batch_id,'pending',uid,least(r.valid_until,now()+interval '10 minutes')) RETURNING id INTO cmd;
 UPDATE public.fertigation_recommendations SET approval_status=CASE WHEN p_action='modify' THEN 'modified' ELSE 'approved' END,
 approved_by=uid,approved_at=now(),approved_volume_ml=dur*n.dose_flow_ml_per_s,dispatched_command_id=cmd,
 modification_reason=CASE WHEN p_action='modify' THEN p_reason END,dispatch_note=format('Durasi %s s; volume nominal %s mL; permintaan %s mL',dur,dur*n.dose_flow_ml_per_s,vol) WHERE id=r.id;
 RETURN cmd;
END $$;


ALTER FUNCTION "public"."approve_fertigation_recommendation"("p_recommendation_id" "uuid", "p_action" "text", "p_volume_ml" double precision, "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_nutrient_batch"("p_node_id" "uuid", "p_solution_volume_l" double precision, "p_items" "jsonb", "p_name" "text" DEFAULT NULL::"text", "p_measured_ec_uscm" double precision DEFAULT NULL::double precision, "p_measured_ph" double precision DEFAULT NULL::double precision, "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."create_nutrient_batch"("p_node_id" "uuid", "p_solution_volume_l" double precision, "p_items" "jsonb", "p_name" "text", "p_measured_ec_uscm" double precision, "p_measured_ph" double precision, "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_actions_fill_plot_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
    IF NEW.plot_id IS NULL AND NEW.recommendation_id IS NOT NULL THEN
        SELECT fr.plot_id INTO NEW.plot_id
        FROM public.fertigation_recommendations fr
        WHERE fr.id = NEW.recommendation_id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fertigation_actions_fill_plot_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_command_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
BEGIN
 IF (TG_OP<>'INSERT' AND OLD.command='fertigate') OR (TG_OP<>'DELETE' AND NEW.command='fertigate') THEN
 IF current_user IN('authenticated','anon') THEN RAISE EXCEPTION 'Fertigasi wajib melalui RPC/backend' USING ERRCODE='42501'; END IF;
 IF TG_OP='DELETE' AND OLD.fertigation_recommendation_id IS NOT NULL THEN RAISE EXCEPTION 'Command terikat tidak boleh dihapus'; END IF;
 IF TG_OP='UPDATE' AND OLD.fertigation_recommendation_id IS NOT NULL AND
 (NEW.fertigation_recommendation_id IS DISTINCT FROM OLD.fertigation_recommendation_id OR NEW.node_id IS DISTINCT FROM OLD.node_id
 OR NEW.plot_id IS DISTINCT FROM OLD.plot_id OR NEW.dose_s IS DISTINCT FROM OLD.dose_s
 OR NEW.command IS DISTINCT FROM OLD.command OR NEW.nutrient_batch_id IS DISTINCT FROM OLD.nutrient_batch_id
 OR (OLD.status NOT IN('pending','sent','running') AND NEW.status IN('pending','sent','running'))) THEN RAISE EXCEPTION 'Binding command final; tidak boleh redispatch'; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;


ALTER FUNCTION "public"."fertigation_command_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_config_validate"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE n public.node_actuator_config%ROWTYPE; v record;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Konfigurasi immutable; buat versi baru'; END IF;
 FOR v IN SELECT value FROM jsonb_each(to_jsonb(NEW)) WHERE value::text IN ('"NaN"','"Infinity"','"-Infinity"') LOOP
  RAISE EXCEPTION 'Konfigurasi harus finite';
 END LOOP;
 IF NEW.operation_mode NOT IN ('calibrated','manual_initial') OR NEW.r_min<>0.7 OR NEW.r_max<>1.3
 OR NEW.sensor_min_readings<2 OR NEW.sensor_max_gap_min<1 OR NEW.sensor_max_gap_min>NEW.ec_window_min
 OR NEW.forecast_max_age_hours<1 OR NEW.theta_ref_pct NOT BETWEEN NEW.theta_valid_min_pct AND NEW.theta_valid_max_pct
 OR NEW.theta_valid_min_pct<58 OR NEW.theta_valid_max_pct>63
 OR NEW.rain_observed_max_mm<0 OR NEW.rain_forecast_max_mm<0 THEN RAISE EXCEPTION 'Parameter konfigurasi tidak valid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.nodes WHERE id=NEW.node_id AND plot_id=NEW.plot_id AND status::text='active') THEN
  RAISE EXCEPTION 'Node tidak aktif atau bukan milik petak'; END IF;
 SELECT * INTO n FROM public.node_actuator_config WHERE node_id=NEW.node_id;
 IF NOT FOUND OR NOT n.has_fertigation OR NOT public.fertigation_finite(n.dose_flow_ml_per_s) OR n.dose_flow_ml_per_s<=0 THEN
  RAISE EXCEPTION 'Kalibrasi pompa fertigasi wajib'; END IF;
 IF NEW.v_maks_ml>n.dose_flow_ml_per_s*least(n.max_run_s,n.max_dose_day_s) THEN RAISE EXCEPTION 'V_maks melebihi kapasitas'; END IF;
 IF NEW.nutrient_batch_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.nutrient_batches WHERE id=NEW.nutrient_batch_id AND node_id=NEW.node_id AND is_active) THEN
  RAISE EXCEPTION 'Batch tidak cocok/aktif'; END IF;
 RETURN NEW;
END $$;


ALTER FUNCTION "public"."fertigation_config_validate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_ec_adj"("p_plot_id" "uuid", "p_at" timestamp with time zone DEFAULT "now"()) RETURNS TABLE("config_id" "uuid", "window_start" timestamp with time zone, "window_end" timestamp with time zone, "n_readings" integer, "ec25_uscm" double precision, "theta_pct" double precision, "soil_temperature_c" double precision, "ec_adj_uscm" double precision, "theta_valid" boolean)
    LANGUAGE "sql" STABLE
    AS $$ SELECT x.* FROM public.fertigation_config c
 CROSS JOIN LATERAL public.fertigation_ec_adj_config(c.id,p_at) x
 WHERE c.id=(SELECT id FROM public.fertigation_config WHERE plot_id=p_plot_id AND valid_from<=p_at ORDER BY valid_from DESC,created_at DESC,id DESC LIMIT 1) $$;


ALTER FUNCTION "public"."fertigation_ec_adj"("p_plot_id" "uuid", "p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_ec_adj_config"("p_config_id" "uuid", "p_at" timestamp with time zone) RETURNS TABLE("config_id" "uuid", "window_start" timestamp with time zone, "window_end" timestamp with time zone, "n_readings" integer, "ec25_uscm" double precision, "theta_pct" double precision, "soil_temperature_c" double precision, "ec_adj_uscm" double precision, "theta_valid" boolean)
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
 WITH cfg AS(SELECT * FROM public.fertigation_config WHERE id=p_config_id),
 w AS(SELECT r.*,lag(r.reading_timestamp) OVER(ORDER BY r.reading_timestamp) AS prev
 FROM public.calibrated_sensor_raw_readings r CROSS JOIN cfg
 LEFT JOIN public.sensor_raw_readings raw ON raw.id=r.raw_reading_id
 WHERE r.plot_id=cfg.plot_id AND r.node_id=cfg.node_id
 AND r.reading_timestamp>p_at-make_interval(mins=>cfg.ec_window_min) AND r.reading_timestamp<=p_at
 AND public.fertigation_finite(r.soil_ec_uscm) AND r.soil_ec_uscm>=0
 AND public.fertigation_finite(r.soil_moisture_pct) AND r.soil_moisture_pct BETWEEN cfg.theta_valid_min_pct AND cfg.theta_valid_max_pct
 AND public.fertigation_finite(r.soil_temperature_c)
 AND (cfg.flag_exclude_regex IS NULL OR coalesce(r.quality_flag,'')!~cfg.flag_exclude_regex)
 AND coalesce(r.quality_flag,'') !~* 'unverified|maintenance|sensor_down'
 AND raw.time_status IN('verified','corrected_constant','corrected_linear')
 AND raw.node_id=cfg.node_id AND raw.plot_id=cfg.plot_id AND raw.reading_timestamp=r.reading_timestamp),
 a AS(SELECT count(DISTINCT reading_timestamp)::integer n,min(reading_timestamp) first_t,max(reading_timestamp) last_t,
 max(reading_timestamp-prev) gap,
 percentile_cont(0.5) WITHIN GROUP(ORDER BY soil_ec_uscm) ec,
 percentile_cont(0.5) WITHIN GROUP(ORDER BY soil_moisture_pct) th,avg(soil_temperature_c) temp,
 percentile_cont(0.5) WITHIN GROUP(ORDER BY soil_ec_uscm-cfg.s_ec_per_theta*(soil_moisture_pct-cfg.theta_ref_pct)) adj
 FROM w CROSS JOIN cfg)
 SELECT cfg.id,p_at-make_interval(mins=>cfg.ec_window_min),p_at,a.n,a.ec,a.th,a.temp,a.adj,
 coalesce(a.n>=cfg.sensor_min_readings AND a.first_t<=p_at-make_interval(mins=>cfg.ec_window_min-cfg.sensor_max_gap_min)
 AND a.last_t>=p_at-make_interval(mins=>cfg.sensor_max_gap_min)
 AND a.gap<=make_interval(mins=>cfg.sensor_max_gap_min),false) FROM cfg CROSS JOIN a
$$;


ALTER FUNCTION "public"."fertigation_ec_adj_config"("p_config_id" "uuid", "p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_expire_recommendations"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$ DECLARE n integer; BEGIN
 UPDATE public.fertigation_recommendations SET approval_status='expired' WHERE approval_status='pending' AND valid_until<=now();
 GET DIAGNOSTICS n=ROW_COUNT; RETURN n; END $$;


ALTER FUNCTION "public"."fertigation_expire_recommendations"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_finite"("x" double precision) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$ SELECT coalesce(x > '-Infinity'::float8 AND x < 'Infinity'::float8,false) $$;


ALTER FUNCTION "public"."fertigation_finite"("x" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_input_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$ DECLARE v record; BEGIN
 FOR v IN SELECT value FROM jsonb_each(to_jsonb(NEW)) WHERE value::text IN ('"NaN"','"Infinity"','"-Infinity"') LOOP RAISE EXCEPTION 'Masukan fertigasi harus finite'; END LOOP;
 IF TG_TABLE_NAME='fertigation_decisions' THEN
 IF NEW.origin NOT IN('real','synthetic') THEN RAISE EXCEPTION 'Origin wajib real/synthetic'; END IF;
 ELSIF NEW.decision_source='rf' AND NEW.model_id IS NULL THEN RAISE EXCEPTION 'Rekomendasi RF wajib model_id'; END IF;
 RETURN NEW;
END $$;


ALTER FUNCTION "public"."fertigation_input_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_rain_24h"("p_plot_id" "uuid", "p_at" timestamp with time zone DEFAULT "now"()) RETURNS double precision
    LANGUAGE "sql" STABLE
    AS $$
 SELECT public.fertigation_rain_config(id,p_at,false) FROM public.fertigation_config WHERE plot_id=p_plot_id AND valid_from<=p_at ORDER BY valid_from DESC,created_at DESC,id DESC LIMIT 1 $$;


ALTER FUNCTION "public"."fertigation_rain_24h"("p_plot_id" "uuid", "p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_rain_config"("p_config" "uuid", "p_at" timestamp with time zone, "p_forecast" boolean) RETURNS double precision
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE c public.fertigation_config%ROWTYPE; v double precision; issued timestamptz; n integer;
BEGIN
 SELECT * INTO c FROM public.fertigation_config WHERE id=p_config;
 IF p_forecast THEN
 SELECT max(issued_at) INTO issued FROM public.weather_forecast_snapshots WHERE plot_id=c.plot_id
 AND source=c.weather_source AND model=c.weather_model AND issued_at<=p_at;
 IF issued IS NULL OR issued<p_at-make_interval(hours=>c.forecast_max_age_hours) THEN RETURN NULL; END IF;
 SELECT count(*),sum(precipitation_mm) INTO n,v FROM public.weather_forecast_snapshots
 WHERE plot_id=c.plot_id AND source=c.weather_source AND model=c.weather_model AND issued_at=issued
 AND valid_time IN(SELECT date_trunc('hour',p_at)+i*interval '1 hour' FROM generate_series(1,12)i);
 IF n<>12 OR EXISTS(SELECT 1 FROM public.weather_forecast_snapshots WHERE plot_id=c.plot_id AND source=c.weather_source AND model=c.weather_model AND issued_at=issued
 AND valid_time IN(SELECT date_trunc('hour',p_at)+i*interval '1 hour' FROM generate_series(1,12)i)
 GROUP BY valid_time HAVING count(*)<>1 OR bool_and(public.fertigation_finite(precipitation_mm) AND precipitation_mm>=0) IS NOT TRUE) THEN RETURN NULL; END IF;
 ELSE
 SELECT count(*),sum(precipitation_mm) INTO n,v FROM public.weather_observed_hourly WHERE plot_id=c.plot_id AND source=c.observed_source
 AND time IN(SELECT date_trunc('hour',p_at)-i*interval '1 hour' FROM generate_series(0,23)i);
 IF n<>24 OR EXISTS(SELECT 1 FROM public.weather_observed_hourly WHERE plot_id=c.plot_id AND source=c.observed_source
 AND time IN(SELECT date_trunc('hour',p_at)-i*interval '1 hour' FROM generate_series(0,23)i)
 GROUP BY time HAVING count(*)<>1 OR bool_and(public.fertigation_finite(precipitation_mm) AND precipitation_mm>=0) IS NOT TRUE) THEN RETURN NULL; END IF;
 END IF;
 RETURN v;
END $$;


ALTER FUNCTION "public"."fertigation_rain_config"("p_config" "uuid", "p_at" timestamp with time zone, "p_forecast" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_rain_forecast_12h"("p_plot_id" "uuid", "p_at" timestamp with time zone DEFAULT "now"()) RETURNS double precision
    LANGUAGE "sql" STABLE
    AS $$
 SELECT public.fertigation_rain_config(id,p_at,true) FROM public.fertigation_config WHERE plot_id=p_plot_id AND valid_from<=p_at ORDER BY valid_from DESC,created_at DESC,id DESC LIMIT 1 $$;


ALTER FUNCTION "public"."fertigation_rain_forecast_12h"("p_plot_id" "uuid", "p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_record_response"("p_action_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE a public.fertigation_actions%ROWTYPE; c public.fertigation_config%ROWTYPE; r public.fertigation_recommendations%ROWTYPE;
 d public.fertigation_decisions%ROWTYPE; b record; f record; v uuid; rain double precision;
BEGIN
 SELECT id INTO v FROM public.fertigation_dose_responses WHERE fertigation_action_id=p_action_id;
 IF FOUND THEN RETURN v; END IF;
 SELECT * INTO a FROM public.fertigation_actions WHERE id=p_action_id FOR UPDATE;
 IF NOT FOUND OR NOT public.fertigation_finite(a.actual_volume) OR a.actual_volume<=0 OR a.execution_timestamp+interval '24 hours'>now() THEN RAISE EXCEPTION 'Aksi/volume/waktu respons belum valid'; END IF;
 SELECT id INTO v FROM public.fertigation_dose_responses WHERE fertigation_action_id=p_action_id;
 IF FOUND THEN RETURN v; END IF;
 SELECT * INTO r FROM public.fertigation_recommendations WHERE id=a.recommendation_id;
 SELECT * INTO d FROM public.fertigation_decisions WHERE id=r.decision_id;
 SELECT * INTO c FROM public.fertigation_config WHERE id=d.config_id;
 IF c.id IS NULL OR d.origin<>'real' OR NOT public.fertigation_finite(a.actual_duration_sec) OR a.actual_duration_sec<=0
 OR a.pump_action IS DISTINCT FROM 'off' OR NOT EXISTS(SELECT 1 FROM public.actuator_commands ac WHERE ac.id=a.command_id
 AND ac.status IN('executed','stopped','interrupted') AND ac.actual_dose_s>0 AND ac.node_id=c.node_id AND ac.plot_id=c.plot_id
 AND ac.fertigation_recommendation_id=r.id AND ac.nutrient_batch_id=c.nutrient_batch_id)
 OR a.node_id IS DISTINCT FROM c.node_id OR a.plot_id IS DISTINCT FROM c.plot_id
 OR a.command_id IS DISTINCT FROM r.dispatched_command_id OR a.command_id IS NULL
 OR a.nutrient_batch_id IS DISTINCT FROM c.nutrient_batch_id THEN RAISE EXCEPTION 'Provenance aksi tidak cocok'; END IF;
 SELECT * INTO b FROM public.fertigation_ec_adj_config(c.id,a.execution_timestamp);
 SELECT * INTO f FROM public.fertigation_ec_adj_config(c.id,a.execution_timestamp+interval '24 hours');
 rain:=public.fertigation_rain_config(c.id,a.execution_timestamp+interval '24 hours',false);
 IF b.theta_valid IS NOT TRUE OR f.theta_valid IS NOT TRUE OR rain IS NULL THEN RAISE EXCEPTION 'Sensor/hujan respons tidak lengkap'; END IF;
 INSERT INTO public.fertigation_dose_responses(plot_id,fertigation_action_id,recommendation_id,config_id,dose_timestamp,v_actual_ml,theta_ref_pct,
 ec_adj_before,theta_before_pct,measure_timestamp,ec_adj_after_24h,theta_after_pct,quality_pass,used_for_training)
 VALUES(c.plot_id,a.id,r.id,c.id,a.execution_timestamp,a.actual_volume,c.theta_ref_pct,b.ec_adj_uscm,b.theta_pct,
 a.execution_timestamp+interval '24 hours',f.ec_adj_uscm,f.theta_pct,rain<=c.rain_observed_max_mm,false) RETURNING id INTO v;
 RETURN v;
END $$;


ALTER FUNCTION "public"."fertigation_record_response"("p_action_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_response_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE v record;
BEGIN
 IF TG_OP='UPDATE' AND OLD.reviewed_by IS NOT NULL THEN RAISE EXCEPTION 'Snapshot sudah direview; tidak boleh ditimpa'; END IF;
 FOR v IN SELECT value FROM jsonb_each(to_jsonb(NEW)) WHERE value::text IN ('"NaN"','"Infinity"','"-Infinity"') LOOP RAISE EXCEPTION 'Respons harus finite'; END LOOP;
 IF NEW.used_for_training AND (NEW.reviewed_by IS NULL OR NEW.reviewed_at IS NULL OR nullif(trim(NEW.review_note),'') IS NULL OR NOT NEW.quality_pass
 OR NEW.config_id IS NULL OR NEW.fertigation_action_id IS NULL OR NEW.measure_timestamp IS NULL
 OR abs(extract(epoch FROM NEW.measure_timestamp-NEW.dose_timestamp)-86400)>3600
 OR NEW.ec_adj_before IS NULL OR NEW.ec_adj_after_24h IS NULL OR NEW.ec_adj_after_24h-NEW.ec_adj_before<=5*NEW.noise_5min_uscm
 OR NEW.theta_before_pct IS NULL OR NEW.theta_after_pct IS NULL OR NEW.theta_ref_pct IS NULL
 OR abs(NEW.theta_before_pct-NEW.theta_ref_pct)>1 OR abs(NEW.theta_after_pct-NEW.theta_ref_pct)>1) THEN RAISE EXCEPTION 'Respons belum layak latih/review'; END IF;
 RETURN NEW;
END $$;


ALTER FUNCTION "public"."fertigation_response_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_rf_is_eligible"("p_model_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  SELECT COALESCE(
    (SELECT (e.eligible AND coalesce(e.n_scenarios>0,false))
           FROM public.fertigation_rf_evaluations e
          WHERE e.model_id = p_model_id AND e.evaluated_at <= now()
      ORDER BY e.evaluated_at DESC,e.created_at DESC,e.id DESC
      LIMIT 1), false);
$$;


ALTER FUNCTION "public"."fertigation_rf_is_eligible"("p_model_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fertigation_stock_conc_g_per_l"("p_batch_id" "uuid") RETURNS double precision
    LANGUAGE "sql" STABLE
    AS $$
 SELECT CASE WHEN public.fertigation_finite(b.solution_volume_l) AND b.solution_volume_l>0 AND count(i.id)>0
 AND bool_and(CASE WHEN i.amount_g IS NOT NULL AND i.amount_ml IS NULL THEN public.fertigation_finite(i.amount_g) AND i.amount_g>0
 WHEN i.amount_g IS NULL AND i.amount_ml IS NOT NULL THEN public.fertigation_finite(i.amount_ml) AND i.amount_ml>0 AND p.form='liquid' AND p.is_verified AND public.fertigation_finite(p.density_g_per_ml) AND p.density_g_per_ml>0 ELSE false END)
 THEN sum(CASE WHEN i.amount_g IS NOT NULL THEN i.amount_g ELSE i.amount_ml*p.density_g_per_ml END)/b.solution_volume_l END
 FROM public.nutrient_batches b LEFT JOIN public.nutrient_batch_items i ON i.batch_id=b.id
 LEFT JOIN public.fertilizer_products p ON p.id=i.product_id WHERE b.id=p_batch_id GROUP BY b.id
$$;


ALTER FUNCTION "public"."fertigation_stock_conc_g_per_l"("p_batch_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."fertigation_stock_conc_g_per_l"("p_batch_id" "uuid") IS 'Massa produk total g/L, bukan massa unsur NPK. Semua item wajib dapat dikonversi tanpa penjumlahan parsial.';



CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  insert into public.profiles (id, full_name, email, avatar_url, created_at, updated_at)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    new.email,
    coalesce(new.raw_user_meta_data->>'avatar_url', 'https://cdn-icons-png.flaticon.com/512/149/149071.png'),
    now(),
    now()
  )
  on conflict (id) do update set
    full_name = excluded.full_name,
    email = excluded.email,
    updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_activate_nutrient_batch"() RETURNS "trigger"
    LANGUAGE "plpgsql"
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


ALTER FUNCTION "public"."smile_activate_nutrient_batch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_bump_config_version"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if row(new.*) is distinct from row(old.*) then
    new.config_version := old.config_version + 1;
    new.updated_at := now();
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."smile_bump_config_version"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_cal_rainfall_mm"("p_tips" bigint) RETURNS double precision
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    AS $$
  select case when p_tips is null then null else 0.2891 * p_tips end
$$;


ALTER FUNCTION "public"."smile_cal_rainfall_mm"("p_tips" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_cal_soil_ec"("p_ec_raw" double precision, "p_temp_c" double precision) RETURNS double precision
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    AS $$
  select case when p_ec_raw is null or p_temp_c is null then null
              when 1 + 0.01987 * (p_temp_c - 25) <= 0 then null
              else greatest(0, -16.53 + 1.0213 * p_ec_raw / (1 + 0.01987 * (p_temp_c - 25)))
         end
$$;


ALTER FUNCTION "public"."smile_cal_soil_ec"("p_ec_raw" double precision, "p_temp_c" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_cal_soil_moisture"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) RETURNS double precision
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select case when p_raw is null then null
              else coalesce(public.smile_calibrate(p_node, 'soil_moisture', p_raw, p_at),
                            13.279 + 0.5814 * p_raw)
         end
$$;


ALTER FUNCTION "public"."smile_cal_soil_moisture"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_cal_soil_temperature"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) RETURNS double precision
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select case when p_raw is null then null
              else coalesce(public.smile_calibrate(p_node, 'soil_temperature', p_raw, p_at),
                            p_raw)
         end
$$;


ALTER FUNCTION "public"."smile_cal_soil_temperature"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_calibrate"("p_node" "uuid", "p_param" "text", "p_raw" double precision, "p_at" timestamp with time zone DEFAULT "now"()) RETURNS double precision
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select public.smile_poly(c.coeffs, p_raw)
  from public.sensor_calibrations c
  where c.node_id = p_node and c.parameter = p_param and c.valid_from <= p_at
  order by c.valid_from desc
  limit 1
$$;


ALTER FUNCTION "public"."smile_calibrate"("p_node" "uuid", "p_param" "text", "p_raw" double precision, "p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_corrected_ts"("ts_raw" timestamp with time zone, "delta_s" integer, "start_verified" boolean, "seg_start" timestamp with time zone, "rtc_before" timestamp with time zone) RETURNS timestamp with time zone
    LANGUAGE "sql" IMMUTABLE
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


ALTER FUNCTION "public"."smile_corrected_ts"("ts_raw" timestamp with time zone, "delta_s" integer, "start_verified" boolean, "seg_start" timestamp with time zone, "rtc_before" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_dose_seconds"("p_batch_id" "uuid", "p_n_g" double precision, "p_p2o5_g" double precision, "p_k2o_g" double precision, "p_flow_ml_per_s" double precision) RETURNS integer
    LANGUAGE "sql" STABLE
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


ALTER FUNCTION "public"."smile_dose_seconds"("p_batch_id" "uuid", "p_n_g" double precision, "p_p2o5_g" double precision, "p_k2o_g" double precision, "p_flow_ml_per_s" double precision) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."smile_dose_seconds"("p_batch_id" "uuid", "p_n_g" double precision, "p_p2o5_g" double precision, "p_k2o_g" double precision, "p_flow_ml_per_s" double precision) IS 'detik = gram_hara / (konsentrasi g/mL x debit mL/s); diambil yang terkecil antar-unsur. NULL kalau tidak bisa dihitung.';



CREATE OR REPLACE FUNCTION "public"."smile_guard_actuator_command"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."smile_guard_actuator_command"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_guard_batch_item"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."smile_guard_batch_item"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_guard_fertilizer_product"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if auth.uid() is not null then          -- request dari pengguna app (bukan SQL Editor / server)
    new.owner_user_id := auth.uid();
    new.is_verified   := false;
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."smile_guard_fertilizer_product"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_poly"("p_coeffs" double precision[], "p_x" double precision) RETURNS double precision
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    AS $$
  select sum(c * power(p_x, i - 1))
  from unnest(p_coeffs) with ordinality as t(c, i)
$$;


ALTER FUNCTION "public"."smile_poly"("p_coeffs" double precision[], "p_x" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_raw_for_calibrated"("p_node" "uuid", "p_param" "text", "p_target" double precision) RETURNS double precision
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."smile_raw_for_calibrated"("p_node" "uuid", "p_param" "text", "p_target" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_recalibrate_readings"("p_node" "uuid" DEFAULT NULL::"uuid", "p_from" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  n bigint;
begin
  insert into public.calibrated_sensor_raw_readings (
    raw_reading_id, reading_timestamp, node_id, plot_id, quality_flag,
    soil_moisture_pct, soil_temperature_c, soil_ec_uscm,
    rainfall_tip_count, rainfall_mm,
    soil_ph, soil_n_mgkg, soil_p_mgkg, soil_k_mgkg,
    air_temperature_c, air_humidity_pct, calibrated_at)
  select
    r.id, r.reading_timestamp, r.node_id, r.plot_id, r.quality_flag,
    public.smile_cal_soil_moisture(r.node_id, r.soil_moisture_pct,
      coalesce(r.reading_timestamp, r.ingested_at)),
    public.smile_cal_soil_temperature(r.node_id, r.soil_temperature_c,
      coalesce(r.reading_timestamp, r.ingested_at)),
    public.smile_cal_soil_ec(r.soil_ec_uscm, r.soil_temperature_c),
    r.rainfall_tip_count,
    public.smile_cal_rainfall_mm(r.rainfall_tip_count),
    r.soil_ph, r.soil_n_mgkg, r.soil_p_mgkg, r.soil_k_mgkg,
    r.air_temperature_c, r.air_humidity_pct, now()
  from public.sensor_raw_readings r
  where (p_node is null or r.node_id = p_node)
    and (p_from is null or coalesce(r.reading_timestamp, r.ingested_at) >= p_from)
  on conflict (raw_reading_id) do update set
    reading_timestamp  = excluded.reading_timestamp,
    node_id            = excluded.node_id,
    plot_id            = excluded.plot_id,
    quality_flag       = excluded.quality_flag,
    soil_moisture_pct  = excluded.soil_moisture_pct,
    soil_temperature_c = excluded.soil_temperature_c,
    soil_ec_uscm       = excluded.soil_ec_uscm,
    rainfall_tip_count = excluded.rainfall_tip_count,
    rainfall_mm        = excluded.rainfall_mm,
    soil_ph            = excluded.soil_ph,
    soil_n_mgkg        = excluded.soil_n_mgkg,
    soil_p_mgkg        = excluded.soil_p_mgkg,
    soil_k_mgkg        = excluded.soil_k_mgkg,
    air_temperature_c  = excluded.air_temperature_c,
    air_humidity_pct   = excluded.air_humidity_pct,
    calibrated_at      = excluded.calibrated_at;
  get diagnostics n = row_count;
  return n;
end $$;


ALTER FUNCTION "public"."smile_recalibrate_readings"("p_node" "uuid", "p_from" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_refresh_node_thresholds"("p_node" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."smile_refresh_node_thresholds"("p_node" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_time_status"("delta_s" integer, "start_verified" boolean, "device_flags" integer) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when delta_s is null then
      case when (coalesce(device_flags, 0) & 1) = 1 then 'unverified' else 'verified' end
    when not start_verified then 'corrected_constant'
    when delta_s = 0 then 'verified'
    else 'corrected_linear'
  end
$$;


ALTER FUNCTION "public"."smile_time_status"("delta_s" integer, "start_verified" boolean, "device_flags" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_trg_calibrate_reading"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_at timestamptz := coalesce(new.reading_timestamp, new.ingested_at, now());
begin
  begin
    insert into public.calibrated_sensor_raw_readings (
      raw_reading_id, reading_timestamp, node_id, plot_id, quality_flag,
      soil_moisture_pct, soil_temperature_c, soil_ec_uscm,
      rainfall_tip_count, rainfall_mm,
      soil_ph, soil_n_mgkg, soil_p_mgkg, soil_k_mgkg,
      air_temperature_c, air_humidity_pct, calibrated_at)
    values (
      new.id, new.reading_timestamp, new.node_id, new.plot_id, new.quality_flag,
      public.smile_cal_soil_moisture(new.node_id, new.soil_moisture_pct, v_at),
      public.smile_cal_soil_temperature(new.node_id, new.soil_temperature_c, v_at),
      public.smile_cal_soil_ec(new.soil_ec_uscm, new.soil_temperature_c),
      new.rainfall_tip_count,
      public.smile_cal_rainfall_mm(new.rainfall_tip_count),
      new.soil_ph, new.soil_n_mgkg, new.soil_p_mgkg, new.soil_k_mgkg,
      new.air_temperature_c, new.air_humidity_pct, now())
    on conflict (raw_reading_id) do update set
      reading_timestamp  = excluded.reading_timestamp,
      node_id            = excluded.node_id,
      plot_id            = excluded.plot_id,
      quality_flag       = excluded.quality_flag,
      soil_moisture_pct  = excluded.soil_moisture_pct,
      soil_temperature_c = excluded.soil_temperature_c,
      soil_ec_uscm       = excluded.soil_ec_uscm,
      rainfall_tip_count = excluded.rainfall_tip_count,
      rainfall_mm        = excluded.rainfall_mm,
      soil_ph            = excluded.soil_ph,
      soil_n_mgkg        = excluded.soil_n_mgkg,
      soil_p_mgkg        = excluded.soil_p_mgkg,
      soil_k_mgkg        = excluded.soil_k_mgkg,
      air_temperature_c  = excluded.air_temperature_c,
      air_humidity_pct   = excluded.air_humidity_pct,
      calibrated_at      = excluded.calibrated_at;
  exception when others then
    -- Jangan sampai ingest data mentah gagal karena kalibrasi.
    raise warning 'smile_trg_calibrate_reading: raw id % gagal dikalibrasi: %', new.id, sqlerrm;
  end;
  return null;
end $$;


ALTER FUNCTION "public"."smile_trg_calibrate_reading"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_trg_recalibrate_from_calibration"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.parameter in ('soil_moisture', 'soil_temperature') then
    perform public.smile_recalibrate_readings(new.node_id, new.valid_from);
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."smile_trg_recalibrate_from_calibration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_trg_refresh_from_calibration"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.parameter = 'soil_moisture' then
    perform public.smile_refresh_node_thresholds(new.node_id);
  end if;
  return null;
end $$;


ALTER FUNCTION "public"."smile_trg_refresh_from_calibration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_trg_refresh_from_config"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if pg_trigger_depth() > 1 then return null; end if;   -- cegah rekursi
  perform public.smile_refresh_node_thresholds(new.node_id);
  return null;
end $$;


ALTER FUNCTION "public"."smile_trg_refresh_from_config"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smile_trg_refresh_from_params"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r record;
begin
  for r in select id from public.nodes where plot_id = new.plot_id loop
    perform public.smile_refresh_node_thresholds(r.id);
  end loop;
  return null;
end $$;


ALTER FUNCTION "public"."smile_trg_refresh_from_params"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_node_pump_state"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
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


ALTER FUNCTION "public"."sync_node_pump_state"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_node_valve_state"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
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


ALTER FUNCTION "public"."sync_node_valve_state"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."actuator_commands" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "node_id" "uuid" NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "command" "text" NOT NULL,
    "water_s" integer,
    "dose_s" integer,
    "trigger" "text" NOT NULL,
    "irrigation_prediction_id" "uuid",
    "fertigation_recommendation_id" "uuid",
    "reason" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:10:00'::interval) NOT NULL,
    "sent_at" timestamp with time zone,
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "actual_water_s" integer,
    "actual_dose_s" integer,
    "result_detail" "text",
    "nutrient_batch_id" "uuid",
    CONSTRAINT "actuator_command_shape" CHECK (((("command" = 'stop'::"text") AND ("water_s" IS NULL) AND ("dose_s" IS NULL)) OR (("command" = 'irrigate'::"text") AND (("water_s" >= 1) AND ("water_s" <= 600)) AND ("dose_s" IS NULL)) OR (("command" = 'fertigate'::"text") AND (("water_s" >= 33) AND ("water_s" <= 600)) AND (("dose_s" >= 1) AND ("dose_s" <= 300)) AND ("dose_s" <= ("water_s" - 32))))),
    CONSTRAINT "actuator_commands_command_check" CHECK (("command" = ANY (ARRAY['irrigate'::"text", 'fertigate'::"text", 'stop'::"text"]))),
    CONSTRAINT "actuator_commands_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'sent'::"text", 'running'::"text", 'executed'::"text", 'stopped'::"text", 'interrupted'::"text", 'rejected'::"text", 'expired'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "actuator_commands_trigger_check" CHECK (("trigger" = ANY (ARRAY['manual'::"text", 'rule_engine'::"text", 'schedule'::"text"])))
);


ALTER TABLE "public"."actuator_commands" OWNER TO "postgres";


COMMENT ON TABLE "public"."actuator_commands" IS 'Perintah berdurasi untuk ESP. Ditulis app (manual) atau server (rule_engine/schedule). ESP tidak pernah menerima perintah "nyala" tanpa durasi.';



CREATE TABLE IF NOT EXISTS "public"."calibrated_sensor_raw_readings" (
    "id" bigint NOT NULL,
    "reading_timestamp" timestamp with time zone DEFAULT "now"(),
    "soil_moisture_pct" double precision,
    "soil_temperature_c" double precision,
    "soil_ec_uscm" double precision,
    "soil_ph" real,
    "rainfall_tip_count" bigint,
    "rainfall_mm" double precision,
    "quality_flag" "text",
    "air_temperature_c" double precision,
    "air_humidity_pct" double precision,
    "node_id" "uuid",
    "plot_id" "uuid",
    "soil_n_mgkg" double precision,
    "soil_p_mgkg" double precision,
    "soil_k_mgkg" double precision,
    "raw_reading_id" bigint,
    "calibrated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."calibrated_sensor_raw_readings" OWNER TO "postgres";


COMMENT ON TABLE "public"."calibrated_sensor_raw_readings" IS 'This is a calibrated version of sensor_raw_readings';



COMMENT ON COLUMN "public"."calibrated_sensor_raw_readings"."raw_reading_id" IS 'id baris asal di sensor_raw_readings (diisi trigger v13). NULL = baris lama sebelum v13.';



COMMENT ON COLUMN "public"."calibrated_sensor_raw_readings"."calibrated_at" IS 'Waktu nilai terkalibrasi terakhir dihitung.';



ALTER TABLE "public"."calibrated_sensor_raw_readings" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."calibrated_sensor_raw_readings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."clock_events" (
    "id" bigint NOT NULL,
    "node_id" "uuid" NOT NULL,
    "clock_segment" "text" NOT NULL,
    "rtc_before" timestamp with time zone NOT NULL,
    "ref_time" timestamp with time zone NOT NULL,
    "delta_s" integer NOT NULL,
    "start_verified" boolean NOT NULL,
    "segment_start" timestamp with time zone,
    "ref_source" "text" NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "clock_events_ref_source_check" CHECK (("ref_source" = ANY (ARRAY['ntp'::"text", 'server'::"text"])))
);


ALTER TABLE "public"."clock_events" OWNER TO "postgres";


ALTER TABLE "public"."clock_events" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."clock_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."fertigation_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recommendation_id" "uuid",
    "execution_timestamp" timestamp with time zone NOT NULL,
    "executed_by" "public"."fertigation_action_type",
    "actual_volume" double precision,
    "actual_duration_sec" double precision,
    "execution_status" "public"."execution_status",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "plot_id" "uuid",
    "pump_action" "text",
    "node_id" "uuid",
    "command_id" "uuid",
    "device_event_id" "text",
    "clock_segment" "text",
    "execution_timestamp_raw" timestamp with time zone,
    "detail" "text",
    "nutrient_batch_id" "uuid",
    CONSTRAINT "fertigation_actions_pump_action_check" CHECK (("pump_action" = ANY (ARRAY['on'::"text", 'off'::"text"])))
);


ALTER TABLE "public"."fertigation_actions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."fertigation_actions"."nutrient_batch_id" IS 'Larutan yang benar-benar dipompa. Gram hara terkirim = actual_volume (L) x 1000 x konsentrasi batch.';



CREATE TABLE IF NOT EXISTS "public"."fertigation_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "node_id" "uuid" NOT NULL,
    "theta_ref_pct" double precision DEFAULT 59.5 NOT NULL,
    "s_ec_per_theta" double precision DEFAULT 3.10 NOT NULL,
    "theta_valid_min_pct" double precision DEFAULT 58 NOT NULL,
    "theta_valid_max_pct" double precision DEFAULT 63 NOT NULL,
    "ec_window_min" integer DEFAULT 60 NOT NULL,
    "flag_exclude_regex" "text" DEFAULT 'soil_sensor_down|time_unverified|maintenance'::"text",
    "ec_base_uscm" double precision DEFAULT 233,
    "k_ec_per_ml" double precision,
    "ec_max_factor" double precision DEFAULT 1.5 NOT NULL,
    "nutrient_batch_id" "uuid",
    "v_dasar_ml" double precision,
    "v_maks_ml" double precision,
    "r_min" double precision DEFAULT 0.7 NOT NULL,
    "r_max" double precision DEFAULT 1.3 NOT NULL,
    "decision_source" "text" DEFAULT 'rule'::"text" NOT NULL,
    "rf_spread_max" double precision,
    "rf_real_weight" double precision DEFAULT 10 NOT NULL,
    "rf_disagree_threshold" double precision DEFAULT 0.3 NOT NULL,
    "decision_hour" smallint DEFAULT 8 NOT NULL,
    "recommendation_valid_hours" integer DEFAULT 24 NOT NULL,
    "notes" "text",
    "valid_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "operation_mode" "text" DEFAULT 'calibrated'::"text" NOT NULL,
    "parameters_approved" boolean DEFAULT false NOT NULL,
    "rain_observed_max_mm" double precision,
    "rain_forecast_max_mm" double precision,
    "weather_source" "text" DEFAULT 'open_meteo'::"text" NOT NULL,
    "weather_model" "text" DEFAULT 'best_match'::"text" NOT NULL,
    "observed_source" "text" DEFAULT 'open_meteo_archive'::"text" NOT NULL,
    "sensor_min_readings" integer DEFAULT 6 NOT NULL,
    "sensor_max_gap_min" integer DEFAULT 15 NOT NULL,
    "forecast_max_age_hours" integer DEFAULT 6 NOT NULL,
    CONSTRAINT "fertigation_config_decision_hour_check" CHECK ((("decision_hour" >= 0) AND ("decision_hour" <= 23))),
    CONSTRAINT "fertigation_config_decision_source_check" CHECK (("decision_source" = ANY (ARRAY['rule'::"text", 'rf'::"text"]))),
    CONSTRAINT "fertigation_config_ec_base_uscm_check" CHECK (("ec_base_uscm" > (0)::double precision)),
    CONSTRAINT "fertigation_config_ec_max_factor_check" CHECK (("ec_max_factor" > (1)::double precision)),
    CONSTRAINT "fertigation_config_ec_window_min_check" CHECK ((("ec_window_min" >= 5) AND ("ec_window_min" <= 1440))),
    CONSTRAINT "fertigation_config_k_ec_per_ml_check" CHECK (("k_ec_per_ml" > (0)::double precision)),
    CONSTRAINT "fertigation_config_r_min_check" CHECK (("r_min" > (0)::double precision)),
    CONSTRAINT "fertigation_config_r_range" CHECK (("r_min" < "r_max")),
    CONSTRAINT "fertigation_config_recommendation_valid_hours_check" CHECK (("recommendation_valid_hours" > 0)),
    CONSTRAINT "fertigation_config_rf_disagree_threshold_check" CHECK (("rf_disagree_threshold" > (0)::double precision)),
    CONSTRAINT "fertigation_config_rf_real_weight_check" CHECK (("rf_real_weight" >= (1)::double precision)),
    CONSTRAINT "fertigation_config_rf_spread_max_check" CHECK (("rf_spread_max" > (0)::double precision)),
    CONSTRAINT "fertigation_config_s_ec_per_theta_check" CHECK (("s_ec_per_theta" > (0)::double precision)),
    CONSTRAINT "fertigation_config_theta_range" CHECK (("theta_valid_min_pct" < "theta_valid_max_pct")),
    CONSTRAINT "fertigation_config_v_dasar_ml_check" CHECK (("v_dasar_ml" > (0)::double precision)),
    CONSTRAINT "fertigation_config_v_maks_ml_check" CHECK (("v_maks_ml" > (0)::double precision))
);


ALTER TABLE "public"."fertigation_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."fertigation_config" IS 'Konfigurasi fertigasi per petak (berversi lewat valid_from). decision_source=rule berarti aturan fisika yang memutuskan; ubah ke rf hanya setelah kriteria kelayakan RF 1-3 lolos (fertigation_rf_evaluations).';



COMMENT ON COLUMN "public"."fertigation_config"."flag_exclude_regex" IS 'Baris calibrated_sensor_raw_readings dengan quality_flag cocok regex ini dikeluarkan dari hitungan EC_adj. Sesuaikan dengan isi kolom quality_flag.';



COMMENT ON COLUMN "public"."fertigation_config"."k_ec_per_ml" IS 'Kenaikan EC_adj 24 jam per mL. NULL menahan mode calibrated; hanya mode manual_initial eksplisit mengizinkan dosis uji tanpa k/G3.';



CREATE OR REPLACE VIEW "public"."fertigation_config_active" WITH ("security_invoker"='true') AS
 SELECT DISTINCT ON ("plot_id") "id",
    "plot_id",
    "node_id",
    "theta_ref_pct",
    "s_ec_per_theta",
    "theta_valid_min_pct",
    "theta_valid_max_pct",
    "ec_window_min",
    "flag_exclude_regex",
    "ec_base_uscm",
    "k_ec_per_ml",
    "ec_max_factor",
    "nutrient_batch_id",
    "v_dasar_ml",
    "v_maks_ml",
    "r_min",
    "r_max",
    "decision_source",
    "rf_spread_max",
    "rf_real_weight",
    "rf_disagree_threshold",
    "decision_hour",
    "recommendation_valid_hours",
    "notes",
    "valid_from",
    "created_by",
    "created_at"
   FROM "public"."fertigation_config"
  WHERE ("valid_from" <= "now"())
  ORDER BY "plot_id", "valid_from" DESC, "created_at" DESC, "id" DESC;


ALTER VIEW "public"."fertigation_config_active" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fertigation_decisions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "node_id" "uuid",
    "config_id" "uuid",
    "model_id" "uuid",
    "decision_timestamp" timestamp with time zone NOT NULL,
    "ec25_uscm" double precision,
    "ec_adj_uscm" double precision,
    "theta_pct" double precision,
    "soil_temperature_c" double precision,
    "rain_24h_mm" double precision,
    "rain_forecast_12h_mm" double precision,
    "days_since_last_dose" double precision,
    "last_dose_ml" double precision,
    "last_response_per_ml" double precision,
    "ec_trend_24h" double precision,
    "g1_pass" boolean,
    "g1_reason" "text",
    "g2_pass" boolean,
    "g2_reason" "text",
    "g3_pass" boolean,
    "g3_reason" "text",
    "r_rf" double precision,
    "rf_spread" double precision,
    "r_formula" double precision,
    "rf_disagree" boolean,
    "decision_source" "text",
    "factor" double precision,
    "v_recommended_ml" double precision,
    "outcome" "text" NOT NULL,
    "data_version" "text",
    "model_version" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "origin" "text" DEFAULT 'real'::"text" NOT NULL,
    CONSTRAINT "fertigation_decisions_decision_source_check" CHECK (("decision_source" = ANY (ARRAY['rf'::"text", 'rule'::"text"]))),
    CONSTRAINT "fertigation_decisions_g1_consistent" CHECK ((("outcome" <> 'blocked_g1'::"text") OR ("g1_pass" IS FALSE))),
    CONSTRAINT "fertigation_decisions_g2_consistent" CHECK ((("outcome" <> 'blocked_g2'::"text") OR ("g2_pass" IS FALSE))),
    CONSTRAINT "fertigation_decisions_g3_consistent" CHECK ((("outcome" <> 'blocked_g3'::"text") OR ("g3_pass" IS FALSE))),
    CONSTRAINT "fertigation_decisions_outcome_check" CHECK (("outcome" = ANY (ARRAY['recommend'::"text", 'recommend_uncalibrated'::"text", 'not_needed'::"text", 'blocked_g1'::"text", 'blocked_g2'::"text", 'blocked_g3'::"text"])))
);


ALTER TABLE "public"."fertigation_decisions" OWNER TO "postgres";


COMMENT ON TABLE "public"."fertigation_decisions" IS 'Satu baris per keputusan harian per petak, termasuk saat tidak ada rekomendasi. Menjadi bahan latih RF dan bukti untuk laporan.';



COMMENT ON COLUMN "public"."fertigation_decisions"."r_rf" IS 'Prediksi RF: berapa dosis dasar yang masih kurang hari ini. NULL pada mode awal atau saat decision_source=rule tanpa RF.';



COMMENT ON COLUMN "public"."fertigation_decisions"."r_formula" IS 'EC_target = EC_base + k x V_dasar; r = (EC_target - EC_adj) / (k x V_dasar). Guru saat RF dilatih dan pembanding saat RF memutuskan.';



CREATE OR REPLACE VIEW "public"."nutrient_batch_concentration" AS
SELECT
    NULL::"uuid" AS "batch_id",
    NULL::"uuid" AS "node_id",
    NULL::boolean AS "is_active",
    NULL::double precision AS "solution_volume_l",
    NULL::double precision AS "n_g_per_ml",
    NULL::double precision AS "p2o5_g_per_ml",
    NULL::double precision AS "k2o_g_per_ml",
    NULL::bigint AS "item_count",
    NULL::boolean AS "all_products_verified",
    NULL::boolean AS "ec_measured";


ALTER VIEW "public"."nutrient_batch_concentration" OWNER TO "postgres";


COMMENT ON VIEW "public"."nutrient_batch_concentration" IS 'Konsentrasi N, P2O5, K2O (g/mL) tiap batch. Untuk analisis riset, pakai batch dengan all_products_verified dan ec_measured.';



CREATE OR REPLACE VIEW "public"."fertigation_delivered" WITH ("security_invoker"='true') AS
 SELECT "a"."id" AS "fertigation_action_id",
    "a"."plot_id",
    "a"."node_id",
    "a"."execution_timestamp",
    "a"."nutrient_batch_id",
    "a"."actual_volume" AS "solution_l",
    (("a"."actual_volume" * (1000)::double precision) * "c"."n_g_per_ml") AS "n_g",
    (("a"."actual_volume" * (1000)::double precision) * "c"."p2o5_g_per_ml") AS "p2o5_g",
    (("a"."actual_volume" * (1000)::double precision) * "c"."k2o_g_per_ml") AS "k2o_g"
   FROM ("public"."fertigation_actions" "a"
     LEFT JOIN "public"."nutrient_batch_concentration" "c" ON (("c"."batch_id" = "a"."nutrient_batch_id")));


ALTER VIEW "public"."fertigation_delivered" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fertigation_dose_responses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "fertigation_action_id" "uuid",
    "recommendation_id" "uuid",
    "is_test_dose" boolean DEFAULT false NOT NULL,
    "dose_multiplier" double precision,
    "dose_timestamp" timestamp with time zone NOT NULL,
    "v_actual_ml" double precision NOT NULL,
    "theta_ref_pct" double precision,
    "ec_adj_before" double precision,
    "theta_before_pct" double precision,
    "measure_timestamp" timestamp with time zone,
    "ec_adj_after_24h" double precision,
    "theta_after_pct" double precision,
    "noise_5min_uscm" double precision DEFAULT 0.39 NOT NULL,
    "delta_ec_adj" double precision GENERATED ALWAYS AS (("ec_adj_after_24h" - "ec_adj_before")) STORED,
    "k_ec_per_ml" double precision GENERATED ALWAYS AS (
CASE
    WHEN (("ec_adj_after_24h" IS NOT NULL) AND ("ec_adj_before" IS NOT NULL)) THEN (("ec_adj_after_24h" - "ec_adj_before") / "v_actual_ml")
    ELSE NULL::double precision
END) STORED,
    "readable" boolean GENERATED ALWAYS AS (
CASE
    WHEN (("ec_adj_after_24h" IS NOT NULL) AND ("ec_adj_before" IS NOT NULL)) THEN (("ec_adj_after_24h" - "ec_adj_before") > ((5)::double precision * "noise_5min_uscm"))
    ELSE NULL::boolean
END) STORED,
    "theta_comparable" boolean GENERATED ALWAYS AS (
CASE
    WHEN (("theta_ref_pct" IS NOT NULL) AND ("theta_before_pct" IS NOT NULL) AND ("theta_after_pct" IS NOT NULL)) THEN (("abs"(("theta_before_pct" - "theta_ref_pct")) <= (1)::double precision) AND ("abs"(("theta_after_pct" - "theta_ref_pct")) <= (1)::double precision))
    ELSE NULL::boolean
END) STORED,
    "used_for_training" boolean DEFAULT false NOT NULL,
    "training_weight" double precision DEFAULT 10 NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "config_id" "uuid",
    "quality_pass" boolean DEFAULT false NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_note" "text",
    CONSTRAINT "fertigation_dose_responses_noise_5min_uscm_check" CHECK (("noise_5min_uscm" > (0)::double precision)),
    CONSTRAINT "fertigation_dose_responses_training_weight_check" CHECK (("training_weight" > (0)::double precision)),
    CONSTRAINT "fertigation_dose_responses_v_actual_ml_check" CHECK (("v_actual_ml" > (0)::double precision))
);


ALTER TABLE "public"."fertigation_dose_responses" OWNER TO "postgres";


COMMENT ON TABLE "public"."fertigation_dose_responses" IS 'ΔEC_adj 24 jam setelah dosis (jam sama, θ sebanding). Sumber k dan label nyata untuk melatih ulang RF.';



COMMENT ON COLUMN "public"."fertigation_dose_responses"."readable" IS 'TRUE bila ΔEC_adj > 5 x derau rata-rata 5 menit (respons dianggap terbaca).';



COMMENT ON COLUMN "public"."fertigation_dose_responses"."theta_comparable" IS 'TRUE bila θ sebelum dan sesudah berada dalam ±1 %vol dari θ_ref.';



CREATE TABLE IF NOT EXISTS "public"."fertigation_recommendations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "model_id" "uuid",
    "recommendation_timestamp" timestamp with time zone NOT NULL,
    "dosis_dasar_g" double precision,
    "modulation_factor" double precision,
    "final_dose_g" double precision,
    "volume_pump_ml" double precision,
    "pump_duration_seconds" double precision,
    "ec_pori_source_reading_id" bigint,
    "ec_pori_latest" double precision,
    "ec_pori_prediction" double precision,
    "status" "public"."fertigation_recommendation_type",
    "confidence_low" double precision,
    "confidence_high" double precision,
    "reason" "text",
    "base_dose_source" character varying,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "plant_phenology_id" "uuid",
    "fertilizer_product_id" "uuid",
    "dispatched_command_id" "uuid",
    "dispatch_note" "text",
    "target_n_g" double precision,
    "target_p2o5_g" double precision,
    "target_k2o_g" double precision,
    "nutrient_batch_id" "uuid",
    "decision_id" "uuid",
    "decision_source" "text",
    "r_rf" double precision,
    "r_formula" double precision,
    "valid_until" timestamp with time zone,
    "approval_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "approved_volume_ml" double precision,
    "modification_reason" "text",
    CONSTRAINT "fertigation_recommendations_approval_status_check" CHECK (("approval_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'modified'::"text", 'rejected'::"text", 'expired'::"text"]))),
    CONSTRAINT "fertigation_recommendations_approved_volume_ml_check" CHECK (("approved_volume_ml" >= (0)::double precision)),
    CONSTRAINT "fertigation_recommendations_decision_source_check" CHECK (("decision_source" = ANY (ARRAY['rf'::"text", 'rule'::"text"]))),
    CONSTRAINT "fertigation_recommendations_target_k2o_g_check" CHECK (("target_k2o_g" >= (0)::double precision)),
    CONSTRAINT "fertigation_recommendations_target_n_g_check" CHECK (("target_n_g" >= (0)::double precision)),
    CONSTRAINT "fertigation_recommendations_target_p2o5_g_check" CHECK (("target_p2o5_g" >= (0)::double precision))
);


ALTER TABLE "public"."fertigation_recommendations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."fertigation_recommendations"."dosis_dasar_g" IS 'Dipakai ulang sebagai setara gram: V_dasar (mL) x c_stok (g/L) / 1000.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."modulation_factor" IS 'Faktor 0 bila r<0.7; selain itu min(r,1.3).';



COMMENT ON COLUMN "public"."fertigation_recommendations"."final_dose_g" IS 'Dipakai ulang sebagai setara gram: volume_pump_ml x c_stok (g/L) / 1000.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."volume_pump_ml" IS 'V=0 bila r<r_min, selain itu min(r,r_max)*V_dasar dibatasi V_maks. Durasi integer dibulatkan ke bawah.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."pump_duration_seconds" IS 't = V / q, dengan q = node_actuator_config.dose_flow_ml_per_s.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."ec_pori_source_reading_id" IS 'DEPRECATED: konsep baru memakai EC_adj, bukan EC pori. Dibiarkan untuk data lama.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."ec_pori_latest" IS 'DEPRECATED: konsep baru memakai EC_adj (lihat fertigation_decisions.ec_adj_uscm).';



COMMENT ON COLUMN "public"."fertigation_recommendations"."ec_pori_prediction" IS 'DEPRECATED: RF kini memprediksi r_RF (kebutuhan dosis), bukan EC pori.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."confidence_low" IS 'Dipakai ulang: batas bawah sebaran prediksi r_RF antar-pohon.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."confidence_high" IS 'Dipakai ulang: batas atas sebaran prediksi r_RF antar-pohon.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."plant_phenology_id" IS 'DEPRECATED sementara: fase pertumbuhan ditunda; V_dasar tetap per konfigurasi.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."target_n_g" IS 'DEPRECATED: N, P, K tidak dipakai (kanal sensor turunan EC). Dibiarkan untuk data lama.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."target_p2o5_g" IS 'DEPRECATED: lihat target_n_g.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."target_k2o_g" IS 'DEPRECATED: lihat target_n_g.';



COMMENT ON COLUMN "public"."fertigation_recommendations"."approval_status" IS 'pending -> approved | modified | rejected | expired. Hanya diubah lewat approve_fertigation_recommendation() dan fertigation_expire_recommendations().';



CREATE TABLE IF NOT EXISTS "public"."fertigation_rf_evaluations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_id" "uuid" NOT NULL,
    "evaluated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_version" "text",
    "n_scenarios" integer,
    "c1_agreement_pct" double precision,
    "c1_mae_r" double precision,
    "c2_violations" integer,
    "c3_negative_control_pass" boolean,
    "c3_positive_control_pass" boolean,
    "c4_real_mae_r" double precision,
    "c4_n_events" integer,
    "eligible" boolean GENERATED ALWAYS AS (COALESCE((("c1_agreement_pct" >= (95)::double precision) AND ("c1_mae_r" <= (0.10)::double precision) AND ("c2_violations" = 0) AND "c3_negative_control_pass" AND "c3_positive_control_pass"), false)) STORED,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "fertigation_rf_evaluations_c1_agreement_pct_check" CHECK ((("c1_agreement_pct" >= (0)::double precision) AND ("c1_agreement_pct" <= (100)::double precision))),
    CONSTRAINT "fertigation_rf_evaluations_c1_mae_r_check" CHECK (("c1_mae_r" >= (0)::double precision)),
    CONSTRAINT "fertigation_rf_evaluations_c2_violations_check" CHECK (("c2_violations" >= 0)),
    CONSTRAINT "fertigation_rf_evaluations_c4_n_events_check" CHECK (("c4_n_events" >= 0)),
    CONSTRAINT "fertigation_rf_evaluations_c4_real_mae_r_check" CHECK (("c4_real_mae_r" >= (0)::double precision))
);


ALTER TABLE "public"."fertigation_rf_evaluations" OWNER TO "postgres";


COMMENT ON TABLE "public"."fertigation_rf_evaluations" IS 'Hasil uji kriteria kelayakan RF fertigasi. Ambang (95%, 0.10) bersifat sementara dan tertanam di kolom eligible.';



CREATE TABLE IF NOT EXISTS "public"."fertilizer_products" (
    "name" character varying NOT NULL,
    "n_pct" double precision NOT NULL,
    "p_pct" double precision NOT NULL,
    "k_pct" double precision NOT NULL,
    "density_g_per_ml" double precision,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_user_id" "uuid",
    "is_verified" boolean DEFAULT false NOT NULL,
    "form" "text" DEFAULT 'solid'::"text" NOT NULL,
    CONSTRAINT "fertilizer_products_form_check" CHECK (("form" = ANY (ARRAY['solid'::"text", 'liquid'::"text"]))),
    CONSTRAINT "fertilizer_products_liquid_density" CHECK ((("form" <> 'liquid'::"text") OR ("density_g_per_ml" > (0)::double precision))),
    CONSTRAINT "fertilizer_products_pct_range" CHECK (((("n_pct" >= (0)::double precision) AND ("n_pct" <= (100)::double precision)) AND (("p_pct" >= (0)::double precision) AND ("p_pct" <= (100)::double precision)) AND (("k_pct" >= (0)::double precision) AND ("k_pct" <= (100)::double precision))))
);


ALTER TABLE "public"."fertilizer_products" OWNER TO "postgres";


COMMENT ON COLUMN "public"."fertilizer_products"."n_pct" IS 'N total (%) sesuai label.';



COMMENT ON COLUMN "public"."fertilizer_products"."p_pct" IS 'Fosfor sebagai P2O5 (%) sesuai label.';



COMMENT ON COLUMN "public"."fertilizer_products"."k_pct" IS 'Kalium sebagai K2O (%) sesuai label.';



COMMENT ON COLUMN "public"."fertilizer_products"."owner_user_id" IS 'NULL = katalog global (diisi tim). Terisi = produk pribadi petani, hanya terlihat oleh pemiliknya.';



CREATE TABLE IF NOT EXISTS "public"."ingest_rejects" (
    "id" bigint NOT NULL,
    "node_id" "uuid",
    "endpoint" "text" NOT NULL,
    "line_no" integer,
    "raw_line" "text",
    "reason" "text" NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ingest_rejects" OWNER TO "postgres";


ALTER TABLE "public"."ingest_rejects" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."ingest_rejects_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."irrigation_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "irrigation_prediction_id" "uuid",
    "action_timestamp" timestamp with time zone NOT NULL,
    "triggered_by" "public"."trigger_type",
    "valve_action" "public"."valve_action_status",
    "duration_sec" bigint,
    "estimated_volume_liter" double precision,
    "execution_status" "public"."execution_status",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "node_id" "uuid",
    "command_id" "uuid",
    "device_event_id" "text",
    "clock_segment" "text",
    "action_timestamp_raw" timestamp with time zone,
    "detail" "text"
);


ALTER TABLE "public"."irrigation_actions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."irrigation_actions"."duration_sec" IS 'Durasi pompa air AKTUAL yang dilaporkan ESP (bukan durasi yang diminta).';



COMMENT ON COLUMN "public"."irrigation_actions"."device_event_id" IS 'ID event dari ESP (ev_id). Kunci anti-duplikat upload ulang.';



CREATE TABLE IF NOT EXISTS "public"."irrigation_features" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "feature_timestamp" timestamp with time zone NOT NULL,
    "soil_moisture_lag_1h" double precision,
    "soil_moisture_lag_3h" double precision,
    "soil_moisture_lag_6h" double precision,
    "delta_moisture_1h" double precision,
    "delta_moisture_3h" double precision,
    "delta_moisture_6h" double precision,
    "rainfall_acc_1h" double precision,
    "rainfall_acc_6h" double precision,
    "rainfall_acc_24h" double precision,
    "hour_sin" double precision,
    "hour_cos" double precision,
    "day_of_year_sin" double precision,
    "day_of_year_cos" double precision,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."irrigation_features" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."irrigation_predictions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_id" "uuid",
    "prediction_timestamp" timestamp with time zone NOT NULL,
    "predicted_soil_moisture" double precision,
    "prediction_error_margin" double precision,
    "status_model" "public"."model_status",
    "prediction_dr_value" double precision,
    "raw_value" double precision,
    "irrigation_triggered" boolean,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reason" "text",
    "recommended_irrigation_mm" double precision,
    "dispatched_command_id" "uuid",
    "dispatch_note" "text",
    "decision_layer" "text",
    "dr_value_fao56" double precision,
    "taw_mm" double precision,
    "raw_mm" double precision,
    "dr_forecast_24h_mm" double precision,
    "etc_forecast_24h_mm" double precision,
    "rain_forecast_12h_mm" double precision,
    "ledger_id" bigint,
    CONSTRAINT "ip_decision_layer_valid" CHECK ((("decision_layer" IS NULL) OR ("decision_layer" = ANY (ARRAY['fao56'::"text", 'rf'::"text", 'fao56+rf'::"text"])))),
    CONSTRAINT "ip_model_required_for_ml" CHECK ((("model_id" IS NOT NULL) OR ("decision_layer" = 'fao56'::"text")))
);


ALTER TABLE "public"."irrigation_predictions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."irrigation_predictions"."recommended_irrigation_mm" IS 'Irigasi yang disarankan rule engine (mm). Server mengubahnya ke detik: (mm x wetted_area_m2) / water_flow_lpm x 60.';



CREATE TABLE IF NOT EXISTS "public"."lab_soil_tests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "lab_name" character varying NOT NULL,
    "sample_date" "date" NOT NULL,
    "lab_n_pct" double precision,
    "lab_p_pct" double precision,
    "lab_k_pct" double precision,
    "lab_ec_uscm" double precision,
    "lab_ph" double precision,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."lab_soil_tests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ml_feature_importance" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_id" "uuid",
    "feature_name" character varying(100) NOT NULL,
    "importance_pct" double precision NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."ml_feature_importance" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ml_model_metrics" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_id" "uuid",
    "horizon" character varying(20) NOT NULL,
    "model_name" character varying(100) NOT NULL,
    "rank_type" character varying(20) NOT NULL,
    "rmse" double precision NOT NULL,
    "mae" double precision NOT NULL,
    "r2" double precision NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."ml_model_metrics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."model_registries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" character varying NOT NULL,
    "type" "public"."model_type" NOT NULL,
    "task" "public"."task_type" NOT NULL,
    "trained_date" "date",
    "metrics_json" "jsonb",
    "is_active" boolean NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "version" character varying(50) DEFAULT 'v1.3.0'::character varying,
    "horizons" character varying(50) DEFAULT 't+6h, t+24h'::character varying,
    "training_samples" character varying(100) DEFAULT '4,312 hourly rows · 180 days'::character varying,
    "last_ml_output" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "ec_response_model" character varying(100) DEFAULT 'ec-resp-v0.2 · 28 Sep 2026'::character varying
);


ALTER TABLE "public"."model_registries" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."ml_models" AS
 SELECT ("id")::"text" AS "id",
    "name",
    ("type")::"text" AS "type",
    COALESCE("version", 'v1.3.0'::character varying) AS "version",
        CASE
            WHEN "is_active" THEN 'active'::"text"
            ELSE 'inactive'::"text"
        END AS "status",
    COALESCE("horizons", 't+6h, t+24h'::character varying) AS "horizons",
    ("trained_date")::timestamp with time zone AS "last_trained",
    COALESCE("training_samples", '4,312 hourly rows · 180 days'::character varying) AS "training_samples",
    COALESCE("last_ml_output", "now"()) AS "last_ml_output",
    COALESCE("ec_response_model", 'ec-resp-v0.2 · 28 Sep 2026'::character varying) AS "ec_response_model",
    "metrics_json",
    "created_at"
   FROM "public"."model_registries";


ALTER VIEW "public"."ml_models" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."node_actuator_config" (
    "node_id" "uuid" NOT NULL,
    "has_irrigation" boolean DEFAULT true NOT NULL,
    "has_fertigation" boolean DEFAULT false NOT NULL,
    "water_flow_lpm" double precision,
    "dose_flow_ml_per_s" double precision,
    "wetted_area_m2" double precision,
    "max_run_s" integer DEFAULT 600 NOT NULL,
    "max_water_day_s" integer DEFAULT 1800 NOT NULL,
    "max_dose_day_s" integer DEFAULT 300 NOT NULL,
    "min_gap_s" integer DEFAULT 1800 NOT NULL,
    "flush_s" integer DEFAULT 30 NOT NULL,
    "fallback_threshold_raw" double precision,
    "fallback_run_s" integer DEFAULT 120 NOT NULL,
    "fallback_offline_h" integer DEFAULT 24 NOT NULL,
    "morning_start_hour" integer DEFAULT 6 NOT NULL,
    "morning_end_hour" integer DEFAULT 9 NOT NULL,
    "config_version" integer DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "prewet_s" integer DEFAULT 30 NOT NULL,
    "stop_moisture_raw" double precision,
    "thresholds_auto" boolean DEFAULT true NOT NULL,
    CONSTRAINT "morning_window_valid" CHECK (("morning_end_hour" > "morning_start_hour")),
    CONSTRAINT "node_actuator_config_dose_flow_ml_per_s_check" CHECK (("dose_flow_ml_per_s" > (0)::double precision)),
    CONSTRAINT "node_actuator_config_fallback_offline_h_check" CHECK (("fallback_offline_h" >= 6)),
    CONSTRAINT "node_actuator_config_fallback_run_s_check" CHECK ((("fallback_run_s" >= 1) AND ("fallback_run_s" <= 600))),
    CONSTRAINT "node_actuator_config_flush_s_check" CHECK (("flush_s" >= 30)),
    CONSTRAINT "node_actuator_config_max_dose_day_s_check" CHECK ((("max_dose_day_s" >= 1) AND ("max_dose_day_s" <= 300))),
    CONSTRAINT "node_actuator_config_max_run_s_check" CHECK ((("max_run_s" >= 1) AND ("max_run_s" <= 600))),
    CONSTRAINT "node_actuator_config_max_water_day_s_check" CHECK ((("max_water_day_s" >= 1) AND ("max_water_day_s" <= 1800))),
    CONSTRAINT "node_actuator_config_min_gap_s_check" CHECK (("min_gap_s" >= 900)),
    CONSTRAINT "node_actuator_config_morning_end_hour_check" CHECK ((("morning_end_hour" >= 1) AND ("morning_end_hour" <= 24))),
    CONSTRAINT "node_actuator_config_morning_start_hour_check" CHECK ((("morning_start_hour" >= 0) AND ("morning_start_hour" <= 23))),
    CONSTRAINT "node_actuator_config_prewet_s_check" CHECK ((("prewet_s" >= 0) AND ("prewet_s" <= 300))),
    CONSTRAINT "node_actuator_config_water_flow_lpm_check" CHECK (("water_flow_lpm" > (0)::double precision)),
    CONSTRAINT "node_actuator_config_wetted_area_m2_check" CHECK (("wetted_area_m2" > (0)::double precision))
);


ALTER TABLE "public"."node_actuator_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."node_actuator_config" IS 'Konfigurasi aktuator per node. Dikirim ke ESP saat config_version berubah. Firmware tetap memakai batas kerasnya sendiri.';



COMMENT ON COLUMN "public"."node_actuator_config"."dose_flow_ml_per_s" IS 'Debit peristaltik (mL/detik) pada DOSE_DUTY firmware, diukur SAAT POMPA AIR MENYALA (melawan tekanan jalur).';



COMMENT ON COLUMN "public"."node_actuator_config"."flush_s" IS 'Fase BILAS (detik) setelah suntik pupuk. Tentukan dengan uji pewarna (waktu sampai penetes terjauh jernih kembali). Minimal 30.';



COMMENT ON COLUMN "public"."node_actuator_config"."fallback_threshold_raw" IS 'Ambang kelembapan tanah dalam satuan BACAAN SENSOR MENTAH (%). NULL = fallback lokal nonaktif.';



COMMENT ON COLUMN "public"."node_actuator_config"."prewet_s" IS 'Fase BASAHI (detik): pompa air jalan sebelum pupuk disuntik.';



COMMENT ON COLUMN "public"."node_actuator_config"."stop_moisture_raw" IS 'Rem jenuh: ESP menghentikan IRIGASI bila kelembapan mentah ≥ nilai ini (setara θ_FC). NULL = rem nonaktif.';



COMMENT ON COLUMN "public"."node_actuator_config"."thresholds_auto" IS 'true = fallback_threshold_raw dan stop_moisture_raw dihitung otomatis dari plot_soil_water_params + sensor_calibrations.';



CREATE TABLE IF NOT EXISTS "public"."nodes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "model" character varying,
    "install_date" "date",
    "last_calibration_date" "date",
    "status" "public"."node_status" DEFAULT 'active'::"public"."node_status" NOT NULL,
    "notes" "text",
    "mac_address" "text",
    "firmware_version" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "api_token_hash" "text",
    "last_seen_at" timestamp with time zone,
    "valve_is_on" boolean DEFAULT false NOT NULL,
    "valve_mode" "text" DEFAULT 'auto'::"text" NOT NULL,
    "valve_updated_at" timestamp with time zone,
    "pump_is_on" boolean DEFAULT false NOT NULL,
    "pump_mode" "text" DEFAULT 'auto'::"text" NOT NULL,
    "pump_updated_at" timestamp with time zone,
    "rain_mm_per_tip" double precision,
    CONSTRAINT "nodes_pump_mode_check" CHECK (("pump_mode" = ANY (ARRAY['auto'::"text", 'manual'::"text"]))),
    CONSTRAINT "nodes_rain_mm_per_tip_range" CHECK ((("rain_mm_per_tip" IS NULL) OR (("rain_mm_per_tip" > (0)::double precision) AND ("rain_mm_per_tip" < (1)::double precision)))),
    CONSTRAINT "nodes_valve_mode_check" CHECK (("valve_mode" = ANY (ARRAY['auto'::"text", 'manual'::"text"])))
);


ALTER TABLE "public"."nodes" OWNER TO "postgres";


COMMENT ON COLUMN "public"."nodes"."valve_is_on" IS 'Status pompa air yang DILAPORKAN ESP. Ditulis server, app hanya membaca.';



COMMENT ON COLUMN "public"."nodes"."valve_mode" IS 'Mode kanal irigasi (auto/manual). DITULIS APP.';



COMMENT ON COLUMN "public"."nodes"."valve_updated_at" IS 'Kapan valve_is_on terakhir berubah menurut laporan ESP.';



COMMENT ON COLUMN "public"."nodes"."pump_is_on" IS 'Status pompa peristaltik yang DILAPORKAN ESP. Ditulis server, app hanya membaca.';



COMMENT ON COLUMN "public"."nodes"."pump_mode" IS 'Mode kanal fertigasi (auto/manual). DITULIS APP.';



COMMENT ON COLUMN "public"."nodes"."pump_updated_at" IS 'Kapan pump_is_on terakhir berubah menurut laporan ESP.';



COMMENT ON COLUMN "public"."nodes"."rain_mm_per_tip" IS 'mm hujan per tip tipping bucket (hasil kalibrasi). NULL = 0,28 (nominal). Dipakai neraca air, bukan firmware.';



CREATE TABLE IF NOT EXISTS "public"."nutrient_batch_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "amount_g" double precision,
    "amount_ml" double precision,
    CONSTRAINT "nutrient_batch_items_amount_g_check" CHECK (("amount_g" > (0)::double precision)),
    CONSTRAINT "nutrient_batch_items_amount_ml_check" CHECK (("amount_ml" > (0)::double precision)),
    CONSTRAINT "nutrient_batch_items_one_amount" CHECK (("num_nonnulls"("amount_g", "amount_ml") = 1))
);


ALTER TABLE "public"."nutrient_batch_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nutrient_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "node_id" "uuid" NOT NULL,
    "name" "text",
    "solution_volume_l" double precision NOT NULL,
    "prepared_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "measured_ec_uscm" double precision,
    "measured_ph" double precision,
    "notes" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "deactivated_at" timestamp with time zone,
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "nutrient_batches_measured_ec_uscm_check" CHECK (("measured_ec_uscm" >= (0)::double precision)),
    CONSTRAINT "nutrient_batches_measured_ph_check" CHECK ((("measured_ph" >= (0)::double precision) AND ("measured_ph" <= (14)::double precision))),
    CONSTRAINT "nutrient_batches_solution_volume_l_check" CHECK (("solution_volume_l" > (0)::double precision))
);


ALTER TABLE "public"."nutrient_batches" OWNER TO "postgres";


COMMENT ON TABLE "public"."nutrient_batches" IS 'Larutan yang sedang/pernah ada di tangki pupuk node. Satu batch aktif per node. Batch baru otomatis menonaktifkan yang lama.';



CREATE TABLE IF NOT EXISTS "public"."plant_phenology" (
    "plot_id" "uuid" NOT NULL,
    "plant_phase" "public"."plant_phase" DEFAULT 'immature'::"public"."plant_phase" NOT NULL,
    "plant_age_months" integer NOT NULL,
    "effective_date" "date" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."plant_phenology" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plot_soil_water_params" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "theta_fc_pct" double precision NOT NULL,
    "theta_pwp_pct" double precision NOT NULL,
    "p_frac" double precision DEFAULT 0.40 NOT NULL,
    "zr_mm" double precision NOT NULL,
    "kc" double precision DEFAULT 1.0 NOT NULL,
    "source" "text" NOT NULL,
    "notes" "text",
    "valid_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pswp_kc_range" CHECK ((("kc" > (0)::double precision) AND ("kc" <= (2)::double precision))),
    CONSTRAINT "pswp_p_range" CHECK ((("p_frac" > (0)::double precision) AND ("p_frac" < (1)::double precision))),
    CONSTRAINT "pswp_theta_range" CHECK ((("theta_pwp_pct" > (0)::double precision) AND ("theta_fc_pct" < (100)::double precision) AND ("theta_pwp_pct" < "theta_fc_pct"))),
    CONSTRAINT "pswp_zr_range" CHECK ((("zr_mm" >= (50)::double precision) AND ("zr_mm" <= (3000)::double precision)))
);


ALTER TABLE "public"."plot_soil_water_params" OWNER TO "postgres";


COMMENT ON TABLE "public"."plot_soil_water_params" IS 'Parameter neraca air FAO-56 per plot. Berversi lewat valid_from; jangan di-update, insert baris baru.';



CREATE OR REPLACE VIEW "public"."plot_water_params_current" WITH ("security_invoker"='on') AS
 SELECT DISTINCT ON ("plot_id") "id" AS "params_id",
    "plot_id",
    "theta_fc_pct",
    "theta_pwp_pct",
    "p_frac",
    "zr_mm",
    "kc",
    "source",
    "valid_from",
    ((("theta_fc_pct" - "theta_pwp_pct") / (100.0)::double precision) * "zr_mm") AS "taw_mm",
    ((("p_frac" * ("theta_fc_pct" - "theta_pwp_pct")) / (100.0)::double precision) * "zr_mm") AS "raw_mm",
    ("theta_fc_pct" - ("p_frac" * ("theta_fc_pct" - "theta_pwp_pct"))) AS "theta_trigger_pct"
   FROM "public"."plot_soil_water_params" "p"
  WHERE ("valid_from" <= "now"())
  ORDER BY "plot_id", "valid_from" DESC;


ALTER VIEW "public"."plot_water_params_current" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_name" character varying NOT NULL,
    "area_m2" double precision,
    "planting_date" "date",
    "location_lat" "text",
    "location_lng" "text",
    "picture_url" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."plots" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "full_name" "text",
    "email" "text",
    "avatar_url" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "fcm_token" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sensor_raw_readings" (
    "id" bigint NOT NULL,
    "reading_timestamp" timestamp with time zone,
    "soil_moisture_pct" double precision,
    "soil_temperature_c" double precision,
    "soil_ec_uscm" double precision,
    "soil_ph" real,
    "rainfall_tip_count" bigint,
    "rainfall_mm" double precision,
    "quality_flag" "text",
    "air_temperature_c" double precision,
    "air_humidity_pct" double precision,
    "node_id" "uuid",
    "plot_id" "uuid",
    "soil_n_mgkg" double precision,
    "soil_p_mgkg" double precision,
    "soil_k_mgkg" double precision,
    "reading_timestamp_raw" timestamp with time zone,
    "clock_segment" "text",
    "uptime_s" bigint,
    "device_flags" integer,
    "time_status" "text",
    "ingested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sensor_raw_readings_time_status_check" CHECK (("time_status" = ANY (ARRAY['verified'::"text", 'corrected_constant'::"text", 'corrected_linear'::"text", 'unverified'::"text", 'legacy'::"text"])))
);


ALTER TABLE "public"."sensor_raw_readings" OWNER TO "postgres";


COMMENT ON COLUMN "public"."sensor_raw_readings"."reading_timestamp_raw" IS 'Timestamp mentah dari RTC node, tidak pernah diubah. reading_timestamp = hasil koreksi.';



COMMENT ON COLUMN "public"."sensor_raw_readings"."device_flags" IS 'Bitmask firmware: 1 time_unverified, 2 rtc_jump, 4 soil_fail, 8 sht_fail, 16 rain_fail, 32 rtc_read_fail';



ALTER TABLE "public"."sensor_raw_readings" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."raw_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."sensor_calibrations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "node_id" "uuid" NOT NULL,
    "parameter" "text" NOT NULL,
    "coeffs" double precision[] NOT NULL,
    "raw_min" double precision NOT NULL,
    "raw_max" double precision NOT NULL,
    "r2" double precision,
    "n_points" integer,
    "source" "text" NOT NULL,
    "notes" "text",
    "valid_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sc_raw_range" CHECK (("raw_max" > "raw_min")),
    CONSTRAINT "sensor_calibrations_coeffs_check" CHECK ((("array_length"("coeffs", 1) >= 2) AND ("array_length"("coeffs", 1) <= 4))),
    CONSTRAINT "sensor_calibrations_n_points_check" CHECK ((("n_points" IS NULL) OR ("n_points" >= 2))),
    CONSTRAINT "sensor_calibrations_parameter_check" CHECK (("parameter" = ANY (ARRAY['soil_moisture'::"text", 'soil_temperature'::"text", 'soil_ec'::"text", 'soil_ph'::"text"]))),
    CONSTRAINT "sensor_calibrations_r2_check" CHECK ((("r2" IS NULL) OR (("r2" >= (0)::double precision) AND ("r2" <= (1)::double precision))))
);


ALTER TABLE "public"."sensor_calibrations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_notifications" (
    "id" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "type" "text",
    "data" "jsonb",
    "is_read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."user_notifications" REPLICA IDENTITY FULL;


ALTER TABLE "public"."user_notifications" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_fertigation_formula_examples" WITH ("security_invoker"='true') AS
 SELECT "id",
    "plot_id",
    "config_id",
    "origin",
    "r_formula",
    'formula_imitation_not_ground_truth'::"text" AS "label_kind"
   FROM "public"."fertigation_decisions"
  WHERE ("r_formula" IS NOT NULL);


ALTER VIEW "public"."v_fertigation_formula_examples" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_fertigation_pending" WITH ("security_invoker"='true') AS
 SELECT "r"."id" AS "recommendation_id",
    "r"."plot_id",
    "r"."recommendation_timestamp",
    "r"."valid_until",
    "r"."volume_pump_ml",
    "r"."pump_duration_seconds",
    "r"."decision_source",
    "r"."r_rf",
    "r"."r_formula",
    "r"."reason",
    "d"."ec_adj_uscm",
    "d"."theta_pct",
    "d"."rf_disagree",
    "d"."outcome",
    ("r"."valid_until" - "now"()) AS "time_left"
   FROM ("public"."fertigation_recommendations" "r"
     LEFT JOIN "public"."fertigation_decisions" "d" ON (("d"."id" = "r"."decision_id")))
  WHERE (("r"."approval_status" = 'pending'::"text") AND ("r"."valid_until" > "now"()) AND ("r"."decision_id" IS NOT NULL));


ALTER VIEW "public"."v_fertigation_pending" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_fertigation_training_data" WITH ("security_invoker"='true') AS
 SELECT "d"."id" AS "decision_id",
    "d"."plot_id",
    "d"."decision_timestamp",
    "d"."ec_adj_uscm",
    ("d"."ec_adj_uscm" - "c"."ec_base_uscm") AS "ec_adj_minus_base",
    "d"."theta_pct",
    "d"."soil_temperature_c",
    "d"."rain_24h_mm",
    "d"."rain_forecast_12h_mm",
    "d"."days_since_last_dose",
    "d"."last_dose_ml",
    "d"."last_response_per_ml",
    "d"."ec_trend_24h",
    "d"."r_formula" AS "label_formula",
        CASE
            WHEN ("r"."approval_status" = ANY (ARRAY['approved'::"text", 'modified'::"text"])) THEN ("r"."approved_volume_ml" / "c"."v_dasar_ml")
            ELSE NULL::double precision
        END AS "label_farmer_ratio",
    "resp"."delta_ec_adj" AS "response_delta_ec_adj",
    "resp"."k_ec_per_ml" AS "response_k",
    "resp"."readable" AS "response_readable",
    "resp"."theta_comparable" AS "response_theta_comparable",
    "resp"."training_weight",
    "d"."data_version"
   FROM ((("public"."fertigation_decisions" "d"
     JOIN "public"."fertigation_config" "c" ON (("c"."id" = "d"."config_id")))
     JOIN "public"."fertigation_recommendations" "r" ON (("r"."decision_id" = "d"."id")))
     JOIN "public"."fertigation_dose_responses" "resp" ON (("resp"."recommendation_id" = "r"."id")))
  WHERE (("d"."origin" = 'real'::"text") AND "resp"."used_for_training" AND ("resp"."reviewed_by" IS NOT NULL) AND "resp"."quality_pass" AND "resp"."readable" AND "resp"."theta_comparable" AND ("d"."g1_pass" IS TRUE) AND ("d"."g2_pass" IS TRUE) AND ("d"."g3_pass" IS TRUE));


ALTER VIEW "public"."v_fertigation_training_data" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."water_balance_ledger" (
    "id" bigint NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "node_id" "uuid",
    "period_start" timestamp with time zone NOT NULL,
    "period_end" timestamp with time zone NOT NULL,
    "params_id" "uuid",
    "eto_mm" double precision,
    "eto_source" "text" NOT NULL,
    "kc" double precision,
    "etc_mm" double precision DEFAULT 0 NOT NULL,
    "rain_mm" double precision DEFAULT 0 NOT NULL,
    "rain_source" "text" NOT NULL,
    "irrigation_mm" double precision DEFAULT 0 NOT NULL,
    "dp_mm" double precision DEFAULT 0 NOT NULL,
    "dr_start_mm" double precision NOT NULL,
    "dr_model_mm" double precision NOT NULL,
    "theta_obs_raw" double precision,
    "theta_obs_pct" double precision,
    "dr_obs_mm" double precision,
    "dr_end_mm" double precision NOT NULL,
    "corrected" boolean DEFAULT false NOT NULL,
    "taw_mm" double precision,
    "raw_mm" double precision,
    "calibration_status" "text" NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "water_balance_ledger_calibration_status_check" CHECK (("calibration_status" = ANY (ARRAY['calibrated'::"text", 'uncalibrated'::"text"]))),
    CONSTRAINT "water_balance_ledger_dp_mm_check" CHECK (("dp_mm" >= (0)::double precision)),
    CONSTRAINT "water_balance_ledger_dr_end_mm_check" CHECK (("dr_end_mm" >= (0)::double precision)),
    CONSTRAINT "water_balance_ledger_dr_model_mm_check" CHECK (("dr_model_mm" >= (0)::double precision)),
    CONSTRAINT "water_balance_ledger_dr_obs_mm_check" CHECK ((("dr_obs_mm" IS NULL) OR ("dr_obs_mm" >= (0)::double precision))),
    CONSTRAINT "water_balance_ledger_dr_start_mm_check" CHECK (("dr_start_mm" >= (0)::double precision)),
    CONSTRAINT "water_balance_ledger_etc_mm_check" CHECK (("etc_mm" >= (0)::double precision)),
    CONSTRAINT "water_balance_ledger_eto_mm_check" CHECK ((("eto_mm" IS NULL) OR ("eto_mm" >= (0)::double precision))),
    CONSTRAINT "water_balance_ledger_eto_source_check" CHECK (("eto_source" = ANY (ARRAY['open_meteo'::"text", 'open_meteo_cached'::"text", 'open_meteo_archive'::"text", 'hargreaves_sht31'::"text", 'none'::"text"]))),
    CONSTRAINT "water_balance_ledger_irrigation_mm_check" CHECK (("irrigation_mm" >= (0)::double precision)),
    CONSTRAINT "water_balance_ledger_rain_mm_check" CHECK (("rain_mm" >= (0)::double precision)),
    CONSTRAINT "water_balance_ledger_rain_source_check" CHECK (("rain_source" = ANY (ARRAY['sensor'::"text", 'open_meteo'::"text", 'none'::"text"]))),
    CONSTRAINT "wbl_period_valid" CHECK (("period_end" > "period_start"))
);


ALTER TABLE "public"."water_balance_ledger" OWNER TO "postgres";


COMMENT ON TABLE "public"."water_balance_ledger" IS 'Neraca air FAO-56 per jam (Layer 1). Ditulis server; 48 jam terakhir dihitung ulang tiap siklus agar data offline yang telat masuk ikut terhitung.';



ALTER TABLE "public"."water_balance_ledger" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."water_balance_ledger_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."weather_forecast_snapshots" (
    "id" bigint NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "source" "text" DEFAULT 'open_meteo'::"text" NOT NULL,
    "model" "text" DEFAULT 'best_match'::"text" NOT NULL,
    "issued_at" timestamp with time zone NOT NULL,
    "valid_time" timestamp with time zone NOT NULL,
    "lead_hours" integer NOT NULL,
    "precipitation_mm" double precision,
    "precipitation_probability" double precision,
    "et0_fao_mm" double precision,
    "temperature_2m" double precision,
    "relative_humidity_2m" double precision,
    "wind_speed_10m" double precision,
    "shortwave_radiation" double precision,
    "fetched_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "weather_forecast_snapshots_et0_fao_mm_check" CHECK ((("et0_fao_mm" IS NULL) OR ("et0_fao_mm" >= (0)::double precision))),
    CONSTRAINT "weather_forecast_snapshots_lead_hours_check" CHECK ((("lead_hours" >= 1) AND ("lead_hours" <= 48))),
    CONSTRAINT "weather_forecast_snapshots_precipitation_mm_check" CHECK ((("precipitation_mm" IS NULL) OR ("precipitation_mm" >= (0)::double precision))),
    CONSTRAINT "weather_forecast_snapshots_precipitation_probability_check" CHECK ((("precipitation_probability" IS NULL) OR (("precipitation_probability" >= (0)::double precision) AND ("precipitation_probability" <= (100)::double precision)))),
    CONSTRAINT "wfs_lead_matches" CHECK (("valid_time" = ("issued_at" + "make_interval"("hours" => "lead_hours"))))
);


ALTER TABLE "public"."weather_forecast_snapshots" OWNER TO "postgres";


COMMENT ON TABLE "public"."weather_forecast_snapshots" IS 'Arsip prakiraan Open-Meteo per jam untuk ML. Append-only: satu set baris per fetch (issued_at).';



COMMENT ON COLUMN "public"."weather_forecast_snapshots"."model" IS 'Model yang DIMINTA (parameter models). Open-Meteo tidak mengembalikan model yang dipakai; best_match = pilihan otomatis.';



COMMENT ON COLUMN "public"."weather_forecast_snapshots"."issued_at" IS 'Waktu fetch dibulatkan ke bawah ke jam penuh (UTC). BUKAN waktu run model: Open-Meteo tidak mengembalikannya.';



COMMENT ON COLUMN "public"."weather_forecast_snapshots"."valid_time" IS 'Stempel jam Open-Meteo (UTC). Nilai akumulasi/rata-rata (hujan, ET0, radiasi) berlaku untuk satu jam SEBELUM stempel.';



COMMENT ON COLUMN "public"."weather_forecast_snapshots"."wind_speed_10m" IS 'm/s';



COMMENT ON COLUMN "public"."weather_forecast_snapshots"."shortwave_radiation" IS 'W/m², rata-rata satu jam sebelum valid_time';



ALTER TABLE "public"."weather_forecast_snapshots" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."weather_forecast_snapshots_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."weather_forecasts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "forecast_issued_at" timestamp with time zone NOT NULL,
    "valid_for_timestamp" timestamp with time zone NOT NULL,
    "forecast_rainfall_mm" double precision,
    "forecast_temperature_c" double precision,
    "forecast_humidity_pct" double precision,
    "source" "public"."source_type",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "forecast_eto_mm" double precision,
    CONSTRAINT "wf_eto_nonneg" CHECK ((("forecast_eto_mm" IS NULL) OR ("forecast_eto_mm" >= (0)::double precision)))
);


ALTER TABLE "public"."weather_forecasts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."weather_observed_hourly" (
    "id" bigint NOT NULL,
    "plot_id" "uuid" NOT NULL,
    "source" "text" DEFAULT 'open_meteo_archive'::"text" NOT NULL,
    "time" timestamp with time zone NOT NULL,
    "precipitation_mm" double precision,
    "temperature_2m" double precision,
    "relative_humidity_2m" double precision,
    "wind_speed_10m" double precision,
    "shortwave_radiation" double precision,
    "et0_fao_mm" double precision,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "weather_observed_hourly_et0_fao_mm_check" CHECK ((("et0_fao_mm" IS NULL) OR ("et0_fao_mm" >= (0)::double precision))),
    CONSTRAINT "weather_observed_hourly_precipitation_mm_check" CHECK ((("precipitation_mm" IS NULL) OR ("precipitation_mm" >= (0)::double precision)))
);


ALTER TABLE "public"."weather_observed_hourly" OWNER TO "postgres";


COMMENT ON TABLE "public"."weather_observed_hourly" IS 'Cuaca reanalisis Open-Meteo archive per jam (UTC). Nilai hari-hari terakhir bisa direvisi oleh job harian.';



COMMENT ON COLUMN "public"."weather_observed_hourly"."time" IS 'Stempel jam (UTC). Hujan, ET0, radiasi = jumlah/rata-rata satu jam SEBELUM stempel.';



COMMENT ON COLUMN "public"."weather_observed_hourly"."wind_speed_10m" IS 'm/s';



ALTER TABLE "public"."weather_observed_hourly" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."weather_observed_hourly_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."actuator_commands"
    ADD CONSTRAINT "actuator_commands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."calibrated_sensor_raw_readings"
    ADD CONSTRAINT "calibrated_sensor_raw_readings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clock_events"
    ADD CONSTRAINT "clock_events_node_segment_uq" UNIQUE ("node_id", "clock_segment");



ALTER TABLE ONLY "public"."clock_events"
    ADD CONSTRAINT "clock_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fertigation_actions"
    ADD CONSTRAINT "fertigation_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fertigation_config"
    ADD CONSTRAINT "fertigation_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fertigation_decisions"
    ADD CONSTRAINT "fertigation_decisions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fertigation_decisions"
    ADD CONSTRAINT "fertigation_decisions_unique" UNIQUE ("plot_id", "decision_timestamp");



ALTER TABLE ONLY "public"."fertigation_dose_responses"
    ADD CONSTRAINT "fertigation_dose_responses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fertigation_rf_evaluations"
    ADD CONSTRAINT "fertigation_rf_evaluations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fertilizer_products"
    ADD CONSTRAINT "fertilizer_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ingest_rejects"
    ADD CONSTRAINT "ingest_rejects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."irrigation_actions"
    ADD CONSTRAINT "irrigation_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."irrigation_features"
    ADD CONSTRAINT "irrigation_features_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."irrigation_predictions"
    ADD CONSTRAINT "irrigation_predictions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lab_soil_tests"
    ADD CONSTRAINT "lab_soil_tests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ml_feature_importance"
    ADD CONSTRAINT "ml_feature_importance_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ml_model_metrics"
    ADD CONSTRAINT "ml_model_metrics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."model_registries"
    ADD CONSTRAINT "model_registries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."node_actuator_config"
    ADD CONSTRAINT "node_actuator_config_pkey" PRIMARY KEY ("node_id");



ALTER TABLE ONLY "public"."nodes"
    ADD CONSTRAINT "nodes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nutrient_batch_items"
    ADD CONSTRAINT "nutrient_batch_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nutrient_batches"
    ADD CONSTRAINT "nutrient_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plant_phenology"
    ADD CONSTRAINT "plant_phenology_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plot_soil_water_params"
    ADD CONSTRAINT "plot_soil_water_params_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plots"
    ADD CONSTRAINT "plots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sensor_raw_readings"
    ADD CONSTRAINT "raw_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sensor_calibrations"
    ADD CONSTRAINT "sensor_calibrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_notifications"
    ADD CONSTRAINT "user_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."water_balance_ledger"
    ADD CONSTRAINT "water_balance_ledger_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."water_balance_ledger"
    ADD CONSTRAINT "wbl_unique_period" UNIQUE ("plot_id", "period_end");



ALTER TABLE ONLY "public"."weather_forecast_snapshots"
    ADD CONSTRAINT "weather_forecast_snapshots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."weather_forecasts"
    ADD CONSTRAINT "weather_forecasts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."weather_observed_hourly"
    ADD CONSTRAINT "weather_observed_hourly_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."weather_forecast_snapshots"
    ADD CONSTRAINT "wfs_unique" UNIQUE ("plot_id", "source", "issued_at", "valid_time");



ALTER TABLE ONLY "public"."weather_observed_hourly"
    ADD CONSTRAINT "woh_unique" UNIQUE ("plot_id", "source", "time");



CREATE INDEX "csrr_node_ts_idx" ON "public"."calibrated_sensor_raw_readings" USING "btree" ("node_id", "reading_timestamp");



CREATE INDEX "csrr_plot_ts_idx" ON "public"."calibrated_sensor_raw_readings" USING "btree" ("plot_id", "reading_timestamp");



CREATE UNIQUE INDEX "csrr_raw_reading_uq" ON "public"."calibrated_sensor_raw_readings" USING "btree" ("raw_reading_id");



CREATE INDEX "idx_actuator_commands_node_time" ON "public"."actuator_commands" USING "btree" ("node_id", "created_at" DESC);



CREATE INDEX "idx_actuator_commands_pending" ON "public"."actuator_commands" USING "btree" ("node_id", "created_at") WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_csrr_plot_time" ON "public"."calibrated_sensor_raw_readings" USING "btree" ("plot_id", "reading_timestamp" DESC);



CREATE INDEX "idx_fertigation_actions_plot_id" ON "public"."fertigation_actions" USING "btree" ("plot_id", "execution_timestamp" DESC);



CREATE INDEX "idx_fertigation_actions_plot_time" ON "public"."fertigation_actions" USING "btree" ("plot_id", "execution_timestamp" DESC);



CREATE INDEX "idx_fertigation_actions_rec_time" ON "public"."fertigation_actions" USING "btree" ("recommendation_id", "execution_timestamp" DESC);



CREATE INDEX "idx_fertigation_config_plot_valid" ON "public"."fertigation_config" USING "btree" ("plot_id", "valid_from" DESC);



CREATE INDEX "idx_fertigation_decisions_plot_time" ON "public"."fertigation_decisions" USING "btree" ("plot_id", "decision_timestamp" DESC);



CREATE INDEX "idx_fertigation_rec_plot_time" ON "public"."fertigation_recommendations" USING "btree" ("plot_id", "recommendation_timestamp" DESC);



CREATE INDEX "idx_fertigation_reco_decision" ON "public"."fertigation_recommendations" USING "btree" ("decision_id");



CREATE INDEX "idx_fertigation_reco_pending" ON "public"."fertigation_recommendations" USING "btree" ("plot_id", "valid_until") WHERE ("approval_status" = 'pending'::"text");



CREATE INDEX "idx_fertigation_response_plot_time" ON "public"."fertigation_dose_responses" USING "btree" ("plot_id", "dose_timestamp" DESC);



CREATE INDEX "idx_fertigation_response_reco" ON "public"."fertigation_dose_responses" USING "btree" ("recommendation_id");



CREATE INDEX "idx_fertigation_rf_eval_model" ON "public"."fertigation_rf_evaluations" USING "btree" ("model_id", "evaluated_at" DESC);



CREATE INDEX "idx_irrigation_actions_plot_time" ON "public"."irrigation_actions" USING "btree" ("plot_id", "action_timestamp" DESC);



CREATE INDEX "idx_irrigation_pred_plot_time" ON "public"."irrigation_predictions" USING "btree" ("plot_id", "prediction_timestamp" DESC);



CREATE INDEX "idx_irrigation_predictions_plot_time" ON "public"."irrigation_predictions" USING "btree" ("plot_id", "prediction_timestamp" DESC);



CREATE INDEX "idx_ml_feature_importance_order" ON "public"."ml_feature_importance" USING "btree" ("sort_order");



CREATE INDEX "idx_ml_model_metrics_horizon" ON "public"."ml_model_metrics" USING "btree" ("horizon", "rank_type");



CREATE INDEX "idx_nutrient_batch_items_batch" ON "public"."nutrient_batch_items" USING "btree" ("batch_id");



CREATE INDEX "idx_user_notifications_user_id" ON "public"."user_notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_weather_forecasts_plot_valid" ON "public"."weather_forecasts" USING "btree" ("plot_id", "valid_for_timestamp");



CREATE INDEX "ingest_rejects_node_received_idx" ON "public"."ingest_rejects" USING "btree" ("node_id", "received_at");



CREATE INDEX "ip_plot_ts_idx" ON "public"."irrigation_predictions" USING "btree" ("plot_id", "prediction_timestamp" DESC);



CREATE INDEX "pswp_plot_valid_idx" ON "public"."plot_soil_water_params" USING "btree" ("plot_id", "valid_from" DESC);



CREATE INDEX "sc_node_param_valid_idx" ON "public"."sensor_calibrations" USING "btree" ("node_id", "parameter", "valid_from" DESC);



CREATE UNIQUE INDEX "sensor_raw_readings_identity_uq" ON "public"."sensor_raw_readings" USING "btree" ("node_id", "clock_segment", "reading_timestamp_raw");



CREATE INDEX "sensor_raw_readings_node_ts_idx" ON "public"."sensor_raw_readings" USING "btree" ("node_id", "reading_timestamp");



CREATE INDEX "sensor_raw_readings_plot_ts_idx" ON "public"."sensor_raw_readings" USING "btree" ("plot_id", "reading_timestamp");



CREATE UNIQUE INDEX "uq_fertigation_actions_device_event" ON "public"."fertigation_actions" USING "btree" ("node_id", "device_event_id") WHERE ("device_event_id" IS NOT NULL);



CREATE UNIQUE INDEX "uq_fertigation_response_action" ON "public"."fertigation_dose_responses" USING "btree" ("fertigation_action_id") WHERE ("fertigation_action_id" IS NOT NULL);



CREATE UNIQUE INDEX "uq_irrigation_actions_device_event" ON "public"."irrigation_actions" USING "btree" ("node_id", "device_event_id") WHERE ("device_event_id" IS NOT NULL);



CREATE UNIQUE INDEX "uq_nutrient_batches_one_active" ON "public"."nutrient_batches" USING "btree" ("node_id") WHERE "is_active";



CREATE UNIQUE INDEX "weather_forecasts_plot_valid_source_uq" ON "public"."weather_forecasts" USING "btree" ("plot_id", "valid_for_timestamp", "source");



CREATE INDEX "wf_plot_valid_issued_idx" ON "public"."weather_forecasts" USING "btree" ("plot_id", "valid_for_timestamp", "forecast_issued_at" DESC);



CREATE INDEX "wfs_fetched_idx" ON "public"."weather_forecast_snapshots" USING "btree" ("fetched_at" DESC);



CREATE INDEX "wfs_plot_valid_idx" ON "public"."weather_forecast_snapshots" USING "btree" ("plot_id", "valid_time");



CREATE INDEX "woh_updated_idx" ON "public"."weather_observed_hourly" USING "btree" ("updated_at" DESC);



CREATE OR REPLACE VIEW "public"."nutrient_batch_concentration" WITH ("security_invoker"='true') AS
 SELECT "b"."id" AS "batch_id",
    "b"."node_id",
    "b"."is_active",
    "b"."solution_volume_l",
    (COALESCE("sum"((("m"."mass_g" * "p"."n_pct") / (100)::double precision)), (0)::double precision) / ("b"."solution_volume_l" * (1000)::double precision)) AS "n_g_per_ml",
    (COALESCE("sum"((("m"."mass_g" * "p"."p_pct") / (100)::double precision)), (0)::double precision) / ("b"."solution_volume_l" * (1000)::double precision)) AS "p2o5_g_per_ml",
    (COALESCE("sum"((("m"."mass_g" * "p"."k_pct") / (100)::double precision)), (0)::double precision) / ("b"."solution_volume_l" * (1000)::double precision)) AS "k2o_g_per_ml",
    "count"("i"."id") AS "item_count",
    COALESCE("bool_and"("p"."is_verified"), false) AS "all_products_verified",
    ("b"."measured_ec_uscm" IS NOT NULL) AS "ec_measured"
   FROM ((("public"."nutrient_batches" "b"
     LEFT JOIN "public"."nutrient_batch_items" "i" ON (("i"."batch_id" = "b"."id")))
     LEFT JOIN "public"."fertilizer_products" "p" ON (("p"."id" = "i"."product_id")))
     LEFT JOIN LATERAL ( SELECT COALESCE("i"."amount_g", ("i"."amount_ml" * "p"."density_g_per_ml")) AS "mass_g") "m" ON (true))
  GROUP BY "b"."id";



CREATE OR REPLACE TRIGGER "trg_activate_nutrient_batch" BEFORE INSERT OR UPDATE OF "is_active" ON "public"."nutrient_batches" FOR EACH ROW EXECUTE FUNCTION "public"."smile_activate_nutrient_batch"();



CREATE OR REPLACE TRIGGER "trg_bump_config_version" BEFORE UPDATE ON "public"."node_actuator_config" FOR EACH ROW EXECUTE FUNCTION "public"."smile_bump_config_version"();



CREATE OR REPLACE TRIGGER "trg_fertigation_actions_fill_plot_id" BEFORE INSERT ON "public"."fertigation_actions" FOR EACH ROW EXECUTE FUNCTION "public"."fertigation_actions_fill_plot_id"();



CREATE OR REPLACE TRIGGER "trg_fertigation_actions_sync_node" AFTER INSERT ON "public"."fertigation_actions" FOR EACH ROW EXECUTE FUNCTION "public"."sync_node_pump_state"();



CREATE OR REPLACE TRIGGER "trg_fertigation_command_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."actuator_commands" FOR EACH ROW EXECUTE FUNCTION "public"."fertigation_command_guard"();



CREATE OR REPLACE TRIGGER "trg_fertigation_config_validate" BEFORE INSERT OR DELETE OR UPDATE ON "public"."fertigation_config" FOR EACH ROW EXECUTE FUNCTION "public"."fertigation_config_validate"();



CREATE OR REPLACE TRIGGER "trg_fertigation_input_guard" BEFORE INSERT OR UPDATE ON "public"."fertigation_decisions" FOR EACH ROW EXECUTE FUNCTION "public"."fertigation_input_guard"();



CREATE OR REPLACE TRIGGER "trg_fertigation_input_guard" BEFORE INSERT OR UPDATE ON "public"."fertigation_recommendations" FOR EACH ROW EXECUTE FUNCTION "public"."fertigation_input_guard"();



CREATE OR REPLACE TRIGGER "trg_fertigation_response_guard" BEFORE INSERT OR UPDATE ON "public"."fertigation_dose_responses" FOR EACH ROW EXECUTE FUNCTION "public"."fertigation_response_guard"();



CREATE OR REPLACE TRIGGER "trg_guard_actuator_command" BEFORE INSERT ON "public"."actuator_commands" FOR EACH ROW EXECUTE FUNCTION "public"."smile_guard_actuator_command"();



CREATE OR REPLACE TRIGGER "trg_guard_batch_item" BEFORE INSERT OR UPDATE ON "public"."nutrient_batch_items" FOR EACH ROW EXECUTE FUNCTION "public"."smile_guard_batch_item"();



CREATE OR REPLACE TRIGGER "trg_guard_fertilizer_product" BEFORE INSERT OR UPDATE ON "public"."fertilizer_products" FOR EACH ROW EXECUTE FUNCTION "public"."smile_guard_fertilizer_product"();



CREATE OR REPLACE TRIGGER "trg_irrigation_actions_sync_node" AFTER INSERT ON "public"."irrigation_actions" FOR EACH ROW EXECUTE FUNCTION "public"."sync_node_valve_state"();



CREATE OR REPLACE TRIGGER "trg_nac_refresh_auto" AFTER UPDATE OF "thresholds_auto" ON "public"."node_actuator_config" FOR EACH ROW WHEN (("new"."thresholds_auto" AND (NOT "old"."thresholds_auto"))) EXECUTE FUNCTION "public"."smile_trg_refresh_from_config"();



CREATE OR REPLACE TRIGGER "trg_nac_refresh_ins" AFTER INSERT ON "public"."node_actuator_config" FOR EACH ROW EXECUTE FUNCTION "public"."smile_trg_refresh_from_config"();



CREATE OR REPLACE TRIGGER "trg_pswp_refresh" AFTER INSERT OR UPDATE ON "public"."plot_soil_water_params" FOR EACH ROW EXECUTE FUNCTION "public"."smile_trg_refresh_from_params"();



CREATE OR REPLACE TRIGGER "trg_sc_recalibrate_readings" AFTER INSERT OR UPDATE ON "public"."sensor_calibrations" FOR EACH ROW EXECUTE FUNCTION "public"."smile_trg_recalibrate_from_calibration"();



CREATE OR REPLACE TRIGGER "trg_sc_refresh" AFTER INSERT OR UPDATE ON "public"."sensor_calibrations" FOR EACH ROW EXECUTE FUNCTION "public"."smile_trg_refresh_from_calibration"();



CREATE OR REPLACE TRIGGER "trg_srr_calibrate" AFTER INSERT OR UPDATE OF "reading_timestamp", "node_id", "plot_id", "quality_flag", "soil_moisture_pct", "soil_temperature_c", "soil_ec_uscm", "rainfall_tip_count", "rainfall_mm", "soil_ph", "soil_n_mgkg", "soil_p_mgkg", "soil_k_mgkg", "air_temperature_c", "air_humidity_pct" ON "public"."sensor_raw_readings" FOR EACH ROW EXECUTE FUNCTION "public"."smile_trg_calibrate_reading"();



ALTER TABLE ONLY "public"."actuator_commands"
    ADD CONSTRAINT "actuator_commands_fertigation_recommendation_id_fkey" FOREIGN KEY ("fertigation_recommendation_id") REFERENCES "public"."fertigation_recommendations"("id");



ALTER TABLE ONLY "public"."actuator_commands"
    ADD CONSTRAINT "actuator_commands_irrigation_prediction_id_fkey" FOREIGN KEY ("irrigation_prediction_id") REFERENCES "public"."irrigation_predictions"("id");



ALTER TABLE ONLY "public"."actuator_commands"
    ADD CONSTRAINT "actuator_commands_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."actuator_commands"
    ADD CONSTRAINT "actuator_commands_nutrient_batch_id_fkey" FOREIGN KEY ("nutrient_batch_id") REFERENCES "public"."nutrient_batches"("id");



ALTER TABLE ONLY "public"."actuator_commands"
    ADD CONSTRAINT "actuator_commands_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id");



ALTER TABLE ONLY "public"."calibrated_sensor_raw_readings"
    ADD CONSTRAINT "calibrated_sensor_raw_readings_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."calibrated_sensor_raw_readings"
    ADD CONSTRAINT "calibrated_sensor_raw_readings_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id");



ALTER TABLE ONLY "public"."clock_events"
    ADD CONSTRAINT "clock_events_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."calibrated_sensor_raw_readings"
    ADD CONSTRAINT "csrr_raw_reading_fkey" FOREIGN KEY ("raw_reading_id") REFERENCES "public"."sensor_raw_readings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_actions"
    ADD CONSTRAINT "fertigation_actions_command_id_fkey" FOREIGN KEY ("command_id") REFERENCES "public"."actuator_commands"("id");



ALTER TABLE ONLY "public"."fertigation_actions"
    ADD CONSTRAINT "fertigation_actions_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."fertigation_actions"
    ADD CONSTRAINT "fertigation_actions_nutrient_batch_id_fkey" FOREIGN KEY ("nutrient_batch_id") REFERENCES "public"."nutrient_batches"("id");



ALTER TABLE ONLY "public"."fertigation_actions"
    ADD CONSTRAINT "fertigation_actions_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_actions"
    ADD CONSTRAINT "fertigation_actions_recommendation_id_fkey" FOREIGN KEY ("recommendation_id") REFERENCES "public"."fertigation_recommendations"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_config"
    ADD CONSTRAINT "fertigation_config_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."fertigation_config"
    ADD CONSTRAINT "fertigation_config_nutrient_batch_id_fkey" FOREIGN KEY ("nutrient_batch_id") REFERENCES "public"."nutrient_batches"("id");



ALTER TABLE ONLY "public"."fertigation_config"
    ADD CONSTRAINT "fertigation_config_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_decisions"
    ADD CONSTRAINT "fertigation_decisions_config_id_fkey" FOREIGN KEY ("config_id") REFERENCES "public"."fertigation_config"("id");



ALTER TABLE ONLY "public"."fertigation_decisions"
    ADD CONSTRAINT "fertigation_decisions_model_id_fkey" FOREIGN KEY ("model_id") REFERENCES "public"."model_registries"("id");



ALTER TABLE ONLY "public"."fertigation_decisions"
    ADD CONSTRAINT "fertigation_decisions_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."fertigation_decisions"
    ADD CONSTRAINT "fertigation_decisions_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_dose_responses"
    ADD CONSTRAINT "fertigation_dose_responses_config_id_fkey" FOREIGN KEY ("config_id") REFERENCES "public"."fertigation_config"("id");



ALTER TABLE ONLY "public"."fertigation_dose_responses"
    ADD CONSTRAINT "fertigation_dose_responses_fertigation_action_id_fkey" FOREIGN KEY ("fertigation_action_id") REFERENCES "public"."fertigation_actions"("id");



ALTER TABLE ONLY "public"."fertigation_dose_responses"
    ADD CONSTRAINT "fertigation_dose_responses_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_dose_responses"
    ADD CONSTRAINT "fertigation_dose_responses_recommendation_id_fkey" FOREIGN KEY ("recommendation_id") REFERENCES "public"."fertigation_recommendations"("id");



ALTER TABLE ONLY "public"."fertigation_dose_responses"
    ADD CONSTRAINT "fertigation_dose_responses_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_decision_id_fkey" FOREIGN KEY ("decision_id") REFERENCES "public"."fertigation_decisions"("id");



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_dispatched_command_id_fkey" FOREIGN KEY ("dispatched_command_id") REFERENCES "public"."actuator_commands"("id");



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_fertilizer_product_id_fkey" FOREIGN KEY ("fertilizer_product_id") REFERENCES "public"."fertilizer_products"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_model_id_fkey" FOREIGN KEY ("model_id") REFERENCES "public"."model_registries"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_nutrient_batch_id_fkey" FOREIGN KEY ("nutrient_batch_id") REFERENCES "public"."nutrient_batches"("id");



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_plant_phenology_id_fkey" FOREIGN KEY ("plant_phenology_id") REFERENCES "public"."plant_phenology"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_recommendations"
    ADD CONSTRAINT "fertigation_recommendations_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fertigation_rf_evaluations"
    ADD CONSTRAINT "fertigation_rf_evaluations_model_id_fkey" FOREIGN KEY ("model_id") REFERENCES "public"."model_registries"("id");



ALTER TABLE ONLY "public"."fertilizer_products"
    ADD CONSTRAINT "fertilizer_products_owner_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ingest_rejects"
    ADD CONSTRAINT "ingest_rejects_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."irrigation_actions"
    ADD CONSTRAINT "irrigation_actions_command_id_fkey" FOREIGN KEY ("command_id") REFERENCES "public"."actuator_commands"("id");



ALTER TABLE ONLY "public"."irrigation_actions"
    ADD CONSTRAINT "irrigation_actions_irrigation_prediction_id_fkey" FOREIGN KEY ("irrigation_prediction_id") REFERENCES "public"."irrigation_predictions"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."irrigation_actions"
    ADD CONSTRAINT "irrigation_actions_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."irrigation_actions"
    ADD CONSTRAINT "irrigation_actions_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."irrigation_features"
    ADD CONSTRAINT "irrigation_features_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."irrigation_predictions"
    ADD CONSTRAINT "irrigation_predictions_dispatched_command_id_fkey" FOREIGN KEY ("dispatched_command_id") REFERENCES "public"."actuator_commands"("id");



ALTER TABLE ONLY "public"."irrigation_predictions"
    ADD CONSTRAINT "irrigation_predictions_ledger_id_fkey" FOREIGN KEY ("ledger_id") REFERENCES "public"."water_balance_ledger"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."irrigation_predictions"
    ADD CONSTRAINT "irrigation_predictions_model_id_fkey" FOREIGN KEY ("model_id") REFERENCES "public"."model_registries"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."irrigation_predictions"
    ADD CONSTRAINT "irrigation_predictions_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lab_soil_tests"
    ADD CONSTRAINT "lab_soil_tests_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ml_feature_importance"
    ADD CONSTRAINT "ml_feature_importance_model_id_fkey" FOREIGN KEY ("model_id") REFERENCES "public"."model_registries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ml_model_metrics"
    ADD CONSTRAINT "ml_model_metrics_model_id_fkey" FOREIGN KEY ("model_id") REFERENCES "public"."model_registries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."node_actuator_config"
    ADD CONSTRAINT "node_actuator_config_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."nodes"
    ADD CONSTRAINT "nodes_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."nodes"
    ADD CONSTRAINT "nodes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."nutrient_batch_items"
    ADD CONSTRAINT "nutrient_batch_items_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."nutrient_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."nutrient_batch_items"
    ADD CONSTRAINT "nutrient_batch_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."fertilizer_products"("id");



ALTER TABLE ONLY "public"."nutrient_batches"
    ADD CONSTRAINT "nutrient_batches_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plant_phenology"
    ADD CONSTRAINT "plant_phenology_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plot_soil_water_params"
    ADD CONSTRAINT "plot_soil_water_params_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plots"
    ADD CONSTRAINT "plots_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sensor_calibrations"
    ADD CONSTRAINT "sensor_calibrations_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sensor_raw_readings"
    ADD CONSTRAINT "sensor_raw_readings_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id");



ALTER TABLE ONLY "public"."sensor_raw_readings"
    ADD CONSTRAINT "sensor_raw_readings_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id");



ALTER TABLE ONLY "public"."user_notifications"
    ADD CONSTRAINT "user_notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."water_balance_ledger"
    ADD CONSTRAINT "water_balance_ledger_node_id_fkey" FOREIGN KEY ("node_id") REFERENCES "public"."nodes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."water_balance_ledger"
    ADD CONSTRAINT "water_balance_ledger_params_id_fkey" FOREIGN KEY ("params_id") REFERENCES "public"."plot_soil_water_params"("id");



ALTER TABLE ONLY "public"."water_balance_ledger"
    ADD CONSTRAINT "water_balance_ledger_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."weather_forecast_snapshots"
    ADD CONSTRAINT "weather_forecast_snapshots_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."weather_forecasts"
    ADD CONSTRAINT "weather_forecasts_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."weather_observed_hourly"
    ADD CONSTRAINT "weather_observed_hourly_plot_id_fkey" FOREIGN KEY ("plot_id") REFERENCES "public"."plots"("id") ON DELETE CASCADE;



CREATE POLICY "Enable delete for users based on user_id" ON "public"."plots" FOR DELETE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Enable insert for users based on user_id" ON "public"."plots" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Enable users to view their own data only" ON "public"."plots" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Owner of this field can manage all things" ON "public"."nodes" TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Policy with table joins" ON "public"."plots" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Public delete fertilizer_products" ON "public"."fertilizer_products" FOR DELETE USING (true);



CREATE POLICY "Public insert fertilizer_products" ON "public"."fertilizer_products" FOR INSERT WITH CHECK (true);



CREATE POLICY "Public select fertigation_actions" ON "public"."fertigation_actions" FOR SELECT USING (true);



CREATE POLICY "Public select fertigation_recommendations" ON "public"."fertigation_recommendations" FOR SELECT USING (true);



CREATE POLICY "Public select fertilizer_products" ON "public"."fertilizer_products" FOR SELECT USING (true);



CREATE POLICY "Public select irrigation_actions" ON "public"."irrigation_actions" FOR SELECT USING (true);



CREATE POLICY "Public select irrigation_predictions" ON "public"."irrigation_predictions" FOR SELECT USING (true);



CREATE POLICY "Public select ml_feature_importance" ON "public"."ml_feature_importance" FOR SELECT USING (true);



CREATE POLICY "Public select ml_model_metrics" ON "public"."ml_model_metrics" FOR SELECT USING (true);



CREATE POLICY "Public select model_registries" ON "public"."model_registries" FOR SELECT USING (true);



CREATE POLICY "Public update fertilizer_products" ON "public"."fertilizer_products" FOR UPDATE USING (true) WITH CHECK (true);



CREATE POLICY "Users can delete own notifications" ON "public"."user_notifications" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert fertigation actions for their own plots" ON "public"."fertigation_actions" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "fertigation_actions"."plot_id") AND (("p"."user_id")::"text" = (( SELECT "auth"."uid"() AS "uid"))::"text")))));



CREATE POLICY "Users can insert irrigation actions for their own plots" ON "public"."irrigation_actions" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."plots"
  WHERE (("plots"."id" = "irrigation_actions"."plot_id") AND (("plots"."user_id")::"text" = ("auth"."uid"())::"text")))));



CREATE POLICY "Users can insert own notifications" ON "public"."user_notifications" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can manage own profile" ON "public"."profiles" TO "authenticated" USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can update irrigation actions for their own plots" ON "public"."irrigation_actions" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."plots"
  WHERE (("plots"."id" = "irrigation_actions"."plot_id") AND (("plots"."user_id")::"text" = ("auth"."uid"())::"text")))));



CREATE POLICY "Users can update own notifications" ON "public"."user_notifications" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view irrigation actions for their own plots" ON "public"."irrigation_actions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."plots"
  WHERE (("plots"."id" = "irrigation_actions"."plot_id") AND (("plots"."user_id")::"text" = ("auth"."uid"())::"text")))));



CREATE POLICY "Users can view own notifications" ON "public"."user_notifications" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."actuator_commands" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."calibrated_sensor_raw_readings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clock_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clock_events_ingest_all" ON "public"."clock_events" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "csrr_ingest_select" ON "public"."calibrated_sensor_raw_readings" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "csrr_owner_select" ON "public"."calibrated_sensor_raw_readings" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "calibrated_sensor_raw_readings"."plot_id") AND ("p"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))) OR (EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "calibrated_sensor_raw_readings"."node_id") AND ("n"."user_id" = ( SELECT "auth"."uid"() AS "uid")))))));



ALTER TABLE "public"."fertigation_actions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fertigation_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fertigation_config_select" ON "public"."fertigation_config" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "fertigation_config"."plot_id") AND ("p"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."fertigation_decisions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fertigation_decisions_select" ON "public"."fertigation_decisions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "fertigation_decisions"."plot_id") AND ("p"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."fertigation_dose_responses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fertigation_dose_responses_select" ON "public"."fertigation_dose_responses" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "fertigation_dose_responses"."plot_id") AND ("p"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."fertigation_recommendations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fertigation_rf_evaluations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "fertigation_rf_evaluations_select" ON "public"."fertigation_rf_evaluations" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."fertilizer_products" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ingest_all_commands" ON "public"."actuator_commands" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "ingest_read_batch_items" ON "public"."nutrient_batch_items" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "ingest_read_batches" ON "public"."nutrient_batches" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "ingest_read_config" ON "public"."node_actuator_config" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "ingest_read_products" ON "public"."fertilizer_products" FOR SELECT TO "smile_ingest" USING (true);



ALTER TABLE "public"."ingest_rejects" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ingest_rejects_ingest_insert" ON "public"."ingest_rejects" FOR INSERT TO "smile_ingest" WITH CHECK (true);



CREATE POLICY "ingest_v8_fertigation_actions" ON "public"."fertigation_actions" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "ingest_v8_fertigation_recommendations" ON "public"."fertigation_recommendations" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "ingest_v8_irrigation_actions" ON "public"."irrigation_actions" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "ingest_v8_irrigation_predictions" ON "public"."irrigation_predictions" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "ingest_v8_nodes" ON "public"."nodes" TO "smile_ingest" USING (true) WITH CHECK (true);



ALTER TABLE "public"."irrigation_actions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."irrigation_features" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."irrigation_predictions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lab_soil_tests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ml_feature_importance" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ml_model_metrics" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."model_registries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."node_actuator_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nodes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "nodes_ingest_read" ON "public"."nodes" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "nodes_ingest_touch" ON "public"."nodes" FOR UPDATE TO "smile_ingest" USING (true) WITH CHECK (true);



ALTER TABLE "public"."nutrient_batch_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nutrient_batches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "owner_batch_items" ON "public"."nutrient_batch_items" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."nutrient_batches" "b"
     JOIN "public"."nodes" "n" ON (("n"."id" = "b"."node_id")))
  WHERE (("b"."id" = "nutrient_batch_items"."batch_id") AND ("n"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."nutrient_batches" "b"
     JOIN "public"."nodes" "n" ON (("n"."id" = "b"."node_id")))
  WHERE (("b"."id" = "nutrient_batch_items"."batch_id") AND ("n"."user_id" = "auth"."uid"())))));



CREATE POLICY "owner_batches" ON "public"."nutrient_batches" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "nutrient_batches"."node_id") AND ("n"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "nutrient_batches"."node_id") AND ("n"."user_id" = "auth"."uid"())))));



CREATE POLICY "owner_insert_manual_commands" ON "public"."actuator_commands" FOR INSERT TO "authenticated" WITH CHECK ((("trigger" = 'manual'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "actuator_commands"."node_id") AND ("n"."user_id" = "auth"."uid"()))))));



CREATE POLICY "owner_rw_config" ON "public"."node_actuator_config" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "node_actuator_config"."node_id") AND ("n"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "node_actuator_config"."node_id") AND ("n"."user_id" = "auth"."uid"())))));



CREATE POLICY "owner_select_commands" ON "public"."actuator_commands" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "actuator_commands"."node_id") AND ("n"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."plant_phenology" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plot_soil_water_params" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plots" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "plots_ingest_select" ON "public"."plots" FOR SELECT TO "smile_ingest" USING (true);



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pswp_ingest_select" ON "public"."plot_soil_water_params" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "pswp_owner_insert" ON "public"."plot_soil_water_params" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "plot_soil_water_params"."plot_id") AND ("p"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "pswp_owner_select" ON "public"."plot_soil_water_params" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "plot_soil_water_params"."plot_id") AND ("p"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "read_global_or_own_products" ON "public"."fertilizer_products" FOR SELECT TO "authenticated" USING ((("owner_user_id" IS NULL) OR ("owner_user_id" = "auth"."uid"())));



CREATE POLICY "sc_ingest_select" ON "public"."sensor_calibrations" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "sc_owner_insert" ON "public"."sensor_calibrations" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "sensor_calibrations"."node_id") AND ("n"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "sc_owner_select" ON "public"."sensor_calibrations" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "sensor_calibrations"."node_id") AND ("n"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



ALTER TABLE "public"."sensor_calibrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sensor_raw_readings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sensor_raw_readings_ingest_all" ON "public"."sensor_raw_readings" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "srr_owner_select" ON "public"."sensor_raw_readings" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "sensor_raw_readings"."plot_id") AND ("p"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))) OR (EXISTS ( SELECT 1
   FROM "public"."nodes" "n"
  WHERE (("n"."id" = "sensor_raw_readings"."node_id") AND ("n"."user_id" = ( SELECT "auth"."uid"() AS "uid")))))));



ALTER TABLE "public"."user_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."water_balance_ledger" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "wbl_ingest_all" ON "public"."water_balance_ledger" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "wbl_owner_select" ON "public"."water_balance_ledger" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "water_balance_ledger"."plot_id") AND ("p"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



ALTER TABLE "public"."weather_forecast_snapshots" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."weather_forecasts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."weather_observed_hourly" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "wf_ingest_insert" ON "public"."weather_forecasts" FOR INSERT TO "smile_ingest" WITH CHECK (true);



CREATE POLICY "wf_ingest_select" ON "public"."weather_forecasts" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "wf_ingest_update" ON "public"."weather_forecasts" FOR UPDATE TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "wfs_ingest_insert" ON "public"."weather_forecast_snapshots" FOR INSERT TO "smile_ingest" WITH CHECK (true);



CREATE POLICY "wfs_ingest_select" ON "public"."weather_forecast_snapshots" FOR SELECT TO "smile_ingest" USING (true);



CREATE POLICY "wfs_owner_select" ON "public"."weather_forecast_snapshots" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "weather_forecast_snapshots"."plot_id") AND ("p"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "woh_ingest_all" ON "public"."weather_observed_hourly" TO "smile_ingest" USING (true) WITH CHECK (true);



CREATE POLICY "woh_owner_select" ON "public"."weather_observed_hourly" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."plots" "p"
  WHERE (("p"."id" = "weather_observed_hourly"."plot_id") AND ("p"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "write_own_products" ON "public"."fertilizer_products" TO "authenticated" USING (("owner_user_id" = "auth"."uid"())) WITH CHECK (("owner_user_id" = "auth"."uid"()));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."actuator_commands";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."calibrated_sensor_raw_readings";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."fertigation_actions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."fertigation_recommendations";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."fertilizer_products";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."irrigation_actions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."irrigation_predictions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."nodes";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."sensor_raw_readings";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."user_notifications";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "smile_ingest";











































































































































































REVOKE ALL ON FUNCTION "public"."approve_fertigation_recommendation"("p_recommendation_id" "uuid", "p_action" "text", "p_volume_ml" double precision, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_fertigation_recommendation"("p_recommendation_id" "uuid", "p_action" "text", "p_volume_ml" double precision, "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_fertigation_recommendation"("p_recommendation_id" "uuid", "p_action" "text", "p_volume_ml" double precision, "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_nutrient_batch"("p_node_id" "uuid", "p_solution_volume_l" double precision, "p_items" "jsonb", "p_name" "text", "p_measured_ec_uscm" double precision, "p_measured_ph" double precision, "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_nutrient_batch"("p_node_id" "uuid", "p_solution_volume_l" double precision, "p_items" "jsonb", "p_name" "text", "p_measured_ec_uscm" double precision, "p_measured_ph" double precision, "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_nutrient_batch"("p_node_id" "uuid", "p_solution_volume_l" double precision, "p_items" "jsonb", "p_name" "text", "p_measured_ec_uscm" double precision, "p_measured_ph" double precision, "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_actions_fill_plot_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_actions_fill_plot_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_actions_fill_plot_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_command_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_command_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_command_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_config_validate"() TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_config_validate"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_config_validate"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_ec_adj"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_ec_adj"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_ec_adj"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_ec_adj_config"("p_config_id" "uuid", "p_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_ec_adj_config"("p_config_id" "uuid", "p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_ec_adj_config"("p_config_id" "uuid", "p_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."fertigation_expire_recommendations"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fertigation_expire_recommendations"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_finite"("x" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_finite"("x" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_finite"("x" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_input_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_input_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_input_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_rain_24h"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_rain_24h"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_rain_24h"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_rain_config"("p_config" "uuid", "p_at" timestamp with time zone, "p_forecast" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_rain_config"("p_config" "uuid", "p_at" timestamp with time zone, "p_forecast" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_rain_config"("p_config" "uuid", "p_at" timestamp with time zone, "p_forecast" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_rain_forecast_12h"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_rain_forecast_12h"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_rain_forecast_12h"("p_plot_id" "uuid", "p_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."fertigation_record_response"("p_action_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fertigation_record_response"("p_action_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_response_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_response_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_response_guard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_rf_is_eligible"("p_model_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_rf_is_eligible"("p_model_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_rf_is_eligible"("p_model_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fertigation_stock_conc_g_per_l"("p_batch_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fertigation_stock_conc_g_per_l"("p_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fertigation_stock_conc_g_per_l"("p_batch_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_activate_nutrient_batch"() TO "anon";
GRANT ALL ON FUNCTION "public"."smile_activate_nutrient_batch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_activate_nutrient_batch"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_bump_config_version"() TO "anon";
GRANT ALL ON FUNCTION "public"."smile_bump_config_version"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_bump_config_version"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_cal_rainfall_mm"("p_tips" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_cal_rainfall_mm"("p_tips" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_cal_rainfall_mm"("p_tips" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_cal_soil_ec"("p_ec_raw" double precision, "p_temp_c" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_cal_soil_ec"("p_ec_raw" double precision, "p_temp_c" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_cal_soil_ec"("p_ec_raw" double precision, "p_temp_c" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_cal_soil_moisture"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_cal_soil_moisture"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_cal_soil_moisture"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_cal_soil_temperature"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_cal_soil_temperature"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_cal_soil_temperature"("p_node" "uuid", "p_raw" double precision, "p_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_calibrate"("p_node" "uuid", "p_param" "text", "p_raw" double precision, "p_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_calibrate"("p_node" "uuid", "p_param" "text", "p_raw" double precision, "p_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_calibrate"("p_node" "uuid", "p_param" "text", "p_raw" double precision, "p_at" timestamp with time zone) TO "service_role";
GRANT ALL ON FUNCTION "public"."smile_calibrate"("p_node" "uuid", "p_param" "text", "p_raw" double precision, "p_at" timestamp with time zone) TO "smile_ingest";



GRANT ALL ON FUNCTION "public"."smile_corrected_ts"("ts_raw" timestamp with time zone, "delta_s" integer, "start_verified" boolean, "seg_start" timestamp with time zone, "rtc_before" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_corrected_ts"("ts_raw" timestamp with time zone, "delta_s" integer, "start_verified" boolean, "seg_start" timestamp with time zone, "rtc_before" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_corrected_ts"("ts_raw" timestamp with time zone, "delta_s" integer, "start_verified" boolean, "seg_start" timestamp with time zone, "rtc_before" timestamp with time zone) TO "service_role";
GRANT ALL ON FUNCTION "public"."smile_corrected_ts"("ts_raw" timestamp with time zone, "delta_s" integer, "start_verified" boolean, "seg_start" timestamp with time zone, "rtc_before" timestamp with time zone) TO "smile_ingest";



GRANT ALL ON FUNCTION "public"."smile_dose_seconds"("p_batch_id" "uuid", "p_n_g" double precision, "p_p2o5_g" double precision, "p_k2o_g" double precision, "p_flow_ml_per_s" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_dose_seconds"("p_batch_id" "uuid", "p_n_g" double precision, "p_p2o5_g" double precision, "p_k2o_g" double precision, "p_flow_ml_per_s" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_dose_seconds"("p_batch_id" "uuid", "p_n_g" double precision, "p_p2o5_g" double precision, "p_k2o_g" double precision, "p_flow_ml_per_s" double precision) TO "service_role";
GRANT ALL ON FUNCTION "public"."smile_dose_seconds"("p_batch_id" "uuid", "p_n_g" double precision, "p_p2o5_g" double precision, "p_k2o_g" double precision, "p_flow_ml_per_s" double precision) TO "smile_ingest";



GRANT ALL ON FUNCTION "public"."smile_guard_actuator_command"() TO "anon";
GRANT ALL ON FUNCTION "public"."smile_guard_actuator_command"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_guard_actuator_command"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_guard_batch_item"() TO "anon";
GRANT ALL ON FUNCTION "public"."smile_guard_batch_item"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_guard_batch_item"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_guard_fertilizer_product"() TO "anon";
GRANT ALL ON FUNCTION "public"."smile_guard_fertilizer_product"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_guard_fertilizer_product"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_poly"("p_coeffs" double precision[], "p_x" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_poly"("p_coeffs" double precision[], "p_x" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_poly"("p_coeffs" double precision[], "p_x" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_raw_for_calibrated"("p_node" "uuid", "p_param" "text", "p_target" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_raw_for_calibrated"("p_node" "uuid", "p_param" "text", "p_target" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_raw_for_calibrated"("p_node" "uuid", "p_param" "text", "p_target" double precision) TO "service_role";
GRANT ALL ON FUNCTION "public"."smile_raw_for_calibrated"("p_node" "uuid", "p_param" "text", "p_target" double precision) TO "smile_ingest";



REVOKE ALL ON FUNCTION "public"."smile_recalibrate_readings"("p_node" "uuid", "p_from" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."smile_recalibrate_readings"("p_node" "uuid", "p_from" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."smile_refresh_node_thresholds"("p_node" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."smile_refresh_node_thresholds"("p_node" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_time_status"("delta_s" integer, "start_verified" boolean, "device_flags" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."smile_time_status"("delta_s" integer, "start_verified" boolean, "device_flags" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_time_status"("delta_s" integer, "start_verified" boolean, "device_flags" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."smile_time_status"("delta_s" integer, "start_verified" boolean, "device_flags" integer) TO "smile_ingest";



REVOKE ALL ON FUNCTION "public"."smile_trg_calibrate_reading"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."smile_trg_calibrate_reading"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."smile_trg_recalibrate_from_calibration"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."smile_trg_recalibrate_from_calibration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_calibration"() TO "anon";
GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_calibration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_calibration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_config"() TO "anon";
GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_config"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_config"() TO "service_role";



GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_params"() TO "anon";
GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_params"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smile_trg_refresh_from_params"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_node_pump_state"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_node_pump_state"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_node_valve_state"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_node_valve_state"() TO "service_role";
























GRANT ALL ON TABLE "public"."actuator_commands" TO "authenticated";
GRANT ALL ON TABLE "public"."actuator_commands" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."actuator_commands" TO "smile_ingest";



GRANT ALL ON TABLE "public"."calibrated_sensor_raw_readings" TO "service_role";
GRANT SELECT ON TABLE "public"."calibrated_sensor_raw_readings" TO "authenticated";
GRANT SELECT ON TABLE "public"."calibrated_sensor_raw_readings" TO "smile_ingest";



GRANT ALL ON SEQUENCE "public"."calibrated_sensor_raw_readings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."clock_events" TO "anon";
GRANT ALL ON TABLE "public"."clock_events" TO "authenticated";
GRANT ALL ON TABLE "public"."clock_events" TO "service_role";
GRANT SELECT,INSERT ON TABLE "public"."clock_events" TO "smile_ingest";



GRANT ALL ON SEQUENCE "public"."clock_events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."clock_events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."clock_events_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."fertigation_actions" TO "anon";
GRANT ALL ON TABLE "public"."fertigation_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."fertigation_actions" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."fertigation_actions" TO "smile_ingest";



GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_config" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_config" TO "authenticated";
GRANT ALL ON TABLE "public"."fertigation_config" TO "service_role";



GRANT ALL ON TABLE "public"."fertigation_config_active" TO "anon";
GRANT ALL ON TABLE "public"."fertigation_config_active" TO "authenticated";
GRANT ALL ON TABLE "public"."fertigation_config_active" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_decisions" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_decisions" TO "authenticated";
GRANT ALL ON TABLE "public"."fertigation_decisions" TO "service_role";



GRANT ALL ON TABLE "public"."nutrient_batch_concentration" TO "anon";
GRANT ALL ON TABLE "public"."nutrient_batch_concentration" TO "authenticated";
GRANT ALL ON TABLE "public"."nutrient_batch_concentration" TO "service_role";
GRANT SELECT ON TABLE "public"."nutrient_batch_concentration" TO "smile_ingest";



GRANT ALL ON TABLE "public"."fertigation_delivered" TO "anon";
GRANT ALL ON TABLE "public"."fertigation_delivered" TO "authenticated";
GRANT ALL ON TABLE "public"."fertigation_delivered" TO "service_role";
GRANT SELECT ON TABLE "public"."fertigation_delivered" TO "smile_ingest";



GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_dose_responses" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_dose_responses" TO "authenticated";
GRANT ALL ON TABLE "public"."fertigation_dose_responses" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_recommendations" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_recommendations" TO "authenticated";
GRANT ALL ON TABLE "public"."fertigation_recommendations" TO "service_role";
GRANT SELECT ON TABLE "public"."fertigation_recommendations" TO "smile_ingest";



GRANT UPDATE("dispatched_command_id") ON TABLE "public"."fertigation_recommendations" TO "smile_ingest";



GRANT UPDATE("dispatch_note") ON TABLE "public"."fertigation_recommendations" TO "smile_ingest";



GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_rf_evaluations" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."fertigation_rf_evaluations" TO "authenticated";
GRANT ALL ON TABLE "public"."fertigation_rf_evaluations" TO "service_role";



GRANT ALL ON TABLE "public"."fertilizer_products" TO "anon";
GRANT ALL ON TABLE "public"."fertilizer_products" TO "authenticated";
GRANT ALL ON TABLE "public"."fertilizer_products" TO "service_role";
GRANT SELECT ON TABLE "public"."fertilizer_products" TO "smile_ingest";



GRANT ALL ON TABLE "public"."ingest_rejects" TO "anon";
GRANT ALL ON TABLE "public"."ingest_rejects" TO "authenticated";
GRANT ALL ON TABLE "public"."ingest_rejects" TO "service_role";
GRANT INSERT ON TABLE "public"."ingest_rejects" TO "smile_ingest";



GRANT ALL ON SEQUENCE "public"."ingest_rejects_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ingest_rejects_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ingest_rejects_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."irrigation_actions" TO "anon";
GRANT ALL ON TABLE "public"."irrigation_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."irrigation_actions" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."irrigation_actions" TO "smile_ingest";



GRANT ALL ON TABLE "public"."irrigation_features" TO "anon";
GRANT ALL ON TABLE "public"."irrigation_features" TO "authenticated";
GRANT ALL ON TABLE "public"."irrigation_features" TO "service_role";



GRANT ALL ON TABLE "public"."irrigation_predictions" TO "anon";
GRANT ALL ON TABLE "public"."irrigation_predictions" TO "authenticated";
GRANT ALL ON TABLE "public"."irrigation_predictions" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."irrigation_predictions" TO "smile_ingest";



GRANT UPDATE("dispatched_command_id") ON TABLE "public"."irrigation_predictions" TO "smile_ingest";



GRANT UPDATE("dispatch_note") ON TABLE "public"."irrigation_predictions" TO "smile_ingest";



GRANT ALL ON TABLE "public"."lab_soil_tests" TO "anon";
GRANT ALL ON TABLE "public"."lab_soil_tests" TO "authenticated";
GRANT ALL ON TABLE "public"."lab_soil_tests" TO "service_role";



GRANT ALL ON TABLE "public"."ml_feature_importance" TO "anon";
GRANT ALL ON TABLE "public"."ml_feature_importance" TO "authenticated";
GRANT ALL ON TABLE "public"."ml_feature_importance" TO "service_role";



GRANT ALL ON TABLE "public"."ml_model_metrics" TO "anon";
GRANT ALL ON TABLE "public"."ml_model_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."ml_model_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."model_registries" TO "anon";
GRANT ALL ON TABLE "public"."model_registries" TO "authenticated";
GRANT ALL ON TABLE "public"."model_registries" TO "service_role";



GRANT ALL ON TABLE "public"."ml_models" TO "anon";
GRANT ALL ON TABLE "public"."ml_models" TO "authenticated";
GRANT ALL ON TABLE "public"."ml_models" TO "service_role";



GRANT ALL ON TABLE "public"."node_actuator_config" TO "authenticated";
GRANT ALL ON TABLE "public"."node_actuator_config" TO "service_role";
GRANT SELECT ON TABLE "public"."node_actuator_config" TO "smile_ingest";



GRANT ALL ON TABLE "public"."nodes" TO "anon";
GRANT ALL ON TABLE "public"."nodes" TO "authenticated";
GRANT ALL ON TABLE "public"."nodes" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("user_id") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("plot_id") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("status") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT UPDATE("firmware_version") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("created_at") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("api_token_hash") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT UPDATE("last_seen_at") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("valve_is_on"),UPDATE("valve_is_on") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("valve_mode") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT UPDATE("valve_updated_at") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("pump_is_on"),UPDATE("pump_is_on") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("pump_mode") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT UPDATE("pump_updated_at") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT SELECT("rain_mm_per_tip") ON TABLE "public"."nodes" TO "smile_ingest";



GRANT ALL ON TABLE "public"."nutrient_batch_items" TO "authenticated";
GRANT ALL ON TABLE "public"."nutrient_batch_items" TO "service_role";
GRANT SELECT ON TABLE "public"."nutrient_batch_items" TO "smile_ingest";



GRANT ALL ON TABLE "public"."nutrient_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."nutrient_batches" TO "service_role";
GRANT SELECT ON TABLE "public"."nutrient_batches" TO "smile_ingest";



GRANT ALL ON TABLE "public"."plant_phenology" TO "anon";
GRANT ALL ON TABLE "public"."plant_phenology" TO "authenticated";
GRANT ALL ON TABLE "public"."plant_phenology" TO "service_role";



GRANT ALL ON TABLE "public"."plot_soil_water_params" TO "anon";
GRANT ALL ON TABLE "public"."plot_soil_water_params" TO "authenticated";
GRANT ALL ON TABLE "public"."plot_soil_water_params" TO "service_role";
GRANT SELECT ON TABLE "public"."plot_soil_water_params" TO "smile_ingest";



GRANT ALL ON TABLE "public"."plot_water_params_current" TO "anon";
GRANT ALL ON TABLE "public"."plot_water_params_current" TO "authenticated";
GRANT ALL ON TABLE "public"."plot_water_params_current" TO "service_role";
GRANT SELECT ON TABLE "public"."plot_water_params_current" TO "smile_ingest";



GRANT ALL ON TABLE "public"."plots" TO "anon";
GRANT ALL ON TABLE "public"."plots" TO "authenticated";
GRANT ALL ON TABLE "public"."plots" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."plots" TO "smile_ingest";



GRANT SELECT("location_lat") ON TABLE "public"."plots" TO "smile_ingest";



GRANT SELECT("location_lng") ON TABLE "public"."plots" TO "smile_ingest";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."sensor_raw_readings" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."sensor_raw_readings" TO "smile_ingest";
GRANT SELECT ON TABLE "public"."sensor_raw_readings" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."raw_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."raw_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."raw_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sensor_calibrations" TO "anon";
GRANT ALL ON TABLE "public"."sensor_calibrations" TO "authenticated";
GRANT ALL ON TABLE "public"."sensor_calibrations" TO "service_role";
GRANT SELECT ON TABLE "public"."sensor_calibrations" TO "smile_ingest";



GRANT ALL ON TABLE "public"."user_notifications" TO "anon";
GRANT ALL ON TABLE "public"."user_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."user_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."v_fertigation_formula_examples" TO "anon";
GRANT ALL ON TABLE "public"."v_fertigation_formula_examples" TO "authenticated";
GRANT ALL ON TABLE "public"."v_fertigation_formula_examples" TO "service_role";



GRANT ALL ON TABLE "public"."v_fertigation_pending" TO "anon";
GRANT ALL ON TABLE "public"."v_fertigation_pending" TO "authenticated";
GRANT ALL ON TABLE "public"."v_fertigation_pending" TO "service_role";



GRANT ALL ON TABLE "public"."v_fertigation_training_data" TO "anon";
GRANT ALL ON TABLE "public"."v_fertigation_training_data" TO "authenticated";
GRANT ALL ON TABLE "public"."v_fertigation_training_data" TO "service_role";



GRANT ALL ON TABLE "public"."water_balance_ledger" TO "anon";
GRANT ALL ON TABLE "public"."water_balance_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."water_balance_ledger" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."water_balance_ledger" TO "smile_ingest";



GRANT ALL ON SEQUENCE "public"."water_balance_ledger_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."water_balance_ledger_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."water_balance_ledger_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."weather_forecast_snapshots" TO "service_role";
GRANT SELECT ON TABLE "public"."weather_forecast_snapshots" TO "authenticated";
GRANT SELECT,INSERT ON TABLE "public"."weather_forecast_snapshots" TO "smile_ingest";



GRANT ALL ON SEQUENCE "public"."weather_forecast_snapshots_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."weather_forecast_snapshots_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."weather_forecast_snapshots_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."weather_forecasts" TO "anon";
GRANT ALL ON TABLE "public"."weather_forecasts" TO "authenticated";
GRANT ALL ON TABLE "public"."weather_forecasts" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."weather_forecasts" TO "smile_ingest";



GRANT ALL ON TABLE "public"."weather_observed_hourly" TO "service_role";
GRANT SELECT ON TABLE "public"."weather_observed_hourly" TO "authenticated";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."weather_observed_hourly" TO "smile_ingest";



GRANT ALL ON SEQUENCE "public"."weather_observed_hourly_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."weather_observed_hourly_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."weather_observed_hourly_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































