-- Hak akses yang dibutuhkan server tetapi BELUM ada di migrasi mana pun (per v12).
-- Dispatcher fertigasi mengisi fertigation_recommendations.nutrient_batch_id.
-- Tanpa grant ini server mematikan fertigasi auto (lihat README, urutan deploy).
grant update (nutrient_batch_id) on public.fertigation_recommendations to smile_ingest;

-- RF shadow membaca bacaan terkalibrasi. Di Supabase grant + policy ini sudah ada
-- (bersama trigger kalibrasi v13), tapi migrasinya belum ada di repo.
grant select on public.calibrated_sensor_raw_readings to smile_ingest;
create policy csrr_ingest_select on public.calibrated_sensor_raw_readings
  for select to smile_ingest using (true);
