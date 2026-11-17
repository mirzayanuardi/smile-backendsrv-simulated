## Table `profiles`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `full_name` | `text` |  Nullable |
| `email` | `text` |  Nullable |
| `avatar_url` | `text` |  Nullable |
| `created_at` | `timestamptz` |  |
| `updated_at` | `timestamptz` |  |
| `fcm_token` | `text` |  Nullable |

## Table `sensor_raw_readings`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `int8` | Primary Identity |
| `reading_timestamp` | `timestamptz` |  Nullable |
| `soil_moisture_pct` | `float8` |  Nullable |
| `soil_temperature_c` | `float8` |  Nullable |
| `soil_ec_uscm` | `float8` |  Nullable |
| `soil_ph` | `float4` |  Nullable |
| `rainfall_tip_count` | `int8` |  Nullable |
| `rainfall_mm` | `float8` |  Nullable |
| `quality_flag` | `text` |  Nullable |
| `air_temperature_c` | `float8` |  Nullable |
| `air_humidity_pct` | `float8` |  Nullable |
| `node_id` | `uuid` |  Nullable |
| `plot_id` | `uuid` |  Nullable |
| `soil_n_mgkg` | `float8` |  Nullable |
| `soil_p_mgkg` | `float8` |  Nullable |
| `soil_k_mgkg` | `float8` |  Nullable |
| `reading_timestamp_raw` | `timestamptz` |  Nullable |
| `clock_segment` | `text` |  Nullable |
| `uptime_s` | `int8` |  Nullable |
| `device_flags` | `int4` |  Nullable |
| `time_status` | `text` |  Nullable |
| `ingested_at` | `timestamptz` |  |

## Table `plots`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `user_id` | `uuid` |  |
| `plot_name` | `varchar` |  |
| `area_m2` | `float8` |  Nullable |
| `planting_date` | `date` |  Nullable |
| `location_lat` | `text` |  Nullable |
| `location_lng` | `text` |  Nullable |
| `picture_url` | `text` |  Nullable |
| `notes` | `text` |  Nullable |
| `created_at` | `timestamptz` |  |

## Table `nodes`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `user_id` | `uuid` |  |
| `plot_id` | `uuid` |  |
| `model` | `varchar` |  Nullable |
| `install_date` | `date` |  Nullable |
| `last_calibration_date` | `date` |  Nullable |
| `status` | `node_status` |  |
| `notes` | `text` |  Nullable |
| `mac_address` | `text` |  Nullable |
| `firmware_version` | `text` |  Nullable |
| `created_at` | `timestamptz` |  |
| `api_token_hash` | `text` |  Nullable |
| `last_seen_at` | `timestamptz` |  Nullable |
| `valve_is_on` | `bool` |  |
| `valve_mode` | `text` |  |
| `valve_updated_at` | `timestamptz` |  Nullable |
| `pump_is_on` | `bool` |  |
| `pump_mode` | `text` |  |
| `pump_updated_at` | `timestamptz` |  Nullable |
| `rain_mm_per_tip` | `float8` |  Nullable |

## Table `fertilizer_products`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `name` | `varchar` |  |
| `n_pct` | `float8` |  |
| `p_pct` | `float8` |  |
| `k_pct` | `float8` |  |
| `density_g_per_ml` | `float8` |  Nullable |
| `notes` | `text` |  Nullable |
| `created_at` | `timestamptz` |  |
| `id` | `uuid` | Primary |
| `owner_user_id` | `uuid` |  Nullable |
| `is_verified` | `bool` |  |
| `form` | `text` |  |

## Table `plant_phenology`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `plot_id` | `uuid` |  |
| `plant_phase` | `plant_phase` |  |
| `plant_age_months` | `int4` |  |
| `effective_date` | `date` |  |
| `notes` | `text` |  Nullable |
| `created_at` | `timestamptz` |  |
| `id` | `uuid` | Primary |

## Table `model_registries`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `name` | `varchar` |  |
| `type` | `model_type` |  |
| `task` | `task_type` |  |
| `trained_date` | `date` |  Nullable |
| `metrics_json` | `jsonb` |  Nullable |
| `is_active` | `bool` |  |
| `created_at` | `timestamptz` |  |
| `version` | `varchar` |  Nullable |
| `horizons` | `varchar` |  Nullable |
| `training_samples` | `varchar` |  Nullable |
| `last_ml_output` | `timestamptz` |  Nullable |
| `ec_response_model` | `varchar` |  Nullable |

## Table `lab_soil_tests`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `plot_id` | `uuid` |  |
| `lab_name` | `varchar` |  |
| `sample_date` | `date` |  |
| `lab_n_pct` | `float8` |  Nullable |
| `lab_p_pct` | `float8` |  Nullable |
| `lab_k_pct` | `float8` |  Nullable |
| `lab_ec_uscm` | `float8` |  Nullable |
| `lab_ph` | `float8` |  Nullable |
| `notes` | `text` |  Nullable |
| `created_at` | `timestamptz` |  |

## Table `weather_forecasts`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `plot_id` | `uuid` |  |
| `forecast_issued_at` | `timestamptz` |  |
| `valid_for_timestamp` | `timestamptz` |  |
| `forecast_rainfall_mm` | `float8` |  Nullable |
| `forecast_temperature_c` | `float8` |  Nullable |
| `forecast_humidity_pct` | `float8` |  Nullable |
| `source` | `source_type` |  Nullable |
| `created_at` | `timestamptz` |  |
| `forecast_eto_mm` | `float8` |  Nullable |

## Table `fertigation_recommendations`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `plot_id` | `uuid` |  |
| `model_id` | `uuid` |  |
| `recommendation_timestamp` | `timestamptz` |  |
| `dosis_dasar_g` | `float8` |  Nullable |
| `modulation_factor` | `float8` |  Nullable |
| `final_dose_g` | `float8` |  Nullable |
| `volume_pump_ml` | `float8` |  Nullable |
| `pump_duration_seconds` | `float8` |  Nullable |
| `ec_pori_source_reading_id` | `int8` |  Nullable |
| `ec_pori_latest` | `float8` |  Nullable |
| `ec_pori_prediction` | `float8` |  Nullable |
| `status` | `fertigation_recommendation_type` |  Nullable |
| `confidence_low` | `float8` |  Nullable |
| `confidence_high` | `float8` |  Nullable |
| `reason` | `text` |  Nullable |
| `base_dose_source` | `varchar` |  Nullable |
| `created_at` | `timestamptz` |  |
| `plant_phenology_id` | `uuid` |  Nullable |
| `fertilizer_product_id` | `uuid` |  Nullable |
| `dispatched_command_id` | `uuid` |  Nullable |
| `dispatch_note` | `text` |  Nullable |
| `target_n_g` | `float8` |  Nullable |
| `target_p2o5_g` | `float8` |  Nullable |
| `target_k2o_g` | `float8` |  Nullable |
| `nutrient_batch_id` | `uuid` |  Nullable |

## Table `fertigation_actions`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `recommendation_id` | `uuid` |  Nullable |
| `execution_timestamp` | `timestamptz` |  |
| `executed_by` | `fertigation_action_type` |  Nullable |
| `actual_volume` | `float8` |  Nullable |
| `actual_duration_sec` | `float8` |  Nullable |
| `execution_status` | `execution_status` |  Nullable |
| `created_at` | `timestamptz` |  |
| `plot_id` | `uuid` |  Nullable |
| `pump_action` | `text` |  Nullable |
| `node_id` | `uuid` |  Nullable |
| `command_id` | `uuid` |  Nullable |
| `device_event_id` | `text` |  Nullable |
| `clock_segment` | `text` |  Nullable |
| `execution_timestamp_raw` | `timestamptz` |  Nullable |
| `detail` | `text` |  Nullable |
| `nutrient_batch_id` | `uuid` |  Nullable |

## Table `irrigation_features`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `plot_id` | `uuid` |  |
| `feature_timestamp` | `timestamptz` |  |
| `soil_moisture_lag_1h` | `float8` |  Nullable |
| `soil_moisture_lag_3h` | `float8` |  Nullable |
| `soil_moisture_lag_6h` | `float8` |  Nullable |
| `delta_moisture_1h` | `float8` |  Nullable |
| `delta_moisture_3h` | `float8` |  Nullable |
| `delta_moisture_6h` | `float8` |  Nullable |
| `rainfall_acc_1h` | `float8` |  Nullable |
| `rainfall_acc_6h` | `float8` |  Nullable |
| `rainfall_acc_24h` | `float8` |  Nullable |
| `hour_sin` | `float8` |  Nullable |
| `hour_cos` | `float8` |  Nullable |
| `day_of_year_sin` | `float8` |  Nullable |
| `day_of_year_cos` | `float8` |  Nullable |
| `created_at` | `timestamptz` |  |

## Table `irrigation_predictions`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `plot_id` | `uuid` |  |
| `model_id` | `uuid` |  Nullable |
| `prediction_timestamp` | `timestamptz` |  |
| `predicted_soil_moisture` | `float8` |  Nullable |
| `prediction_error_margin` | `float8` |  Nullable |
| `status_model` | `model_status` |  Nullable |
| `prediction_dr_value` | `float8` |  Nullable |
| `raw_value` | `float8` |  Nullable |
| `irrigation_triggered` | `bool` |  Nullable |
| `created_at` | `timestamptz` |  |
| `reason` | `text` |  Nullable |
| `recommended_irrigation_mm` | `float8` |  Nullable |
| `dispatched_command_id` | `uuid` |  Nullable |
| `dispatch_note` | `text` |  Nullable |
| `decision_layer` | `text` |  Nullable |
| `dr_value_fao56` | `float8` |  Nullable |
| `taw_mm` | `float8` |  Nullable |
| `raw_mm` | `float8` |  Nullable |
| `dr_forecast_24h_mm` | `float8` |  Nullable |
| `etc_forecast_24h_mm` | `float8` |  Nullable |
| `rain_forecast_12h_mm` | `float8` |  Nullable |
| `ledger_id` | `int8` |  Nullable |

## Table `irrigation_actions`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `plot_id` | `uuid` |  |
| `irrigation_prediction_id` | `uuid` |  Nullable |
| `action_timestamp` | `timestamptz` |  |
| `triggered_by` | `trigger_type` |  Nullable |
| `valve_action` | `valve_action_status` |  Nullable |
| `duration_sec` | `int8` |  Nullable |
| `estimated_volume_liter` | `float8` |  Nullable |
| `execution_status` | `execution_status` |  Nullable |
| `created_at` | `timestamptz` |  |
| `node_id` | `uuid` |  Nullable |
| `command_id` | `uuid` |  Nullable |
| `device_event_id` | `text` |  Nullable |
| `clock_segment` | `text` |  Nullable |
| `action_timestamp_raw` | `timestamptz` |  Nullable |
| `detail` | `text` |  Nullable |

## Table `calibrated_sensor_raw_readings`

This is a calibrated version of sensor_raw_readings

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `int8` | Primary Identity |
| `reading_timestamp` | `timestamptz` |  Nullable |
| `soil_moisture_pct` | `float8` |  Nullable |
| `soil_temperature_c` | `float8` |  Nullable |
| `soil_ec_uscm` | `float8` |  Nullable |
| `soil_ph` | `float4` |  Nullable |
| `rainfall_tip_count` | `int8` |  Nullable |
| `rainfall_mm` | `float8` |  Nullable |
| `quality_flag` | `text` |  Nullable |
| `air_temperature_c` | `float8` |  Nullable |
| `air_humidity_pct` | `float8` |  Nullable |
| `node_id` | `uuid` |  Nullable |
| `plot_id` | `uuid` |  Nullable |
| `soil_n_mgkg` | `float8` |  Nullable |
| `soil_p_mgkg` | `float8` |  Nullable |
| `soil_k_mgkg` | `float8` |  Nullable |
| `raw_reading_id` | `int8` |  Nullable |
| `calibrated_at` | `timestamptz` |  |

## Table `clock_events`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `int8` | Primary Identity |
| `node_id` | `uuid` |  |
| `clock_segment` | `text` |  |
| `rtc_before` | `timestamptz` |  |
| `ref_time` | `timestamptz` |  |
| `delta_s` | `int4` |  |
| `start_verified` | `bool` |  |
| `segment_start` | `timestamptz` |  Nullable |
| `ref_source` | `text` |  |
| `received_at` | `timestamptz` |  |

## Table `ingest_rejects`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `int8` | Primary Identity |
| `node_id` | `uuid` |  Nullable |
| `endpoint` | `text` |  |
| `line_no` | `int4` |  Nullable |
| `raw_line` | `text` |  Nullable |
| `reason` | `text` |  |
| `received_at` | `timestamptz` |  |

## Table `ml_model_metrics`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `model_id` | `uuid` |  Nullable |
| `horizon` | `varchar` |  |
| `model_name` | `varchar` |  |
| `rank_type` | `varchar` |  |
| `rmse` | `float8` |  |
| `mae` | `float8` |  |
| `r2` | `float8` |  |
| `created_at` | `timestamptz` |  |

## Table `ml_feature_importance`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `model_id` | `uuid` |  Nullable |
| `feature_name` | `varchar` |  |
| `importance_pct` | `float8` |  |
| `sort_order` | `int4` |  |
| `created_at` | `timestamptz` |  |

## Table `node_actuator_config`

Konfigurasi aktuator per node. Dikirim ke ESP saat config_version berubah. Firmware tetap memakai batas kerasnya sendiri.

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `node_id` | `uuid` | Primary |
| `has_irrigation` | `bool` |  |
| `has_fertigation` | `bool` |  |
| `water_flow_lpm` | `float8` |  Nullable |
| `dose_flow_ml_per_s` | `float8` |  Nullable |
| `wetted_area_m2` | `float8` |  Nullable |
| `max_run_s` | `int4` |  |
| `max_water_day_s` | `int4` |  |
| `max_dose_day_s` | `int4` |  |
| `min_gap_s` | `int4` |  |
| `flush_s` | `int4` |  |
| `fallback_threshold_raw` | `float8` |  Nullable |
| `fallback_run_s` | `int4` |  |
| `fallback_offline_h` | `int4` |  |
| `morning_start_hour` | `int4` |  |
| `morning_end_hour` | `int4` |  |
| `config_version` | `int4` |  |
| `updated_at` | `timestamptz` |  |
| `prewet_s` | `int4` |  |
| `stop_moisture_raw` | `float8` |  Nullable |
| `thresholds_auto` | `bool` |  |

## Table `actuator_commands`

Perintah berdurasi untuk ESP. Ditulis app (manual) atau server (rule_engine/schedule). ESP tidak pernah menerima perintah "nyala" tanpa durasi.

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `node_id` | `uuid` |  |
| `plot_id` | `uuid` |  |
| `command` | `text` |  |
| `water_s` | `int4` |  Nullable |
| `dose_s` | `int4` |  Nullable |
| `trigger` | `text` |  |
| `irrigation_prediction_id` | `uuid` |  Nullable |
| `fertigation_recommendation_id` | `uuid` |  Nullable |
| `reason` | `text` |  Nullable |
| `status` | `text` |  |
| `created_by` | `uuid` |  Nullable |
| `created_at` | `timestamptz` |  |
| `expires_at` | `timestamptz` |  |
| `sent_at` | `timestamptz` |  Nullable |
| `started_at` | `timestamptz` |  Nullable |
| `finished_at` | `timestamptz` |  Nullable |
| `actual_water_s` | `int4` |  Nullable |
| `actual_dose_s` | `int4` |  Nullable |
| `result_detail` | `text` |  Nullable |
| `nutrient_batch_id` | `uuid` |  Nullable |

## Table `nutrient_batches`

Larutan yang sedang/pernah ada di tangki pupuk node. Satu batch aktif per node. Batch baru otomatis menonaktifkan yang lama.

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `node_id` | `uuid` |  |
| `name` | `text` |  Nullable |
| `solution_volume_l` | `float8` |  |
| `prepared_at` | `timestamptz` |  |
| `measured_ec_uscm` | `float8` |  Nullable |
| `measured_ph` | `float8` |  Nullable |
| `notes` | `text` |  Nullable |
| `is_active` | `bool` |  |
| `deactivated_at` | `timestamptz` |  Nullable |
| `created_by` | `uuid` |  Nullable |
| `created_at` | `timestamptz` |  |

## Table `nutrient_batch_items`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `batch_id` | `uuid` |  |
| `product_id` | `uuid` |  |
| `amount_g` | `float8` |  Nullable |
| `amount_ml` | `float8` |  Nullable |

## Table `plot_soil_water_params`

Parameter neraca air FAO-56 per plot. Berversi lewat valid_from; jangan di-update, insert baris baru.

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `plot_id` | `uuid` |  |
| `theta_fc_pct` | `float8` |  |
| `theta_pwp_pct` | `float8` |  |
| `p_frac` | `float8` |  |
| `zr_mm` | `float8` |  |
| `kc` | `float8` |  |
| `source` | `text` |  |
| `notes` | `text` |  Nullable |
| `valid_from` | `timestamptz` |  |
| `created_by` | `uuid` |  Nullable |
| `created_at` | `timestamptz` |  |

## Table `sensor_calibrations`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `uuid` | Primary |
| `node_id` | `uuid` |  |
| `parameter` | `text` |  |
| `coeffs` | `_float8` |  |
| `raw_min` | `float8` |  |
| `raw_max` | `float8` |  |
| `r2` | `float8` |  Nullable |
| `n_points` | `int4` |  Nullable |
| `source` | `text` |  |
| `notes` | `text` |  Nullable |
| `valid_from` | `timestamptz` |  |
| `created_by` | `uuid` |  Nullable |
| `created_at` | `timestamptz` |  |

## Table `water_balance_ledger`

Neraca air FAO-56 per jam (Layer 1). Ditulis server; 48 jam terakhir dihitung ulang tiap siklus agar data offline yang telat masuk ikut terhitung.

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `int8` | Primary Identity |
| `plot_id` | `uuid` |  |
| `node_id` | `uuid` |  Nullable |
| `period_start` | `timestamptz` |  |
| `period_end` | `timestamptz` |  |
| `params_id` | `uuid` |  Nullable |
| `eto_mm` | `float8` |  Nullable |
| `eto_source` | `text` |  |
| `kc` | `float8` |  Nullable |
| `etc_mm` | `float8` |  |
| `rain_mm` | `float8` |  |
| `rain_source` | `text` |  |
| `irrigation_mm` | `float8` |  |
| `dp_mm` | `float8` |  |
| `dr_start_mm` | `float8` |  |
| `dr_model_mm` | `float8` |  |
| `theta_obs_raw` | `float8` |  Nullable |
| `theta_obs_pct` | `float8` |  Nullable |
| `dr_obs_mm` | `float8` |  Nullable |
| `dr_end_mm` | `float8` |  |
| `corrected` | `bool` |  |
| `taw_mm` | `float8` |  Nullable |
| `raw_mm` | `float8` |  Nullable |
| `calibration_status` | `text` |  |
| `computed_at` | `timestamptz` |  |

## Table `user_notifications`

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `text` | Primary |
| `user_id` | `uuid` |  |
| `title` | `text` |  |
| `body` | `text` |  |
| `type` | `text` |  Nullable |
| `data` | `jsonb` |  Nullable |
| `is_read` | `bool` |  |
| `created_at` | `timestamptz` |  |

## Table `weather_forecast_snapshots`

Arsip prakiraan Open-Meteo per jam untuk ML. Append-only: satu set baris per fetch (issued_at).

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `int8` | Primary Identity |
| `plot_id` | `uuid` |  |
| `source` | `text` |  |
| `model` | `text` |  |
| `issued_at` | `timestamptz` |  |
| `valid_time` | `timestamptz` |  |
| `lead_hours` | `int4` |  |
| `precipitation_mm` | `float8` |  Nullable |
| `precipitation_probability` | `float8` |  Nullable |
| `et0_fao_mm` | `float8` |  Nullable |
| `temperature_2m` | `float8` |  Nullable |
| `relative_humidity_2m` | `float8` |  Nullable |
| `wind_speed_10m` | `float8` |  Nullable |
| `shortwave_radiation` | `float8` |  Nullable |
| `fetched_at` | `timestamptz` |  |

## Table `weather_observed_hourly`

Cuaca reanalisis Open-Meteo archive per jam (UTC). Nilai hari-hari terakhir bisa direvisi oleh job harian.

### Columns

| Name | Type | Constraints |
|------|------|-------------|
| `id` | `int8` | Primary Identity |
| `plot_id` | `uuid` |  |
| `source` | `text` |  |
| `time` | `timestamptz` |  |
| `precipitation_mm` | `float8` |  Nullable |
| `temperature_2m` | `float8` |  Nullable |
| `relative_humidity_2m` | `float8` |  Nullable |
| `wind_speed_10m` | `float8` |  Nullable |
| `shortwave_radiation` | `float8` |  Nullable |
| `et0_fao_mm` | `float8` |  Nullable |
| `updated_at` | `timestamptz` |  |

## Custom Types / Enums

### `device_status`

`normal` | `maintenance` | `broken`

### `sensor_type`

`7in1` | `rainfall`

### `node_status`

`active` | `retired` | `maintenance`

### `plant_phase`

`immature` | `early_bearing` | `mature_bearing`

### `model_type`

`random_forest` | `xgboost` | `persistence_baseline` | `quantile_rf`

### `task_type`

`irrigation` | `fertigation`

### `source_type`

`BMKG` | `NASA_POWER` | `ERA5` | `onsite_station` | `open_meteo`

### `fertigation_recommendation_type`

`naikkan` | `normal` | `tunda` | `blokir`

### `fertigation_action_type`

`auto` | `manual`

### `execution_status`

`success` | `failed` | `skipped` | `overridden`

### `model_status`

`reliable` | `uncertain` | `fallback`

### `trigger_type`

`rule_engine` | `manual` | `schedule` | `local_fallback`

### `valve_action_status`

`open` | `close`

## RLS Policies

### `clock_events`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `clock_events_ingest_all` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |

### `ingest_rejects`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `ingest_rejects_ingest_insert` | INSERT | smile_ingest | PERMISSIVE | — | `true` |

### `profiles`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Users can manage own profile` | ALL | authenticated | PERMISSIVE | `(auth.uid() = id)` | `(auth.uid() = id)` |

### `sensor_raw_readings`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `sensor_raw_readings_ingest_all` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |
| `srr_owner_select` | SELECT | authenticated | PERMISSIVE | `((EXISTS ( SELECT 1    FROM plots p   WHERE ((p.id = sensor_raw_readings.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = sensor_raw_readings.node_id) AND (n.user_id = ( SELECT auth.uid() AS uid))))))` | — |

### `nodes`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `nodes_ingest_read` | SELECT | smile_ingest | PERMISSIVE | `true` | — |
| `nodes_ingest_touch` | UPDATE | smile_ingest | PERMISSIVE | `true` | `true` |
| `ingest_v8_nodes` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |
| `Owner of this field can manage all things` | ALL | authenticated | PERMISSIVE | `(auth.uid() = user_id)` | — |

### `ml_model_metrics`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Public select ml_model_metrics` | SELECT | public | PERMISSIVE | `true` | — |

### `ml_feature_importance`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Public select ml_feature_importance` | SELECT | public | PERMISSIVE | `true` | — |

### `model_registries`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Public select model_registries` | SELECT | public | PERMISSIVE | `true` | — |

### `irrigation_predictions`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Public select irrigation_predictions` | SELECT | public | PERMISSIVE | `true` | — |
| `ingest_v8_irrigation_predictions` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |

### `fertigation_recommendations`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Public select fertigation_recommendations` | SELECT | public | PERMISSIVE | `true` | — |
| `ingest_v8_fertigation_recommendations` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |

### `irrigation_actions`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Public select irrigation_actions` | SELECT | public | PERMISSIVE | `true` | — |
| `Users can insert irrigation actions for their own plots` | INSERT | public | PERMISSIVE | — | `(EXISTS ( SELECT 1    FROM plots   WHERE ((plots.id = irrigation_actions.plot_id) AND ((plots.user_id)::text = (auth.uid())::text))))` |
| `Users can view irrigation actions for their own plots` | SELECT | public | PERMISSIVE | `(EXISTS ( SELECT 1    FROM plots   WHERE ((plots.id = irrigation_actions.plot_id) AND ((plots.user_id)::text = (auth.uid())::text))))` | — |
| `Users can update irrigation actions for their own plots` | UPDATE | public | PERMISSIVE | `(EXISTS ( SELECT 1    FROM plots   WHERE ((plots.id = irrigation_actions.plot_id) AND ((plots.user_id)::text = (auth.uid())::text))))` | — |
| `ingest_v8_irrigation_actions` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |

### `fertigation_actions`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Public select fertigation_actions` | SELECT | public | PERMISSIVE | `true` | — |
| `Users can insert fertigation actions for their own plots` | INSERT | authenticated | PERMISSIVE | — | `(EXISTS ( SELECT 1    FROM plots p   WHERE ((p.id = fertigation_actions.plot_id) AND ((p.user_id)::text = (( SELECT auth.uid() AS uid))::text))))` |
| `ingest_v8_fertigation_actions` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |

### `fertilizer_products`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Public select fertilizer_products` | SELECT | public | PERMISSIVE | `true` | — |
| `Public insert fertilizer_products` | INSERT | public | PERMISSIVE | — | `true` |
| `Public update fertilizer_products` | UPDATE | public | PERMISSIVE | `true` | `true` |
| `Public delete fertilizer_products` | DELETE | public | PERMISSIVE | `true` | — |
| `read_global_or_own_products` | SELECT | authenticated | PERMISSIVE | `((owner_user_id IS NULL) OR (owner_user_id = auth.uid()))` | — |
| `write_own_products` | ALL | authenticated | PERMISSIVE | `(owner_user_id = auth.uid())` | `(owner_user_id = auth.uid())` |
| `ingest_read_products` | SELECT | smile_ingest | PERMISSIVE | `true` | — |

### `plots`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Enable insert for users based on user_id` | INSERT | authenticated | PERMISSIVE | — | `(( SELECT auth.uid() AS uid) = user_id)` |
| `Enable users to view their own data only` | SELECT | authenticated | PERMISSIVE | `(( SELECT auth.uid() AS uid) = user_id)` | — |
| `Enable delete for users based on user_id` | DELETE | authenticated | PERMISSIVE | `(( SELECT auth.uid() AS uid) = user_id)` | — |
| `Policy with table joins` | UPDATE | authenticated | PERMISSIVE | `(auth.uid() = user_id)` | — |
| `plots_ingest_select` | SELECT | smile_ingest | PERMISSIVE | `true` | — |

### `actuator_commands`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `owner_select_commands` | SELECT | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = actuator_commands.node_id) AND (n.user_id = auth.uid()))))` | — |
| `owner_insert_manual_commands` | INSERT | authenticated | PERMISSIVE | — | `((trigger = 'manual'::text) AND (EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = actuator_commands.node_id) AND (n.user_id = auth.uid())))))` |
| `ingest_all_commands` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |

### `node_actuator_config`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `owner_rw_config` | ALL | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = node_actuator_config.node_id) AND (n.user_id = auth.uid()))))` | `(EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = node_actuator_config.node_id) AND (n.user_id = auth.uid()))))` |
| `ingest_read_config` | SELECT | smile_ingest | PERMISSIVE | `true` | — |

### `nutrient_batches`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `owner_batches` | ALL | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = nutrient_batches.node_id) AND (n.user_id = auth.uid()))))` | `(EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = nutrient_batches.node_id) AND (n.user_id = auth.uid()))))` |
| `ingest_read_batches` | SELECT | smile_ingest | PERMISSIVE | `true` | — |

### `nutrient_batch_items`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `owner_batch_items` | ALL | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM (nutrient_batches b      JOIN nodes n ON ((n.id = b.node_id)))   WHERE ((b.id = nutrient_batch_items.batch_id) AND (n.user_id = auth.uid()))))` | `(EXISTS ( SELECT 1    FROM (nutrient_batches b      JOIN nodes n ON ((n.id = b.node_id)))   WHERE ((b.id = nutrient_batch_items.batch_id) AND (n.user_id = auth.uid()))))` |
| `ingest_read_batch_items` | SELECT | smile_ingest | PERMISSIVE | `true` | — |

### `plot_soil_water_params`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `pswp_owner_select` | SELECT | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM plots p   WHERE ((p.id = plot_soil_water_params.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid)))))` | — |
| `pswp_owner_insert` | INSERT | authenticated | PERMISSIVE | — | `(EXISTS ( SELECT 1    FROM plots p   WHERE ((p.id = plot_soil_water_params.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid)))))` |
| `pswp_ingest_select` | SELECT | smile_ingest | PERMISSIVE | `true` | — |

### `sensor_calibrations`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `sc_owner_select` | SELECT | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = sensor_calibrations.node_id) AND (n.user_id = ( SELECT auth.uid() AS uid)))))` | — |
| `sc_owner_insert` | INSERT | authenticated | PERMISSIVE | — | `(EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = sensor_calibrations.node_id) AND (n.user_id = ( SELECT auth.uid() AS uid)))))` |
| `sc_ingest_select` | SELECT | smile_ingest | PERMISSIVE | `true` | — |

### `water_balance_ledger`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `wbl_owner_select` | SELECT | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM plots p   WHERE ((p.id = water_balance_ledger.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid)))))` | — |
| `wbl_ingest_all` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |

### `user_notifications`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `Users can view own notifications` | SELECT | authenticated | PERMISSIVE | `(auth.uid() = user_id)` | — |
| `Users can insert own notifications` | INSERT | authenticated | PERMISSIVE | — | `(auth.uid() = user_id)` |
| `Users can update own notifications` | UPDATE | authenticated | PERMISSIVE | `(auth.uid() = user_id)` | — |
| `Users can delete own notifications` | DELETE | authenticated | PERMISSIVE | `(auth.uid() = user_id)` | — |

### `calibrated_sensor_raw_readings`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `csrr_owner_select` | SELECT | authenticated | PERMISSIVE | `((EXISTS ( SELECT 1    FROM plots p   WHERE ((p.id = calibrated_sensor_raw_readings.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid))))) OR (EXISTS ( SELECT 1    FROM nodes n   WHERE ((n.id = calibrated_sensor_raw_readings.node_id) AND (n.user_id = ( SELECT auth.uid() AS uid))))))` | — |
| `csrr_ingest_select` | SELECT | smile_ingest | PERMISSIVE | `true` | — |

### `weather_forecast_snapshots`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `wfs_owner_select` | SELECT | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM plots p   WHERE ((p.id = weather_forecast_snapshots.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid)))))` | — |
| `wfs_ingest_select` | SELECT | smile_ingest | PERMISSIVE | `true` | — |
| `wfs_ingest_insert` | INSERT | smile_ingest | PERMISSIVE | — | `true` |

### `weather_observed_hourly`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `woh_owner_select` | SELECT | authenticated | PERMISSIVE | `(EXISTS ( SELECT 1    FROM plots p   WHERE ((p.id = weather_observed_hourly.plot_id) AND (p.user_id = ( SELECT auth.uid() AS uid)))))` | — |
| `woh_ingest_all` | ALL | smile_ingest | PERMISSIVE | `true` | `true` |

### `weather_forecasts`

| Policy | Command | Roles | Action | USING | WITH CHECK |
|--------|---------|-------|--------|-------|------------|
| `wf_ingest_select` | SELECT | smile_ingest | PERMISSIVE | `true` | — |
| `wf_ingest_insert` | INSERT | smile_ingest | PERMISSIVE | — | `true` |
| `wf_ingest_update` | UPDATE | smile_ingest | PERMISSIVE | `true` | `true` |
