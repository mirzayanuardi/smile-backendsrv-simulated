# smile-backendsrv-simulated

Salinan ingest server SMILE untuk simulasi dan testing lokal. **Tidak terhubung
ke produksi maupun GitHub.**

- Sumber: `~/smile-backendsrv`, commit `2f2292e` (HEAD saat disalin, 2026-11-11),
  ditambah file kerja yang belum di-commit (`sim/`, `supabase_database.md`, laporan, ceklist).
- Folder `.git` **sengaja tidak disalin**, jadi tidak ada remote dan commit tidak bisa di-push.
- Semua file lain disalin persis (diverifikasi SHA-256), lalu hanya file di bawah ini yang diubah.

## Yang berbeda dari produksi

| File | Perubahan | Alasan |
|---|---|---|
| `docker-compose.yml` | Service `app` **identik** dengan produksi, ditambah `depends_on: db`. Ditambah service `db` (Postgres 17) dan volume `simdb` | Pengganti Supabase |
| `.env` (baru) | Salinan `.env.example`. Hanya `DATABASE_URL` yang diubah, ke `db:5432` lokal | Semua nilai lain = default kode = `.env.example` |
| `sim/seed.sql` | Data awal: 2 node (token dummy), plot Bogor, parameter Latosol, konfigurasi aktuator | Mengikuti seed di `tests/conftest.py` |
| `sim/sim.sh` | Perintah `up`, `down`, `reset`, `logs`, `psql`, `node`, `test` | |
| `sim/compare_schema.py` (baru) | Membandingkan skema DB simulasi dengan `supabase_database.md` | Mengukur selisih dengan produksi |
| `sim/docker-compose.yml`, `sim/sim.env` | Dihapus | Digantikan compose dan `.env` di root |

## Yang sengaja tidak disimulasikan

- **Proxy HTTPS/TLS.** Di produksi, app ada di belakang proxy di `127.0.0.1:8080`. Di sini app diakses langsung lewat HTTP di port yang sama. `Caddyfile` disalin tapi tidak dipakai.
- **Supabase**: Auth, PostgREST, Realtime, Supavisor pooler, `sslmode=require`, pg_cron/edge function.
  Hanya skema Postgres yang dibangun ulang.

## Yang BELUM tentu sama dengan produksi

1. **Skema DB** dibangun dari `tests/schema_stub.sql` (stub per 2026-10-08) ditambah migrasi v7, v8,
   v10, v11, v12 dan `tests/schema_pending.sql`. Jalankan `sim/compare_schema.py` untuk melihat selisih kolom, enum, dan RLS.
   Index, fungsi, trigger, view (misalnya flag `maintenance`/`soil_sensor_down`), dan GRANT
   hanya bisa disamakan lewat `pg_dump --schema-only` dari produksi.
2. **Nilai `.env` produksi** tidak diketahui. Kalau produksi meng-override default (misalnya
   `FERTIGATION_AUTO_STATUSES`), perilaku simulasi akan berbeda.
3. **Versi Postgres** produksi (Supabase) belum dicek. Simulasi memakai 17, sama dengan tes repo.
4. **Open-Meteo** tetap dipanggil sungguhan (API publik, hanya dibaca). Set `WX_FORECAST_ENABLED=0` dan
   `WX_OBSERVED_ENABLED=0` di `.env` kalau mau offline penuh.

## Menjalankan

Prasyarat (sekali): `sudo systemctl enable --now docker && sudo usermod -aG docker $USER`, lalu login ulang.

```bash
cd ~/smile-backendsrv-simulated
./sim/sim.sh up                   # build + start; cek http://127.0.0.1:8080/v1/health
python3 sim/compare_schema.py     # selisih skema vs supabase_database.md
./sim/sim.sh node --minutes 150   # node virtual mengirim data
./sim/sim.sh node --resend        # uji dedup
./sim/sim.sh test                 # pytest (Postgres terpisah di 55432)
./sim/sim.sh reset                # kosongkan DB, ulang dari migrasi
```

Node uji (token dummy, hanya berlaku di DB lokal):

| Node | UUID | Token |
|---|---|---|
| 1 (aktuator + sensor) | `11111111-1111-1111-1111-111111111111` | `sim-token-node-1` |
| 2 (sensor saja) | `22222222-2222-2222-2222-222222222222` | `sim-token-node-2` |

Port: app `127.0.0.1:8080`, DB simulasi `127.0.0.1:55433` (admin `postgres`/`simadmin`),
DB tes `127.0.0.1:55432`.

Catatan: `.claude/settings.local.json` (salinan) mengaktifkan MCP server `supabase`. Saat ini MCP itu
tidak terkonfigurasi di mesin ini, tapi kalau nanti dipasang, kemungkinan besar MCP itu menunjuk ke
Supabase **produksi**.
