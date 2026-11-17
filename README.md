# SMILE Ingest Server

Perantara antara node ESP32-S3 SMILE v7/v8 dan PostgreSQL Supabase. Node
mengunggah potongan CSV dari SD card; server memvalidasi, membuang duplikat,
mengoreksi timestamp (memakai fungsi SQL dari `smile_migration_v7.sql`), lalu
menulis ke Supabase lewat role `smile_ingest` (least privilege).

Sejak v8 server juga menjadi "otak" kanal aktuator: mengirim perintah berdurasi
ke ESP (`GET /v1/commands`), menerima laporan eksekusinya
(`POST /v1/ingest/actuations`), dan men-dispatch keputusan rule engine pada mode
auto. Kontraknya ada di **`docs/INTEGRASI_AKTUATOR_SMILE_v8.md`** (satu-satunya
sumber kebenaran) dan skemanya di `docs/smile_migration_v8.sql`.

Sejak v11 server juga menjalankan **rule engine neraca air FAO-56** (Layer 1,
tanpa ML): buku besar air tanah per jam dan satu keputusan irigasi per plot per
jam, ditulis ke `irrigation_predictions`. Skemanya di
`docs/migration_v11_neraca_air.sql`.

```
ESP32 --HTTPS--> Caddy (443, Let's Encrypt) --> app (FastAPI, 1 worker)
                                                   |
                                                   v  Supavisor session pooler (IPv4, 5432)
                                               Supabase Postgres
```

## Struktur

| Path | Isi |
|---|---|
| `app/main.py` | Endpoint dan pemetaan kode status (kontrak firmware) |
| `app/csvparse.py` | Parser dan validasi CSV per baris |
| `app/db.py` | Pool asyncpg dan SQL readings/clock events (bulk `unnest`, `ON CONFLICT`) |
| `app/actuator.py` | `X-Act`, baris `T`/`G`/`C`, laporan aktuasi → riwayat (§4) |
| `app/dispatcher.py` | Dispatcher mode auto, tiap 60 detik (§5) |
| `app/water_balance.py` | Neraca air FAO-56: ledger per jam + rule engine (v11) |
| `app/weather.py` | Klien Open-Meteo, snapshot prakiraan, job cuaca observasi harian (v12) |
| `app/rf_shadow.py` | Random Forest irigasi dalam shadow mode: hanya mencatat prediksi Dr 24 jam |
| `app/auth.py` | Token per node (SHA-256, cache 60 detik) |
| `app/cli.py` | `create-token` / `rotate-token` |
| `scripts/sim_node.py` | Simulator node (stdlib saja) |
| `scripts/run_water_balance.py` | Satu siklus neraca air untuk satu plot, cetak tabel per jam; mode backfill CSV untuk ML |
| `scripts/backfill_weather_observed.py` | Backfill cuaca reanalisis satu kali |
| `tests/` | Pytest + PostgreSQL lokal + migrasi asli |

## Kontrak singkat

| Endpoint | Auth | Catatan |
|---|---|---|
| `GET /v1/health` | tidak | Selalu 200: `{"status":"ok","server_time":<int>,"db":"ok"\|"down","last_forecast_snapshot_at":<ISO\|null>,"last_observed_weather_at":<ISO\|null>}` |
| `POST /v1/ingest/readings` | ya | CSV 15 kolom |
| `POST /v1/ingest/clock-events` | ya | CSV 7 kolom. Juga mengoreksi ulang waktu riwayat aksi segmen itu |
| `GET /v1/commands` | ya | Poll aktuator tiap 15 s, header `X-Act`, respons `text/plain` (§4.1) |
| `POST /v1/ingest/actuations` | ya | CSV 10 kolom laporan eksekusi (§4.2) |

Kode status: `200` request terbaca (walau ada baris ditolak) · `401` token/node
salah · `400` header CSV salah / bukan UTF-8 · `413` body > 64 KB · `415`
Content-Type bukan `text/csv` · `422` `X-Schema-Version` bukan `1` · `503` DB
bermasalah (seluruh chunk di-rollback; node mengirim ulang, dedup membuatnya aman).

Nomor baris di `rejected` dihitung dari awal body: header = baris 1, baris
data pertama = baris 2.

Nilai sensor di luar rentang menjadi NULL dan tercatat di `quality_flag`
(`oor:soil_ph=15.2`). Nilai yang bukan angka juga menjadi NULL dengan catatan
`bad:<field>=<nilai>`, supaya satu nilai rusak tidak membuang seluruh baris.
`rain_mm` di atas 1e9 dan `rain_tips` di atas 2^31-1 diperlakukan sebagai
`oor`, karena angka sebesar itu akan membuat INSERT gagal dan chunk diulang
selamanya.

## Kanal aktuator (v8)

### `GET /v1/commands`

Header tambahan dari ESP: `X-Act: w=1;d=0;cmd=<uuid|->;left=45;res=1;cfg=3;tw=120;td=0`.
Bagian yang hilang atau rusak diabaikan satu per satu; request tetap 200.
Dalam satu transaksi server:

1. menulis `nodes.valve_is_on = w` / `pump_is_on = d` (`*_updated_at` hanya
   kalau nilainya berubah) dan `last_seen_at` (throttle 60 s);
2. mengubah perintah `cmd` dari `sent` ke `running` (+ `started_at`);
3. mengambil maksimal 4 perintah `pending` yang belum kedaluwarsa
   (`FOR UPDATE SKIP LOCKED`), menandainya `sent`.

```
T 1791360060
G 3 max_run=600 max_water_day=1800 max_dose_day=300 min_gap=1800 prewet=30 flush=30 fb_thr=-1 fb_run=120 fb_off_h=24 m_start=6 m_end=9 stop_thr=-1
C 7f3c...-uuid irrigate manual 60 0 540
```

`stop_thr` (v11) = `node_actuator_config.stop_moisture_raw`, ambang rem jenuh
dalam satuan **bacaan mentah** sensor (setara θ_FC); `-1` = rem nonaktif. Diisi
otomatis oleh trigger database dari kalibrasi kelembapan, sama seperti `fb_thr`.
Firmware v8.3 yang menghentikan irigasi karena rem jenuh melaporkan
`executed` + `detail=soil_saturated` (riwayat `success`, durasi aktual dari ESP).

`prewet` (`node_actuator_config.prewet_s`) dan `flush` (`flush_s`) adalah fase
basahi dan bilas fertigasi. Satu perintah `fertigate` berjalan tiga fase:
basahi (`X-Act` `w=1;d=0`) → suntik (`w=1;d=1`, `dose_s`) → bilas (`w=1;d=0`).

`G` hanya dikirim kalau `cfg` ≠ `node_actuator_config.config_version` (juga
kalau `cfg` tidak ada di header), dan tidak pernah dikirim kalau node belum punya
baris config. `401`/`503` sama dengan endpoint lain.

### `POST /v1/ingest/actuations`

Header CSV: `ev_id,cmd_id,command,trigger,clk,ts_start,water_s,dose_s,status,detail`.
Batas body, kode status, dan aturan "masalah per baris → `rejected` +
`ingest_rejects`, tetap 200" sama dengan readings. Selain validasi format, baris
juga ditolak kalau `cmd_id` bukan perintah milik node itu, `command` tidak sama
dengan perintahnya, atau `local_fallback` membawa `cmd_id`.

Laporan `fertigate` menghasilkan satu baris di **kedua** tabel aksi:

| Tabel | Kolom |
|---|---|
| `irrigation_actions` | `duration_sec = water_s` (basahi + suntik + bilas), `estimated_volume_liter = water_s/60 × water_flow_lpm`, `triggered_by` dari perintah, `detail = 'fertigasi'` |
| `fertigation_actions` | `actual_duration_sec = dose_s`, `actual_volume = dose_s × dose_flow_ml_per_s / 1000` (liter larutan), `nutrient_batch_id` dari `actuator_commands.nutrient_batch_id`, `detail` dari ESP |

Pemetaan ke database mengikuti tabel §4.3. Untuk perintah dari server,
`triggered_by` diambil dari `actuator_commands`, bukan dari CSV. Status perintah
yang sudah final (`executed`, `stopped`, `interrupted`, `rejected`, `expired`,
`cancelled`) tidak ditimpa. Untuk `rejected_*`, `result_detail` berisi
`<status>:<detail>`, misalnya `rejected_limit:day_water`. Di respons,
`inserted` = baris yang menghasilkan perubahan baru dan `duplicates` = baris
tanpa efek baru (kiriman ulang).

### Dispatcher

Background task di proses app, dengan siklus tiap `DISPATCH_INTERVAL_S` (60).
Satu siklus = satu transaksi dengan `pg_try_advisory_xact_lock`, jadi aman
kalau ada beberapa worker. Isinya:

1. `pending` yang lewat `expires_at` → `expired` (`result_detail='not_fetched'`).
2. Irigasi auto: untuk node `valve_mode='auto'`, `has_irrigation`, dengan
   `water_flow_lpm` dan `wetted_area_m2` terisi, server mengambil prediksi
   terbaru plotnya (`irrigation_triggered`, `recommended_irrigation_mm > 0`,
   belum di-dispatch, `dispatch_note` kosong, `created_at` ≤ 30 menit).
   Prediksi itu diperiksa berurutan: jendela pagi WIB, lalu jeda minimal
   (riwayat terakhir atau perintah yang sudah mulai), lalu antrean (`pending`/`sent`
   → coba lagi di siklus berikutnya). Setelah lolos, durasi dihitung
   t = I·A/Q·60 (dibulatkan, dibatasi `max_run_s`, < 5 s → `too_small`) dan
   perintah `rule_engine` disisipkan.
3. Fertigasi auto: **nonaktif** sampai `FERTIGATION_AUTO_STATUSES` diisi.
   Untuk node `pump_mode='auto'` dan `has_fertigation`, server mengambil
   rekomendasi terbaru plotnya dengan status yang diizinkan (≤ 30 menit, belum
   di-dispatch). Langkahnya:
   - Ambil larutan aktif node (`nutrient_batches.is_active`). Kalau tidak ada:
     `dispatch_note='no_active_batch'`.
   - Kalau rekomendasi punya target gram (`target_n_g`/`target_p2o5_g`/`target_k2o_g`):
     `dose_s = smile_dose_seconds(batch, n, p2o5, k2o, dose_flow_ml_per_s)`. Kalau
     hasilnya NULL: `dispatch_note='dose_uncomputable'`.
   - Kalau semua target kosong (format lama): `dose_s = round(pump_duration_seconds)`, maks 300.
   - `water_s = prewet_s + dose_s + flush_s`. Kalau lebih dari `max_run_s`:
     tidak dikirim, `dispatch_note='dose_too_long'` (dosis tidak dipotong).
   - Larutan yang dipakai dicatat di `fertigation_recommendations.nutrient_batch_id`
     dan `actuator_commands.nutrient_batch_id`.

Kalau trigger database menolak insert (misalnya mode baru saja diganti ke manual),
pesannya dicatat di `dispatch_note` sebagai `rejected: <pesan>` dan prediksi itu
tidak dicoba lagi. Setiap keputusan dicatat di log sebagai satu baris JSON
`"event":"dispatch"` dengan `result` berisi salah satu dari `dispatched`,
`clamped`, `outside_window`, `min_gap`, `too_small`, `busy`, `rejected`, atau
(fertigasi) `no_active_batch`, `dose_uncomputable`, `dose_too_long`.

### Neraca air untuk pipeline ML

Sejak fertigasi tiga fase, **air fertigasi tercatat di `irrigation_actions`**
(baris dengan `detail='fertigasi'`), jadi irigasi $I$ di neraca air harus menjumlahkan:

- `irrigation_actions.estimated_volume_liter`, termasuk baris fertigasi, **ditambah**
- `fertigation_actions.actual_volume` (liter larutan dari pompa peristaltik, yang
  ikut masuk ke tanah bersama air).

Filter status eksekusi tetap mengikuti aturan pipeline yang sudah ada. Contoh
query ada di bagian Query audit ("Irigasi I per plot per hari").

Jangan menghitung baris fertigasi dari `irrigation_actions` lalu menambahkan
`water_s` dari `actuator_commands` lagi: itu menghitung air yang sama dua kali.
Gram hara yang masuk per aksi ada di view `fertigation_delivered`.

Catatan: rule engine Layer 1 (v11, bagian Neraca air FAO-56) mengikuti prompt
v11 dan **hanya** menjumlahkan `irrigation_actions`; volume larutan tidak
ditambahkan (biasanya < 0,1 L per aksi). Kalau tim memutuskan larutan ikut
dihitung, ubah `_IRRIGATIONS` di `app/water_balance.py`.

### Variabel lingkungan

| Variabel | Default | Isi |
|---|---|---|
| `DISPATCHER_ENABLED` | `1` | `0` mematikan dispatcher di proses ini |
| `DISPATCH_INTERVAL_S` | `60` | Jeda antar siklus |
| `FERTIGATION_EXECUTED_BY` | kosong | Pemetaan trigger → label enum `fertigation_actions.executed_by`, misalnya `manual=manual,rule_engine=auto,schedule=auto`. Kosong = `executed_by` NULL. Label yang tidak ada di enum diabaikan (lihat log saat start) |
| `FERTIGATION_AUTO_STATUSES` | kosong | Status `fertigation_recommendations` yang boleh di-dispatch otomatis, misalnya `normal,naikkan`. Kosong = fertigasi auto mati |

### Mengisi `node_actuator_config`

Migrasi v8 membuat satu baris default untuk setiap node. Nilai di bawah diisi
oleh tim, per node yang punya aktuator, lewat SQL Editor atau app (role
`authenticated` pemilik node):

```sql
update public.node_actuator_config set
  water_flow_lpm     = 1.2,   -- hasil uji tampung 60 detik (L/menit)
  wetted_area_m2     = 0.8,   -- luas basah A, misalnya pi * r_tajuk^2
  has_fertigation    = true,  -- hanya kalau pompa peristaltik terpasang
  dose_flow_ml_per_s = 1.5,   -- hasil uji pompa peristaltik (mL/detik)
  prewet_s           = 30,    -- fase basahi sebelum suntik (detik)
  flush_s            = 30     -- fase bilas setelah suntik (detik, min 30)
where node_id = '<uuid node>';

-- Node tanpa aktuator irigasi:
update public.node_actuator_config set has_irrigation = false where node_id = '<uuid>';

-- Fallback lokal tetap NONAKTIF sampai ambang kalibrasi diisi:
update public.node_actuator_config set fallback_threshold_raw = <nilai> where node_id = '<uuid>';
```

Setiap perubahan menaikkan `config_version` (trigger), dan ESP menerima baris `G`
pada poll berikutnya. Selama `water_flow_lpm` atau `wetted_area_m2` masih
kosong, dispatcher melewati node itu, sedangkan perintah manual tetap bisa
dipakai. Batas angka (`max_run_s` ≤ 600, `flush_s` ≥ 30, `min_gap_s` ≥ 900,
dst.) dijaga oleh CHECK database dan batas keras firmware.

## Neraca air FAO-56 (Layer 1, v11)

Pembagian tugas yang dikunci:

- **Rule engine** (`app/water_balance.py`): menghitung Dr, memutuskan
  `irrigation_triggered` dan `recommended_irrigation_mm`. Pertimbangan hujan dan
  Dr ≥ RAW ada di sini.
- **Dispatcher** (tidak berubah): jendela pagi, `min_gap`, konversi mm → detik,
  `too_small`, `clamped`.

Istilah: **Dr** defisit air zona akar (mm; 0 = kapasitas lapang, TAW = titik
layu), **ETo** evapotranspirasi acuan, **ETc = Kc × ETo**, **DP** perkolasi
dalam, **TAW** = (θ_FC − θ_PWP)/100 × Zr, **RAW** = p × TAW. Rumus TAW/RAW/θ
pemicu milik view `plot_water_params_current`; Python memakai urutan operasi yang
sama (diuji identik).

### Alur tiap siklus

Job jalan sekali saat startup lalu tiap jam pada **menit ke-5 WIB**, satu proses
saja (`pg_try_advisory_lock`, kunci berbeda dengan dispatcher). Plot diproses
kalau punya baris di `plot_water_params_current` dan node dengan
`has_irrigation`. Node aktif pertama (`created_at`) yang dipakai; lebih dari satu
node menghasilkan peringatan di log.

1. **Ledger** `water_balance_ledger`, satu baris per jam `[t, t+1h)` dengan
   `period_end = t+1h`. Setiap siklus **menghitung ulang `WB_RECOMPUTE_H` jam
   terakhir** karena ESP bisa mengunggah data lama sekaligus. Ditulis dengan
   `INSERT … ON CONFLICT (plot_id, period_end) DO UPDATE` (id baris tetap, karena
   `irrigation_predictions.ledger_id` menunjuk ke sana), satu transaksi per plot.
   - Dr awal = `dr_end_mm` baris ledger tepat sebelum jendela. Kalau ledger
     berhenti lebih lama dari jendela (server mati), jendela diperpanjang sampai
     baris terakhir itu (maks 14 hari). Kalau belum ada ledger: Dr observasi
     terkalibrasi, kalau tidak ada **Dr = 0** (log `init_fc_assumed`).
   - Parameter: versi `plot_soil_water_params` dengan `valid_from ≤ period_start`.
   - **ETo** (urutan v12): `open_meteo` (`weather_forecasts.forecast_eto_mm` dengan
     `valid_for_timestamp = period_end`, issue terbaru; nilai Open-Meteo = jumlah
     satu jam *sebelum* stempel) → `open_meteo_cached` (snapshot terbaru di
     `weather_forecast_snapshots` dengan `valid_time = period_end`) →
     `open_meteo_archive` (`weather_observed_hourly`) → `hargreaves_sht31`
     (Tmin/Tmax SHT31 24 jam terakhir, minimal 18 jam berbeda, ETo harian/24,
     lintang `plots.location_lat`) → `none` (0). **SHT31 saat ini di bawah naungan
     plastik dan bias ±+5 °C di siang hari (malam ±0 °C), jadi Hargreaves cenderung
     terlalu tinggi**; karena itu ia sumber terakhir.
   - **Hujan**: `sensor` (≥ 30 baris dalam jam itu, lihat semantik di bawah) →
     `open_meteo` (`forecast_rainfall_mm`) → `none`. Sejak v12 hujan sensor =
     Δ`rainfall_tip_count` × `nodes.rain_mm_per_tip` (NULL = 0,28).
   - **Irigasi**: Σ `irrigation_actions.estimated_volume_liter` (status `success`
     dan `overridden`) ÷ `wetted_area_m2`. Air fertigasi sudah ada di
     `irrigation_actions`, jadi `fertigation_actions` tidak dijumlahkan lagi.
   - Langkah: `x = Dr − hujan − irigasi + ETc`; kalau x < 0 → DP = −x, x = 0;
     lalu x ≤ TAW.
   - **Observasi**: median `soil_moisture_pct` 15 menit terakhir jam itu (≥ 5
     baris), dikalibrasi dengan `smile_calibrate()` (SQL, polinomial tidak
     disalin ke Python). `dr_obs` hanya kalau terkalibrasi.
   - **Koreksi** (`dr_end = dr_obs`, `corrected = true`) hanya kalau terkalibrasi,
     sudah ≥ `WB_CORRECT_EVERY_H` jam sejak koreksi terakhir, dan tidak ada hujan
     > 0,2 mm atau irigasi di jam itu dan `WB_SETTLE_H` jam sebelumnya. Tanpa
     kalibrasi, ledger tetap jalan sebagai model fisika murni.
2. **Keputusan** dari baris ledger terakhir + parameter view + prakiraan
   (issue terbaru, `(now, now+24h]`): `ETc 24 jam = Kc × Σ forecast_eto_mm`
   (kosong → rata-rata `etc_mm` 72 jam ledger × 24, tanda `eto_fc_estimated`),
   `Dr 24 jam = clamp(Dr + ETc24 − hujan24, 0, TAW)`.
3. Satu baris `irrigation_predictions` (`decision_layer='fao56'`, `model_id`
   NULL), kecuali sudah ada baris `fao56` untuk plot itu < 50 menit (aman saat
   restart). Dispatcher mengambilnya dalam ≤ 60 detik.

### Kode `reason`

Format: `<kode>: <angka>; ETo <sumber>[; eto_fc_estimated][; sensor belum terkalibrasi]`,
misalnya `dr_ge_raw: Dr 26,1 mm ≥ RAW 24,0 mm; ETo open_meteo`. Aturan dievaluasi
berurutan, berhenti di yang pertama cocok:

| Kode | Kondisi | Siram? |
|---|---|---|
| `soil_at_fc` | θ terkalibrasi ≤ 2 jam ≥ θ_FC | tidak |
| `rain_expected` | prakiraan hujan 12 jam ≥ `WB_RAIN_SKIP_MM` | tidak |
| `dr_ge_raw` | Dr ≥ RAW | ya, `min(Dr, TAW)` mm |
| `anticipatory_24h` | di jendela pagi node **dan** Dr 24 jam ≥ RAW | ya, `min(Dr, TAW)` mm |
| `below_raw` | lainnya | tidak |

`anticipatory_24h` ada karena jendela pagi berikutnya baru 24 jam lagi. Prediksi
`dr_ge_raw` di luar jendela pagi tetap ditulis; dispatcher mencatatnya
`outside_window`.

### Semantik `rainfall_mm` (diperiksa dari data asli, 2026-10-15)

`sensor_raw_readings.rainfall_mm` **kumulatif sejak boot**, bukan per interval:
dari 4.499 baris firmware v7+, nilainya naik 81 kali, datar 4.409 kali, dan turun
8 kali; kedelapan penurunan bertepatan dengan `uptime_s` kembali ke 4–10 s atau
`clock_segment` berganti (reboot), dan nilainya tetap naik melewati 24 jam
(33,81 mm pada uptime 2,8 hari). `rainfall_tip_count` juga kumulatif (nominal
0,28 mm/tip; kalibrasi berat air node kami 0,289, disimpan di `nodes.rain_mm_per_tip`).
`rainfall_mm` firmware tidak selalu tepat tip × 0,28 (contoh: 30,18 mm untuk 108 tip),
jadi ledger memakai tip; kalau satu jam punya baris tanpa tip (firmware lama),
seluruh jam memakai `rainfall_mm × faktor / 0,28`. Kedua deret tidak dicampur.
Hujan per jam = Σ `rain_increments()`: selisih antarbaris berurutan per node,
termasuk dari baris terakhir jam sebelumnya; kalau nilai turun, selisihnya = nilai
baru (aturan yang sama dengan `rain24hLocked()` firmware). Hujan yang terjadi
saat node tidak mencatat ikut masuk ke jam pertama yang punya data cukup.

### Data yang dipakai / dibuang

- Semua sensor: baris dengan `time_status` `unverified` atau `legacy` dibuang
  (jamnya tidak bisa dipercaya jatuh di jam yang benar).
- Kelembapan: buang `quality_flag` berisi `soil_fail`; suhu: `sht_fail`; hujan:
  `rain_fail`. Nilai di luar rentang sudah NULL sejak ingest.

### Variabel lingkungan

| Variabel | Default | Isi |
|---|---|---|
| `WB_ENABLED` | `1` | `0` mematikan job di proses ini |
| `WB_RECOMPUTE_H` | `48` | Jam terakhir yang dihitung ulang tiap siklus |
| `WB_CORRECT_EVERY_H` | `6` | Jarak minimal antar koreksi sensor |
| `WB_SETTLE_H` | `2` | Jam setelah hujan/irigasi sebelum sensor boleh mengoreksi |
| `WB_RAIN_SKIP_MM` | `10` | Ambang hujan 12 jam untuk `rain_expected` |
| `WB_DEFAULT_LAT` / `WB_DEFAULT_LNG` | `-6.595` / `106.8166` | Dipakai kalau `plots.location_lat` kosong atau tidak terbaca |

### Hak akses yang belum ada di v11

v11 memberi `SELECT` `weather_forecasts` ke `smile_ingest`, tetapi RLS tabel itu
tidak punya policy untuk `smile_ingest` (query membaca 0 baris tanpa error), dan
tidak memberi akses ke `plots.location_lat` serta `nodes.status/created_at`.
**Semuanya kini ada di migrasi v12.** Sebelum v12 diterapkan job tetap jalan
(lintang default, node dipilih berdasarkan id, faktor tip 0,28, tanpa fallback
cached/archive) dan menulis peringatan sekali per proses di log.

### Skrip bantu

```bash
docker compose exec app python scripts/run_water_balance.py --plot <uuid> --dry-run
docker compose exec app python scripts/run_water_balance.py --plot <uuid> --hours 72
```

Mencetak tabel per jam (ETo dan sumbernya, hujan, irigasi, Dr model, θ mentah dan
terkalibrasi, Dr observasi, Dr akhir, koreksi) dan keputusan akhirnya.
`--dry-run` tidak menulis apa pun (dan tidak mengambil prakiraan). Tanpa
`--dry-run` skrip juga mengambil prakiraan Open-Meteo, sama dengan job.

**Mode backfill untuk ML** (hanya membaca; hanya menulis CSV, tidak menyentuh ledger):

```bash
docker compose exec app python scripts/run_water_balance.py --plot <uuid> \
  --from 2026-10-08 --to 2026-10-12 --no-sensor-correction --export-csv /tmp/fao56.csv
```

Lintasan FAO-56 per jam `[--from, --to)` (waktu tanpa zona = WIB) tanpa koreksi
sensor 6-jaman. Parameter tanah = versi yang berlaku di tiap jam; ETo dengan urutan
di atas; hujan **hanya sensor** (jam tanpa data cukup = 0, jumlahnya dicetak);
irigasi dari `irrigation_actions`. Dr awal = `--init-dr`, atau observasi
terkalibrasi di `--from`, atau 0. Kolom CSV: `time` (akhir jam, UTC), `plot_id`,
`eto_mm`, `etc_mm`, `rain_mm`, `irrigation_mm`, `dr_start_mm`, `dr_end_mm`,
`taw_mm`, `raw_mm`, `eto_source`. Ringkasan (sumber ETo, jam tanpa hujan sensor,
peringatan) ke stderr.

## Arsip cuaca untuk ML (v12)

Skema: `docs/migration_v12_arsip_cuaca.sql`. Satu-satunya klien Open-Meteo ada di
`app/weather.py` (timeout `WX_HTTP_TIMEOUT_S`, `WX_HTTP_ATTEMPTS` percobaan untuk
429/5xx/timeout dengan jeda 1, 2, 4 … s; 4xx tidak diulang).

**Prakiraan.** Diambil di awal siklus neraca air (menit :05), di dalam kunci
neraca air, **satu panggilan per plot, untuk SEMUA plot** (termasuk plot tanpa
node atau dengan node `maintenance`, karena app menampilkan cuaca per plot dan
edge function lama juga mengisi semua plot; koordinat kosong →
`WB_DEFAULT_LAT/LNG`, dicatat sebagai error di log). Job observasi di bawah tetap
hanya untuk plot dengan ≥ 1 node aktif.
Parameter sama dengan edge function lama (`past_days=2`, `forecast_days=3`,
`timezone=UTC`) ditambah `precipitation_probability`, `wind_speed_10m` (m/s),
`shortwave_radiation`, `models=best_match`. Satu respons ditulis ke:

- `weather_forecasts` — upsert per jam seperti edge function (dibaca ledger dan app);
- `weather_forecast_snapshots` — jam dengan lead 1–48, `issued_at` = waktu fetch
  dibulatkan ke jam (**bukan** waktu run model; API tidak memberikannya),
  `ON CONFLICT DO NOTHING`. Role server hanya punya `SELECT, INSERT`.

Dua tulisan itu terpisah, dan kegagalan fetch/tulis hanya dicatat
(`"event":"forecast_snapshot"`, satu baris per siklus: `rows_forecast`,
`rows_snapshot`, `duration_ms`, `errors`); neraca air tetap jalan.

Setelah server ini berjalan dan snapshot terisi, **matikan cron edge function**
supaya Open-Meteo tidak dipanggil dua kali per jam:
`select cron.unschedule('sync-weather-forecast-job');`

**Observasi.** Job harian **03:00 WIB** (kunci advisory `smilewxo`, tidak jalan
saat startup) mengambil archive API untuk H-`WX_OBSERVED_DAYS` s.d. H-1 (tanggal
UTC) ke `weather_observed_hourly` dengan `ON CONFLICT DO UPDATE` (nilai NULL baru
tidak menimpa nilai lama). Jam yang semua variabelnya kosong tidak disimpan.
Log: `"event":"weather_observed"`. Backfill satu kali:

```bash
docker compose exec app python scripts/backfill_weather_observed.py --from 2026-10-01
```

**Previous Runs API tidak dipakai** untuk mengisi snapshot lampau: `_previous_dayN`
hanya berarti "±24·N jam sebelum valid time", responsnya tidak memuat waktu run,
dan `et0_fao_evapotranspiration` / `precipitation_probability` tidak tersedia.
`issued_at` yang diturunkan dari situ adalah tebakan, jadi tabel snapshot hanya
berisi fetch nyata sejak job ini berjalan.

| Variabel | Default | Isi |
|---|---|---|
| `WX_FORECAST_ENABLED` | `1` | `0` = siklus neraca air tidak mengambil prakiraan |
| `WX_OBSERVED_ENABLED` | `1` | `0` mematikan job observasi di proses ini |
| `WX_OBSERVED_DAYS` | `10` | Jendela H-N s.d. H-1 job observasi |
| `WX_HTTP_TIMEOUT_S` | `15` | Timeout per permintaan |
| `WX_HTTP_ATTEMPTS` | `3` | Jumlah percobaan |
| `WX_HTTP_BACKOFF_S` | `1` | Jeda dasar backoff eksponensial |

## RF: shadow mode dan active mode

Model Random Forest irigasi (`ML/TrainingAgain/skenario_4_data_gabungan_forecast`) punya tiga mode
lewat `RF_MODE`: `off` (default), `shadow` (fase 1, hanya mencatat), dan `active` (fase 2, ikut di R4).

### `RF_MODE=active`

- RF dihitung **sebelum** FAO-56 memutuskan (fitur dan titik t sama dengan shadow).
- Kalau RF `reliable`: aturan **R4** (antisipasi di jendela pagi) memakai Dr 24 jam RF menggantikan
  `dr_forecast_24h_mm` FAO-56. Baris keputusan: `decision_layer='fao56+rf'`, `model_id=RF_MODEL_ID`,
  `status_model='reliable'`, `prediction_dr_value` = Dr RF, `prediction_error_margin` = std antar pohon;
  `dr_forecast_24h_mm` tetap nilai FAO-56 untuk pembanding. Dispatcher memprosesnya seperti baris FAO-56.
- Kalau RF `uncertain`, fitur tidak lengkap, atau RF error: keputusan FAO-56 murni (`decision_layer='fao56'`);
  catatan RF ada di `reason` bila prediksinya ada.
- R1, R2, R3, R5 dan `decide()` tidak berubah. RF bisa memicu R4 yang tidak dipicu FAO-56, dan bisa
  juga membatalkannya bila Dr RF < RAW. Tidak ada baris `rf` terpisah di mode ini.
- Hasil evaluasi training: RF belum lebih baik dari rule engine. Pakai `active` untuk uji/simulasi.

### `RF_MODE=shadow`

RF dijalankan berdampingan dengan rule engine FAO-56, tetapi **tidak pernah memutuskan siram**:

- Dipanggil dari `water_balance.run_cycle()` tepat setelah baris FAO-56 plot itu ditulis, di dalam
  try/except sendiri. Kegagalan RF hanya dicatat di log; siklus FAO-56 tidak berubah.
- Hanya untuk plot milik model (`bundle["plot_id"]`). Titik t = awal blok 5 menit terakhir yang sudah
  lengkap (siklus 07:05 WIB → t = 07:00 WIB).
- Fitur (20, urutan bundle) dihitung persis seperti training dari `calibrated_sensor_raw_readings`
  (sumber yang sama dengan export training) dan `weather_forecast_snapshots` (snapshot terbaru dengan
  `fetched_at ≤ t`). Hujan dari selisih `rainfall_tip_count` × 0,2891 mm/tip, menit > 10 tip dibuang;
  ini terpisah dari hujan FAO-56 (`_sensor_rain`, faktor `nodes.rain_mm_per_tip`).
- Ada fitur NaN (data < 24 jam, ada blok 5 menit kosong, prakiraan tidak menjangkau t+24 jam):
  tidak ada insert, satu baris log `event=rf_shadow, skipped=fitur_tidak_lengkap`.
- Baris yang ditulis ke `irrigation_predictions`: `decision_layer='rf'`, `model_id=RF_MODEL_ID`,
  `prediction_dr_value` (Dr t+24 jam), `prediction_error_margin` (std antar pohon, mm), `status_model`
  `reliable` bila std/RAW×100 ≤ `RF_ERROR_THRESHOLD_PCT` (selain itu `uncertain`),
  `predicted_soil_moisture = θ_FC − Dr/Zr×100`, `raw_mm`, `taw_mm`, `irrigation_triggered=false`,
  `recommended_irrigation_mm=null`, `reason='rf_shadow: ...'`. Paling banyak satu baris per plot per 50 menit.
- Dispatcher mengabaikan baris `decision_layer='rf'` walaupun `irrigation_triggered` diubah jadi true
  (pengaman kedua).

| Env | Default | Arti |
|---|---|---|
| `RF_MODE` | `off` | `off` / `shadow` / `active`; selain itu dianggap `off` (dengan log) |
| `RF_MODEL_PATH` | kosong | Path file `.joblib` **di dalam container** (`./models` di-mount read-only ke `/srv/models`) |
| `RF_MODEL_ID` | kosong | `model_registries.id` (lihat `docs/rf_shadow_model_registry.sql`) |
| `RF_ERROR_THRESHOLD_PCT` | `25` | Batas uncertainty untuk `reliable` |

Kalau RF `off`, atau path/ID kosong, atau model gagal dimuat, RF dilewati dengan satu baris log
(keputusan FAO-56 murni).
File model (20 MB) di-commit di `models/` bersama `models/SHA256SUMS`; container me-mount folder itu
read-only (tidak di-COPY ke image). Versi `numpy`, `pandas`, `scikit-learn`, dan `joblib` di
`requirements.txt` sama dengan lingkungan training; jangan dinaikkan tanpa melatih/menyimpan ulang model.
Model baru: ganti file di `models/`, perbarui `SHA256SUMS`, `RF_MODEL_PATH`, dan baris `model_registries`.

Menyalakan:

```bash
(cd models && sha256sum -c SHA256SUMS)              # file model utuh
psql ... -f docs/rf_shadow_model_registry.sql      # sekali; di produksi hanya dengan keputusan tim
# .env: RF_MODE=shadow, RF_MODEL_ID=<id dari SQL di atas>
docker compose up -d --build app
docker logs smile-ingest-app 2>&1 | grep '"event": "rf'
```

Pindah mode di simulasi: `sim/sim.sh rf off|shadow|active` (ubah `.env` lalu restart app, ±10 detik).
Di luar simulasi: ubah `RF_MODE` di `.env` lalu `docker compose up -d --force-recreate app`.
Baris `rf` lama tetap ada dan bisa dihapus dengan `delete from irrigation_predictions where decision_layer = 'rf'`.

Uji kesamaan fitur dengan training butuh folder ML:
`RF_TEST_ML_DIR=".../ML/TrainingAgain" pytest tests/test_rf_shadow_pure.py`. Satu-satunya perbedaan
yang diizinkan: fitur hujan di titik yang jendela 24 jamnya mencakup ketukan manual 7 Nov 16:11–16:13
(dibuang khusus di training).

## Update server produksi dari repo ini

Repo ini berisi semua yang dibutuhkan untuk membangun ulang server ingest **kecuali** dua hal yang
memang tidak boleh ada di git: `.env` (password `smile_ingest`, domain) dan database (Supabase).
Tidak ada Postgres lokal di produksi: `docker-compose.yml` hanya berisi service `app`.
`docker-compose.sim.yml`, `sim/`, dan `SIMULASI.md` khusus server simulasi; `sim/sim.sh` menolak jalan
kalau `DATABASE_URL` tidak menunjuk ke container `db` lokal.

| Isi | Di repo | Catatan |
|---|---|---|
| Kode `app/`, `scripts/`, `Dockerfile`, `requirements.txt` | ya | image dibangun ulang dari sini (~700 MB karena numpy/pandas/scikit-learn) |
| `docker-compose.yml` (produksi) | ya | `app` saja, port `127.0.0.1:8080`, mount `./models` read-only |
| Model RF `models/*.joblib` + `SHA256SUMS` | ya | baru dipakai kalau `RF_MODE` ≠ `off` |
| Migrasi `smile_migration_v7.sql`, `docs/*migration*.sql`, `docs/rf_shadow_model_registry.sql` | ya | diterapkan manual di Supabase SQL Editor |
| `.env` | **tidak** | salin dari server produksi lama, atau isi dari `.env.example` |
| Data (Supabase), backup DB (`import_database/`) | **tidak** | `import_database/` di-ignore (berisi data produksi) |

Langkah (server baru atau update):

```bash
git clone https://github.com/mirzayanuardi/smile-backendsrv-simulated.git smile-backendsrv
cd smile-backendsrv && git switch <branch>       # mis. main setelah PR digabung
cp /path/.env-produksi-lama .env && chmod 600 .env  # atau: cp .env.example .env lalu isi
grep -E '^(DATABASE_URL|RF_MODE)=' .env | sed 's#//[^@]*@#//***@#'   # host Supabase, RF_MODE=off dulu
(cd models && sha256sum -c SHA256SUMS)
docker compose up -d --build app                 # BUKAN -f docker-compose.sim.yml
docker compose ps                                # app "healthy"
curl -s http://127.0.0.1:8080/v1/health          # db: "ok"
docker compose logs --tail=50 app                # "rf: mati (RF_MODE=off)", tanpa error
```

Skema Supabase per backup 2026-11-12 sudah cukup untuk kode ini dengan `RF_MODE=off`: kolom
`decision_layer`, `prediction_error_margin`, constraint `ip_*`, dan grant `smile_ingest` ke
`calibrated_sensor_raw_readings` sudah ada (diuji di server simulasi yang memakai dump skema itu).
Menyalakan RF di produksi (keputusan tim): jalankan `docs/rf_shadow_model_registry.sql` sekali, isi
`RF_MODEL_ID`, set `RF_MODE=shadow`, lalu `docker compose up -d --force-recreate app`.

Konfigurasi data yang dipakai simulasi (kalibrasi `{13.279, 0.5814}`, debit, luas basah, `valve_mode`)
**tidak** ikut ke produksi; semuanya data di Supabase dan diubah manual oleh tim.

Rollback: `RF_MODE=off` + `docker compose up -d --force-recreate app` (RF saja), atau
`git checkout <commit-lama> && docker compose up -d --build app` (semua kode).

## Deploy (Caddy + Let's Encrypt)

Prasyarat (sekali saja):

1. **IP statis.** Jadikan IP eksternal VM statis (GCP Console → VPC network →
   IP addresses → *Reserve* pada IP yang sedang dipakai), supaya A record
   tidak basi setelah VM di-restart.
2. **DNS.** Di pengelola DNS `nirbatas.id` (registrar sekarang), buat
   `A  <subdomain>  →  <IP statis>`. Kalau kelak pindah ke Cloudflare, record
   ini harus **DNS only (awan abu-abu)**, bukan proxied.
3. **Firewall GCP.** Izinkan TCP 80 dan 443 ke VM (port 80 dibutuhkan untuk
   validasi Let's Encrypt dan redirect).
4. **Password role.** Migrasi membuat `smile_ingest` dengan password yang
   tertulis di file SQL. Ganti di SQL Editor:
   `alter role smile_ingest password '<acak panjang>';`

Lalu di VM:

```bash
cp .env.example .env       # isi DOMAIN, ACME_EMAIL, DATABASE_URL
chmod 600 .env
docker compose up -d --build
docker compose ps          # app harus "healthy"
curl https://<domain>/v1/health
```

`DATABASE_URL`: salin host session pooler dari Supabase Dashboard → Connect
(format `aws-N-ap-northeast-1.pooler.supabase.com`, port 5432), user
`smile_ingest.rlzoixdjpzloemnternu`, tambahkan `?sslmode=require`. Kalau
terpaksa memakai transaction pooler (6543), set `DB_STATEMENT_CACHE_SIZE=0`.

Update kode: `docker compose up -d --build app` (rebuild, bukan sekadar
restart). **Urutan untuk v11:** terapkan `docs/migration_v11_neraca_air.sql`
(plus hak akses di bagian Neraca air) dulu, baru deploy. Kode v11 membaca
`node_actuator_config.stop_moisture_raw` di setiap `GET /v1/commands`; tanpa
migrasi semua poll ESP mendapat 503. **Urutan untuk v8:**
terapkan `docs/smile_migration_v8.sql` di Supabase dulu, baru deploy server ini.
Handler clock-events v8 ikut mengoreksi `irrigation_actions`/`fertigation_actions`,
dan akan membalas 503 kalau kolom v8 belum ada. Fertigasi dengan larutan nutrisi
butuh kolom `prewet_s`/`nutrient_batch_id`/`target_*_g` dan fungsi
`smile_dose_seconds` (sudah ada di Supabase per 2026-10-13), plus
`grant update (nutrient_batch_id) on public.fertigation_recommendations to smile_ingest;`
(belum ada). Tanpa grant itu server mematikan fertigasi auto dan menulis
peringatan di log saat start; irigasi auto tetap jalan. Log:
`docker compose logs -f app` (satu baris JSON per request; health 200 tidak
dicatat). Rotasi log Docker: 10 MB x 5 file per container.

## Redeploy, pindah server, dan backup

Semua service jalan di Docker Compose: `app` (image `smile-ingest:latest`,
uvicorn :8000, hanya di jaringan internal) dan `caddy` (port 80/443, TLS
otomatis). Database ada di Supabase, jadi tidak ada data di VM selain `.env`
dan sertifikat Caddy (volume `caddy_data`, bisa diterbitkan ulang otomatis).
`smile-testdb` hanya Postgres untuk `pytest`, bukan bagian dari produksi.

### Redeploy setelah ada perubahan kode

```bash
cd ~/smile-backendsrv
git pull
# 1. Kalau ada file baru di docs/migration_v*.sql: terapkan dulu di Supabase
#    SQL Editor (urut nomor). Kode baru bisa 503 kalau migrasi belum ada.
# 2. Rebuild + ganti container (restart saja TIDAK memuat kode baru):
docker compose up -d --build app
docker compose ps                     # app harus "healthy"
curl https://<domain>/v1/health
docker compose logs -f --tail=50 app  # cek tidak ada error saat start
```

Perubahan `Caddyfile` saja: `docker compose restart caddy`.
Perubahan `.env`: `docker compose up -d` (container dibuat ulang dengan env baru).

**Rollback:** `git checkout <commit-lama> && docker compose up -d --build app`,
lalu kembali ke `main` setelah masalah diperbaiki.

### Pindah ke server baru

Yang **tidak** ada di git dan harus disalin manual: `.env` (rahasia DB) dan
`firmware/secrets.h` (hanya untuk build firmware).

1. Server baru: install Docker + plugin compose, buka firewall TCP 80, 443 dan
   UDP 443, jadikan IP eksternal statis.
2. `git clone https://github.com/izerhaf7/smile-backendsrv.git && cd smile-backendsrv`
3. Salin `.env` dari backup, lalu `chmod 600 .env`.
4. Kalau Supabase memakai *network restrictions*, tambahkan IP server baru.
5. `docker compose up -d --build`
6. Ubah A record domain ke IP baru. Caddy otomatis mengambil sertifikat
   Let's Encrypt begitu DNS mengarah ke server baru (cek
   `docker compose logs caddy`).
7. Setelah trafik ESP terlihat masuk di server baru
   (`docker compose logs -f app`), matikan server lama: `docker compose down`.

Firmware **tidak** perlu di-flash ulang selama domain sama, karena sertifikat
tetap dari Let's Encrypt (lihat `cert_issuer acme` di `Caddyfile`).
Jangan lupa memindahkan penjadwalan `scripts/run_water_balance.py` kalau
sudah dijadwalkan di server lama.

### Backup penuh ke laptop

Di server (folder repo tanpa `.venv`/cache, termasuk `.env` dan `.git`):

```bash
cd ~ && tar czf smile-backup-$(date +%F).tgz \
  --exclude=.venv --exclude=.pytest_cache --exclude=__pycache__ \
  smile-backendsrv && chmod 600 smile-backup-*.tgz
```

Lalu dari laptop:

```bash
# SSH biasa:
scp <user>@<ip-server>:~/smile-backup-YYYY-MM-DD.tgz .
# atau lewat gcloud:
gcloud compute scp --zone <zone> --project <project> \
  <user>@<nama-instance>:~/smile-backup-YYYY-MM-DD.tgz .
```

Hapus arsip di server setelah tersalin (isinya rahasia DB):
`rm ~/smile-backup-*.tgz`. Simpan arsip di laptop di tempat yang aman.

## Token node

```bash
docker compose exec app python -m app.cli create-token --node <uuid-node>
docker compose exec app python -m app.cli rotate-token --node <uuid-node>
```

CLI meminta `DATABASE_ADMIN_URL` lewat prompt tersembunyi (koneksi admin,
misalnya user `postgres.<ref>` lewat session pooler). URL itu tidak disimpan
di mana pun. Token dicetak sekali; hanya SHA-256-nya yang masuk
`nodes.api_token_hash`. Tanpa koneksi DB sama sekali:

```bash
docker compose exec app python -m app.cli create-token --node <uuid> --sql-only
```

Perintah itu mencetak token dan `UPDATE` untuk dijalankan di SQL Editor.

Token baru langsung diterima. Token lama bisa tetap diterima paling lama 60
detik setelah rotasi (cache).

## Root CA untuk firmware (`ROOT_CA_PEM` di `secrets.h`)

Bundle siap pakai: **`firmware/root_ca_bundle.pem`**. Isinya ISRG Root X1, ISRG Root X2,
Root YE, dan Root YR, diunduh dari <https://letsencrypt.org/certificates/>. Salinan
per-root ada di `firmware/roots/`. Tempel seluruh isi bundle sebagai satu string:

```c
static const char ROOT_CA_PEM[] = R"PEM(
-----BEGIN CERTIFICATE-----
...isi firmware/root_ca_bundle.pem...
-----END CERTIFICATE-----
)PEM";
```

Alasannya: sejak 2025 Let's Encrypt menerbitkan dari hierarki baru. Rantai
yang dikirim server ini (dicek 2026-10-08) adalah
`ingest.nirbatas.id → YE1 → Root YE → (cross-sign) ISRG Root X2 → (cross-sign) ISRG Root X1`.

| Isi `ROOT_CA_PEM` | Rantai sekarang | Kalau cross-sign dihentikan |
|---|---|---|
| ISRG Root X1 saja | lolos | **gagal** |
| Bundle 4 root | lolos | lolos |

Diuji dengan `openssl verify`. Root YE/YR belum masuk trust store browser, tetapi
untuk ESP32 yang penting adalah apa yang kita tanam sendiri.
`WiFiClientSecure::setCACert` menerima bundle beberapa sertifikat. Rantai YE
memakai ECDSA P-384; mbedTLS bawaan Arduino-ESP32 mendukungnya, tapi tetap uji
satu node sebelum mem-flash semua.

Cek rantai yang sedang dikirim server:

```bash
openssl s_client -connect ingest.nirbatas.id:443 -servername ingest.nirbatas.id -showcerts </dev/null 2>/dev/null \
  | grep -E '^ *[0-9] s:|^ *i:'
```

Caddy dikunci ke Let's Encrypt saja (`cert_issuer acme`), jadi root tidak akan
berpindah ke CA lain secara diam-diam.

## Uji end-to-end

```bash
python3 scripts/sim_node.py --url https://<domain> --node <uuid> --token <token> \
    --minutes 150 --delta 177 --resend
```

Hasil yang diharapkan: event `inserted: 1`, readings `inserted: 150`, lalu
pengiriman kedua `duplicates` semua. Opsi lain: `--start-verified` (koreksi
linear), `--data-first` (event dikirim belakangan), `--clk`/`--start` untuk
mengulang segmen yang sama. Data simulator tercatat dengan
`firmware_version = smile-v7.0-sim`. Sebaiknya pakai node uji, atau hapus
barisnya setelah uji.

Simulator aktuator (v8) memakai `--actuator`. Ia melakukan poll tiap 15 s dengan
`X-Act`, menjalankan perintah secara virtual (pompa air, pompa pupuk di dalam
jendela air, rem dasar: sibuk, per-run, kuota harian, bilas), lalu mengirim
laporan CSV:

```bash
python3 scripts/sim_node.py --url https://<domain> --node <uuid> --token <token> \
    --actuator --run-s 600              # --offline-s 900 untuk §8 no. 3, --poll-s 5 untuk uji cepat
```

Lalu jalankan skenario §8 dari sisi app: buat perintah manual, ubah mode, atau
sisipkan prediksi uji, dan amati output simulator serta query audit di bawah.
Rem jeda minimal firmware tidak ditiru simulator.

## Query audit

```sql
-- Baris yang waktunya belum pernah terverifikasi, per node
select node_id, count(*), min(reading_timestamp_raw), max(reading_timestamp_raw)
from public.sensor_raw_readings
where time_status = 'unverified'
group by node_id;

-- Distribusi status waktu per node
select node_id, time_status, count(*)
from public.sensor_raw_readings
group by 1, 2 order by 1, 2;

-- Baris yang ditolak server (24 jam terakhir)
select received_at, node_id, endpoint, line_no, reason, raw_line
from public.ingest_rejects
where received_at > now() - interval '24 hours'
order by received_at desc;

-- Ringkasan alasan penolakan
select node_id, reason, count(*) from public.ingest_rejects group by 1, 2 order by 3 desc;

-- Riwayat sinkron jam per node
select node_id, clock_segment, ref_source, start_verified, delta_s,
       segment_start, rtc_before, ref_time, received_at
from public.clock_events
where node_id = '<uuid>'
order by rtc_before;

-- Besar koreksi yang diterapkan per segmen
select node_id, clock_segment, time_status, count(*),
       min(reading_timestamp - reading_timestamp_raw) as koreksi_min,
       max(reading_timestamp - reading_timestamp_raw) as koreksi_max
from public.sensor_raw_readings
where clock_segment is not null
group by 1, 2, 3 order by 1, 2;

-- Catatan kualitas (sensor gagal / di luar rentang)
select node_id, quality_flag, count(*)
from public.sensor_raw_readings
where quality_flag is not null
group by 1, 2 order by 3 desc;

-- Node yang lama tidak terlihat
select id, firmware_version, last_seen_at from public.nodes order by last_seen_at nulls first;
```

Aktuator (v8):

```sql
-- Perintah per status (7 hari terakhir)
select node_id, command, trigger, status, count(*)
from public.actuator_commands
where created_at > now() - interval '7 days'
group by 1, 2, 3, 4 order by 1, 2, 3, 4;

-- Perintah yang ditolak rem ESP, dengan alasannya
select created_at, node_id, command, trigger, water_s, dose_s, result_detail
from public.actuator_commands
where status = 'rejected'
order by created_at desc limit 50;

-- Perintah yang macet di 'sent' (ESP tidak pernah melaporkan running/hasil)
select id, node_id, command, sent_at, expires_at
from public.actuator_commands
where status = 'sent' and expires_at < now()
order by sent_at;

-- Aksi per trigger dan status eksekusi (riwayat dari ESP)
select node_id, triggered_by, execution_status, count(*),
       sum(duration_sec) as total_s, round(sum(estimated_volume_liter)::numeric, 2) as total_l
from public.irrigation_actions
where node_id is not null
group by 1, 2, 3 order by 1, 2, 3;

-- Fertigasi: dosis dan volume per node
select node_id, executed_by, execution_status, count(*),
       sum(actual_duration_sec) as dose_s, round(sum(actual_volume)::numeric, 4) as volume_l
from public.fertigation_actions
where node_id is not null
group by 1, 2, 3 order by 1, 2, 3;

-- dispatch_note per alasan (keputusan dispatcher yang TIDAK menghasilkan perintah)
select split_part(dispatch_note, ':', 1) as alasan, count(*), max(created_at) as terakhir
from public.irrigation_predictions
where dispatch_note is not null
group by 1 order by 2 desc;

-- Prediksi yang berhasil di-dispatch beserta hasil eksekusinya
select p.created_at, p.recommended_irrigation_mm, c.water_s, c.status, c.reason
from public.irrigation_predictions p
join public.actuator_commands c on c.id = p.dispatched_command_id
order by p.created_at desc limit 50;

-- Fertigasi per larutan: dosis, larutan, dan gram hara (view fertigation_delivered)
select a.node_id, a.nutrient_batch_id, count(*) as aksi, sum(a.actual_duration_sec) as dose_s,
       round(sum(d.solution_l)::numeric, 4) as larutan_l, round(sum(d.n_g)::numeric, 3) as n_g,
       round(sum(d.p2o5_g)::numeric, 3) as p2o5_g, round(sum(d.k2o_g)::numeric, 3) as k2o_g
from public.fertigation_actions a
join public.fertigation_delivered d on d.fertigation_action_id = a.id
group by 1, 2 order by 1, 2;

-- Irigasi I per plot per hari (WIB): air dari irrigation_actions (termasuk fertigasi) + larutan
select plot_id, day, round(sum(liter)::numeric, 3) as liter
from (
  select plot_id, (action_timestamp at time zone 'Asia/Jakarta')::date as day, estimated_volume_liter as liter
    from public.irrigation_actions where execution_status::text = 'success'
  union all
  select plot_id, (execution_timestamp at time zone 'Asia/Jakarta')::date, actual_volume
    from public.fertigation_actions where execution_status::text = 'success'
) x
group by 1, 2 order by 1, 2 desc;

-- Neraca air: ledger 48 jam terakhir per plot (WIB)
select plot_id, period_start at time zone 'Asia/Jakarta' as jam_wib,
       round(eto_mm::numeric, 3) as eto, eto_source, round(rain_mm::numeric, 2) as hujan, rain_source,
       round(irrigation_mm::numeric, 2) as irigasi, round(dr_model_mm::numeric, 2) as dr_model,
       theta_obs_raw, round(theta_obs_pct::numeric, 1) as theta_pct, round(dr_obs_mm::numeric, 2) as dr_obs,
       round(dr_end_mm::numeric, 2) as dr_akhir, corrected, calibration_status
from public.water_balance_ledger
where period_end > now() - interval '48 hours'
order by plot_id, period_end;

-- Neraca air: jumlah prediksi FAO-56 per kode reason per hari (WIB)
select (created_at at time zone 'Asia/Jakarta')::date as hari, split_part(reason, ':', 1) as kode,
       count(*), count(*) filter (where irrigation_triggered) as triggered
from public.irrigation_predictions
where decision_layer = 'fao56'
group by 1, 2 order by 1 desc, 2;

-- Neraca air: prediksi triggered, dispatch_note, dan perintah yang dihasilkan
select p.created_at at time zone 'Asia/Jakarta' as dibuat_wib, p.plot_id,
       round(p.dr_value_fao56::numeric, 1) as dr, round(p.recommended_irrigation_mm::numeric, 1) as mm,
       p.reason, p.dispatch_note, c.id as command_id, c.water_s, c.status, c.actual_water_s, c.result_detail
from public.irrigation_predictions p
left join public.actuator_commands c on c.id = p.dispatched_command_id
where p.decision_layer = 'fao56' and p.irrigation_triggered
order by p.created_at desc limit 50;

-- Rekomendasi fertigasi yang tidak dikirim, dengan larutan yang dipakai menghitung
select created_at, plot_id, target_n_g, target_p2o5_g, target_k2o_g, pump_duration_seconds,
       nutrient_batch_id, dispatch_note
from public.fertigation_recommendations
where dispatch_note is not null
order by created_at desc limit 50;
```

## Pengujian

```bash
docker run -d --name smile-testdb -e POSTGRES_PASSWORD=testpw \
  -p 127.0.0.1:55432:5432 postgres:17-alpine
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q
```

Tes membuat database `smile_test` baru, memuat stub skema Supabase (termasuk
tabel aksi/prediksi dan trigger `sync_node_*` yang sudah ada), menjalankan
`smile_migration_v7.sql`, `docs/smile_migration_v8.sql`,
`docs/smile_migration_v10.sql`, `docs/migration_v11_neraca_air.sql`, dan
`docs/migration_v12_arsip_cuaca.sql` (dua kali, untuk uji idempoten) apa
adanya, lalu `tests/schema_pending.sql` (hak akses yang belum ada di migrasi
mana pun), lalu menguji aplikasi sebagai role
`smile_ingest` (hak akses dan RLS ikut teruji). DSN admin bisa diganti lewat
env `TEST_ADMIN_DSN` .
