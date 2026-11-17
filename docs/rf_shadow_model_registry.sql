-- RF shadow mode (fase 1): daftarkan model RF irigasi di model_registries.
-- JANGAN dijalankan di Supabase/produksi tanpa keputusan tim. is_active = false:
-- model hanya dipakai shadow (decision_layer = 'rf'), tidak memengaruhi keputusan siram.
-- Setelah dijalankan, isi RF_MODEL_ID=aa499250-f6e8-4d0b-a28d-bc40eed13eab di .env.
-- metrics_json = metrik_gabungan_forecast.json bagian uji_asli_24h (NaN -> null).
insert into public.model_registries (
  id, name, type, task, trained_date, metrics_json, is_active, version, horizons,
  training_samples, last_ml_output, ec_response_model
) values (
  'aa499250-f6e8-4d0b-a28d-bc40eed13eab',
  'RF irigasi Dr 24 jam (shadow)',
  'random_forest', 'irrigation', '2026-11-17',
  '{"horizon": "24h", "lipatan": "uji_asli", "uji_mulai": "2026-11-11 00:00:00", "uji_selesai": "2026-11-13 15:00:00", "n_latih": 1637, "n_uji": 757, "porsi_uji_sintetis": 0.0, "mae_persistence": 16.544533157199474, "mae_rf": 12.999200046467305, "rmse_persistence": 22.68582344513906, "rmse_rf": 14.477235140150935, "ss_vs_persistence": 0.21429030828768914, "porsi_andal": 0.0, "mae_rf_andal": null, "mae_dipakai": 16.544533157199474, "n_latih_sintetis": 701}'::jsonb,
  false,
  'smile-irigasi-rf-dr-r3-gabungan_forecast-20261117',
  't+24h',
  '2681 sampel 5 menit (horizon 24h), data asli + sintetis',
  null, null
)
on conflict (id) do nothing;
