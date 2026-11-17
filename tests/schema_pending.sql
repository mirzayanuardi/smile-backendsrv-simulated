-- Hak akses yang dibutuhkan server tetapi BELUM ada di migrasi mana pun (per v12).
-- Dispatcher fertigasi mengisi fertigation_recommendations.nutrient_batch_id.
-- Tanpa grant ini server mematikan fertigasi auto (lihat README, urutan deploy).
grant update (nutrient_batch_id) on public.fertigation_recommendations to smile_ingest;
