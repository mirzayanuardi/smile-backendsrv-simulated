# Integrasi Aktuator SMILE v8: Kontrak Sistem

> Dokumen ini adalah **satu-satunya sumber kebenaran** untuk integrasi aktuator. Taruh salinannya di repo app (`docs/`) dan repo server (`docs/`). Kalau ada konflik antara dokumen ini dan prompt, dokumen ini yang benar. Firmware v8 dan `smile_migration_v8.sql` sudah mengikuti kontrak ini.

## 1. Prinsip yang dikunci

| Komponen | Peran | Tidak boleh |
|---|---|---|
| **Server** (otak) | Memutuskan kapan dan berapa lama: mode auto dari rule engine, mode manual dari app. Menerjemahkan mm → detik. Menyimpan riwayat. | Mengirim perintah tanpa durasi |
| **ESP32** (otot + rem) | Menjalankan perintah berdurasi, menolak yang melanggar batas aman, fallback lokal saat offline lama | Memutuskan irigasi sendiri di luar fallback |
| **App** | Mengubah mode, membuat perintah manual, menampilkan status dan riwayat | Menulis ke `irrigation_actions` / `fertigation_actions` / `fertigation_recommendations` |

**Istilah kanal** (mengikuti kolom yang sudah ada di `nodes`):
- `valve_*` = **kanal irigasi**. Fisiknya pompa air + selang (tidak ada solenoid).
- `pump_*` = **kanal fertigasi**. Fisiknya pompa peristaltik.

## 2. Aliran data

```
APP ── update nodes.valve_mode / pump_mode ─────────────────────────────┐
APP ── insert actuator_commands (trigger=manual) ──┐                    │
                                                   ▼                    ▼
SERVER dispatcher ── insert (trigger=rule_engine) ► actuator_commands   nodes
                                                   │  status: pending   ▲
ESP ── GET /v1/commands (tiap 15 s) ───────────────┤  → sent            │ valve_is_on / pump_is_on
        header X-Act (status pompa) ───────────────┼────────────────────┘ (dari header X-Act)
                                                   │  → running
ESP ── POST /v1/ingest/actuations (CSV) ───────────┤  → executed / stopped / interrupted / rejected / expired
                                                   └► irrigation_actions + fertigation_actions (riwayat)
```

## 3. Siklus hidup perintah (`actuator_commands.status`)

```
pending ──(server kirim ke ESP)──► sent ──(X-Act melaporkan cmd ini)──► running
   │                                 │                                     │
   │ lewat expires_at                ├─► rejected (rem ESP menolak)        ├─► executed
   ▼                                 └─► expired  (ESP terima terlambat)   ├─► stopped
expired                                                                    └─► interrupted
```

- `expires_at` default 10 menit, maksimal 15 menit (dipaksa trigger DB).
- **Anti tumpuk:** satu perintah aksi (`irrigate`/`fertigate`) berstatus `pending`/`sent` per node. `stop` selalu boleh.
- **Penjaga mode di database:** perintah `manual` hanya diterima saat mode kanal = `manual`; perintah `rule_engine`/`schedule` hanya saat mode = `auto`.

## 4. Protokol ESP ↔ server

Header standar semua request (dari v7): `Authorization: Bearer <token>`, `X-Node-Id`, `X-Firmware-Version`, `X-Schema-Version: 1`.

### 4.1 `GET /v1/commands` (tiap 15 s saat online)

**Header tambahan dari ESP:**
```
X-Act: w=1;d=0;cmd=<uuid atau ->;left=45;res=1;cfg=3;tw=120;td=0
```
| Kunci | Arti |
|---|---|
| `w`, `d` | pompa air / pompa pupuk sedang menyala (1/0) |
| `cmd` | UUID perintah yang sedang berjalan, `-` kalau idle atau fallback |
| `left` | sisa detik |
| `res` | ember berisi air (1) atau habis (0); selalu 1 kalau float switch tidak dipasang |
| `cfg` | versi config yang dipegang ESP |
| `tw`, `td` | total detik pompa air / pupuk hari ini |

**Server wajib:** update `nodes.valve_is_on = w`, `nodes.pump_is_on = d` (dan `*_updated_at` hanya kalau berubah), `last_seen_at`; kalau `cmd` bukan `-` dan statusnya `sent`, ubah ke `running` + `started_at`.

**Respons `200`, `text/plain`, satu instruksi per baris:**
```
T 1791360060
G 3 max_run=600 max_water_day=1800 max_dose_day=300 min_gap=1800 flush=30 fb_thr=-1 fb_run=120 fb_off_h=24 m_start=6 m_end=9
C 7f3c...-uuid irrigate manual 60 0 540
C 9a1b...-uuid stop manual 0 0 590
```
- `T` = epoch UTC server (selalu ada).
- `G` = config, **hanya** kalau `cfg` dari ESP ≠ `node_actuator_config.config_version`. `fb_thr=-1` kalau `fallback_threshold_raw` NULL.
- `C <uuid> <command> <trigger> <water_s> <dose_s> <ttl_s>`: perintah `pending` yang belum kedaluwarsa, urut `created_at`, maksimal 4. `ttl_s = floor(expires_at − now())`, minimal 1. Setelah dikirim → `status='sent'`, `sent_at=now()`.
- Baris yang tidak dikenal diabaikan firmware. Protokol boleh ditambah tanpa merusak node lama.

### 4.2 `POST /v1/ingest/actuations` (CSV, mekanisme cursor yang sama dengan readings)

```
ev_id,cmd_id,command,trigger,clk,ts_start,water_s,dose_s,status,detail
5e1a90cc,7f3c...-uuid,irrigate,manual,a3f1c2d0,2026-10-11T07:02:11+07:00,60,0,executed,
0b77d2e1,,irrigate,local_fallback,a3f1c2d0,2026-10-12T06:00:40+07:00,120,0,executed,
c41f0a92,,irrigate,rule_engine,a3f1c2d0,2026-10-12T07:15:00+07:00,,,interrupted,power_or_reset
```

| Kolom | Isi |
|---|---|
| `ev_id` | 8 hex, unik per event (kunci anti-duplikat) |
| `cmd_id` | UUID perintah; kosong untuk `local_fallback` |
| `command` | `irrigate` / `fertigate` / `stop` |
| `trigger` | `manual` / `rule_engine` / `schedule` / `local_fallback` |
| `clk`, `ts_start` | segmen jam + waktu mulai mentah (dikoreksi seperti readings, lewat `clock_events`) |
| `water_s`, `dose_s` | durasi **aktual**; kosong = tidak diketahui (aksi terputus listrik) |
| `status` | `executed`, `stopped`, `interrupted`, `rejected_limit`, `rejected_unsafe`, `rejected_invalid`, `expired` |
| `detail` | alasan: `busy`, `day_water`, `day_dose`, `min_gap`, `reservoir_empty`, `dose_or_flush`, `no_dose_pump`, `water_s`, `power_or_reset`, `hard_guard`, `stop_command`, `idle` |

Kode status HTTP dan aturan "masalah per baris tetap 200" **sama persis** dengan `/v1/ingest/readings`. Urutan upload firmware: clock events → actuations → readings.

### 4.3 Pemetaan laporan ESP → database

| `status` ESP | `actuator_commands.status` | Baris riwayat | `execution_status` |
|---|---|---|---|
| `executed` | `executed` | ya | `success` |
| `stopped` | `stopped` | ya | `overridden` |
| `interrupted` | `interrupted` | ya | `failed` |
| `rejected_*` | `rejected` (+ `result_detail`) | tidak | — |
| `expired` | `expired` | tidak | — |
| `stop` + `executed` | `executed` | tidak | — |

**Baris riwayat** untuk `irrigate` dan `fertigate` (fertigasi juga mengalirkan air, jadi airnya ikut neraca air):
- `irrigation_actions`: `node_id`, `plot_id`, `command_id`, `device_event_id=ev_id`, `action_timestamp` (terkoreksi), `action_timestamp_raw`, `clock_segment`, `triggered_by` (`trigger`), `valve_action='open'`, `duration_sec=water_s`, `estimated_volume_liter = water_s/60 × water_flow_lpm`, `execution_status`, `irrigation_prediction_id` (dari perintah), `detail`.
- `fertigation_actions` (hanya `fertigate`): `node_id`, `plot_id`, `command_id`, `device_event_id`, `execution_timestamp` (terkoreksi), `execution_timestamp_raw`, `clock_segment`, `recommendation_id` (dari perintah), `actual_duration_sec=dose_s`, `actual_volume` dalam **liter** (`dose_s × dose_flow_ml_per_s / 1000`), `pump_action='on'`, `execution_status`, `detail`.
- Insert `ON CONFLICT (node_id, device_event_id) DO NOTHING`.

## 5. Dispatcher mode auto (job di server, tiap 60 s)

1. **Kedaluwarsa:** `pending` yang lewat `expires_at` → `expired`.
2. **Irigasi auto** (node `valve_mode='auto'`, `has_irrigation`, `water_flow_lpm` dan `wetted_area_m2` terisi): ambil prediksi terbaru plot itu dengan `irrigation_triggered = true`, `recommended_irrigation_mm > 0`, `dispatched_command_id IS NULL`, `dispatch_note IS NULL`, umur ≤ 30 menit.
   - Di luar jendela pagi (jam WIB `morning_start_hour`–`morning_end_hour`) → `dispatch_note='outside_window'`.
   - Irigasi terakhir node ini lebih baru dari `min_gap_s` → `dispatch_note='min_gap'`.
   - Masih ada perintah aksi `pending`/`sent` → lewati dulu, coba lagi menit berikutnya.
   - Konversi: $t = \dfrac{I \times A}{Q} \times 60$, dengan $I$ = `recommended_irrigation_mm` (mm), $A$ = `wetted_area_m2` (m²), $Q$ = `water_flow_lpm` (L/menit), $t$ dalam detik (1 mm × 1 m² = 1 L). Dibulatkan, dibatasi `max_run_s` (catat `clamped` di `reason`), di bawah 5 s → `dispatch_note='too_small'`.
   - Insert perintah `trigger='rule_engine'`, `irrigation_prediction_id`, `reason` dari prediksi, lalu isi `dispatched_command_id`.
3. **Fertigasi auto** (node `pump_mode='auto'`, `has_fertigation`): hanya untuk rekomendasi berstatus yang ditetapkan tim (lihat §9). `dose_s = round(pump_duration_seconds)` (maks 300), `water_s = dose_s + 2 + flush_s`.

Rule engine (FAO-56 + RF, Layer 1–3) **bukan** bagian dispatcher. Ia cukup menulis `irrigation_predictions` dengan `irrigation_triggered` dan `recommended_irrigation_mm`. Pertimbangan hujan dan Dr ≥ RAW ada di rule engine; jendela waktu, jeda, dan konversi ada di dispatcher.

## 6. Lapisan keselamatan

| Lapis | Di mana | Isi |
|---|---|---|
| 1 | Database (trigger + CHECK) | Mode harus cocok, durasi ≤ 600 s, fertigasi wajib bilas ≥ 30 s, anti tumpuk, kedaluwarsa ≤ 15 menit |
| 2 | Server | Jendela pagi, jeda minimal, konversi dan pembatasan durasi |
| 3 | **Firmware (batas keras, tidak bisa ditimpa)** | ≤ 600 s per perintah, ≤ 1800 s air / hari, ≤ 300 s pupuk / hari, jeda ≥ 900 s untuk auto/fallback, bilas ≥ 30 s, perintah kedaluwarsa ditolak, perintah ganda diabaikan |
| 4 | Firmware runtime | Pin OFF di baris pertama `setup()`, pompa pupuk hanya di dalam jendela pompa air, ember habis → berhenti, penjaga 605 s, watchdog reset → pompa mati |
| 5 | Hardware | Pull-down di input relay/MOSFET, dioda flyback di motor, kapasitor 470–1000 µF di jalur pompa, ember lebih rendah dari ujung selang (anti sifon) |

Perintah **manual** tidak kena jeda minimal (keputusan manusia), tapi tetap kena batas per-run dan harian.

## 7. Fallback lokal (firmware)

Menyiram `fallback_run_s` (default 120 s) hanya jika **semua** terpenuhi:
1. Tidak ada kontak sukses dengan server ≥ `fallback_offline_h` (default 24 jam, minimal 6).
2. Median kelembapan per jam < `fallback_threshold_raw` selama 3 jam berturut-turut. Data tanah yang hilang memutus rangkaian.
3. Hujan 24 jam terakhir < 2 mm (kalau sensor hujan error, syarat ini dilewati).
4. Di jendela pagi (kalau jam terverifikasi).
5. Fallback terakhir ≥ 24 jam lalu, plus semua rem lapis 3.

**Nonaktif selama `fallback_threshold_raw` NULL.** Isi setelah kalibrasi kelembapan selesai. Dicatat sebagai `triggered_by='local_fallback'`.

## 8. Rencana uji integrasi

| # | Skenario | Hasil yang diharapkan |
|---|---|---|
| 1 | Mode manual, tekan "Siram 60 s" | `pending → sent → running → executed` ≤ 15 s mulai; baris `irrigation_actions` `manual/success`, durasi 60 |
| 2 | Tekan "Hentikan" saat berjalan | perintah aksi `stopped`, `execution_status=overridden`, durasi aktual < 60 |
| 3 | Kirim perintah, cabut WiFi 15 menit | `expired`, tidak ada riwayat |
| 4 | Cabut listrik ESP di tengah siram | setelah menyala: `interrupted`, `duration_sec` NULL, `detail=power_or_reset` |
| 5 | Siram manual sampai kuota harian habis | perintah berikutnya `rejected`, detail `day_water` |
| 6 | Ubah ke mode auto, insert prediksi uji (`irrigation_triggered=true`, 2 mm) di jendela pagi | perintah `rule_engine` terbentuk, durasi sesuai rumus §5 |
| 7 | Prediksi uji di luar jendela | `dispatch_note='outside_window'`, tidak ada perintah |
| 8 | Insert manual saat mode auto (lewat app) | app menampilkan pesan error dari DB, tidak ada perintah |
| 9 | Ubah `node_actuator_config` | versi naik, ESP menerima baris `G` di poll berikutnya, OLED berubah |
| 10 | Float switch dilepas saat menyiram | `interrupted`, `detail=reservoir_empty` |
| 11 | Uji fallback di meja: `fallback_offline_h=6`, ambang tinggi, server dimatikan | setelah ≥ 6 jam + 3 jam kering: menyiram sekali, `local_fallback` muncul di riwayat setelah online |

Uji 1–10 bisa di meja dengan LED/relay sebelum pompa sungguhan dipasang.

## 9. Hal yang masih harus diisi tim

1. **GPIO dan level aktif** relay/MOSFET → `PIN_WATER_PUMP`, `PIN_DOSE_PUMP`, `ACT_ACTIVE_HIGH`, `PIN_RESERVOIR` di firmware.
2. **Debit pompa air** (uji tampung 60 detik di instalasi final) → `water_flow_lpm`.
3. **Luas basah** $A$ (misalnya $\pi r^2$ dari jari-jari tajuk) → `wetted_area_m2`.
4. **Debit pompa peristaltik** → `dose_flow_ml_per_s`.
5. **Ambang fallback** dari kalibrasi → `fallback_threshold_raw`.
6. **Label enum** `fertigation_actions.executed_by` dan `fertigation_recommendations.status` belum diketahui. Server membaca label enum saat start dan hanya mengisi `executed_by` kalau labelnya cocok. Status rekomendasi yang boleh di-dispatch otomatis harus ditetapkan tim (default: tidak ada, sehingga fertigasi auto belum aktif).
