#!/usr/bin/env bash
# Pengendali stack SIMULASI SMILE (smile-backendsrv-simulated). Tidak menyentuh produksi.
#
#   sim/sim.sh up        build + jalankan app & db (http://127.0.0.1:8080)
#   sim/sim.sh down      hentikan (data DB tetap)
#   sim/sim.sh reset     hapus data DB, ulang dari migrasi + seed
#   sim/sim.sh logs      ikuti log app
#   sim/sim.sh psql      buka psql sebagai admin DB simulasi
#   sim/sim.sh node ...  jalankan scripts/sim_node.py ke server simulasi (node SIM_NODE)
#   sim/sim.sh esp [--soil-m 60] [--rain-rate 0.05]
#                        input ala ESP: ganti bacaan 25 jam terakhir node SIM_NODE, langsung
#                        satu siklus keputusan, tunggu dispatcher, tampilkan keputusan + perintah
#   sim/sim.sh rf off|shadow|active   ubah RF_MODE di .env lalu restart app
#   sim/sim.sh test      jalankan pytest (Postgres terpisah smile-testdb:55432, Python 3.12)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.sim.yml")
URL="http://127.0.0.1:8080"
# Node data impor Supabase. Token hanya berlaku di DB simulasi (hash-nya diset manual, lihat SIMULASI.md).
# Setelah `reset` (seed), pakai SIM_NODE=11111111-1111-1111-1111-111111111111 SIM_TOKEN=sim-token-node-1.
NODE="${SIM_NODE:-fe3e0beb-cdd7-43cd-a409-07e474d1518b}"
TOKEN="${SIM_TOKEN:-sim-token-fe3e0beb}"
PSQL=("${COMPOSE[@]}" exec -T db psql -U postgres -d smile -v ON_ERROR_STOP=1)

# Pengaman: hanya jalan kalau DATABASE_URL menunjuk ke container db lokal.
if ! grep -Eq '^DATABASE_URL=postgresql://[^@]+@db:5432/' "$ROOT/.env"; then
  echo "BERHENTI: DATABASE_URL di .env tidak menunjuk ke container db lokal." >&2
  exit 1
fi

case "${1:-}" in
  up)    "${COMPOSE[@]}" up -d --build --wait && echo "Server simulasi: $URL/v1/health" ;;
  down)  "${COMPOSE[@]}" down ;;
  reset) "${COMPOSE[@]}" down -v && "${COMPOSE[@]}" up -d --build --wait ;;
  logs)  "${COMPOSE[@]}" logs -f app ;;
  psql)  "${COMPOSE[@]}" exec db psql -U postgres -d smile ;;
  node)  shift; python3 "$ROOT/scripts/sim_node.py" --url "$URL" --node "$NODE" --token "$TOKEN" "$@" ;;
  esp)
    shift
    PLOT=$("${PSQL[@]}" -Atc "select plot_id from public.nodes where id = '$NODE'")
    [ -n "$PLOT" ] || { echo "node $NODE tidak ada di DB simulasi" >&2; exit 1; }
    # Bacaan lama di jendela yang sama punya timestamp sama (beda clock_segment) dan ikut terbaca:
    # dibuang dulu supaya keputusan hanya melihat input ini. Hanya data simulasi 26 jam terakhir.
    "${PSQL[@]}" -qc "delete from public.calibrated_sensor_raw_readings where node_id = '$NODE' and reading_timestamp > now() - interval '26 hours';
                     delete from public.sensor_raw_readings where node_id = '$NODE' and reading_timestamp > now() - interval '26 hours';"
    python3 "$ROOT/scripts/sim_node.py" --url "$URL" --node "$NODE" --token "$TOKEN" \
      --minutes 1500 --delta 0 --start-verified --fail-rate 0 --rain-rate 0 "$@"
    docker exec smile-ingest-app python scripts/run_water_balance.py --plot "$PLOT" --force | sed -n '/^keputusan/,$p'
    echo "menunggu dispatcher (${DISPATCH_WAIT_S:-65} s)..."; sleep "${DISPATCH_WAIT_S:-65}"
    "${PSQL[@]}" -c "select to_char(p.created_at at time zone 'Asia/Jakarta', 'HH24:MI:SS') wib, p.decision_layer layer,
                            p.status_model, round(p.prediction_dr_value::numeric, 1) dr24, p.irrigation_triggered siram,
                            round(p.recommended_irrigation_mm::numeric, 1) mm, p.dispatch_note, c.status cmd, c.water_s
                       from public.irrigation_predictions p
                       left join public.actuator_commands c on c.id = p.dispatched_command_id
                      where p.plot_id = '$PLOT' order by p.created_at desc limit 3"
    ;;
  rf)
    case "${2:-}" in off|shadow|active) ;; *) echo "pakai: sim/sim.sh rf off|shadow|active" >&2; exit 1 ;; esac
    if grep -q '^RF_MODE=' "$ROOT/.env"; then sed -i "s/^RF_MODE=.*/RF_MODE=$2/" "$ROOT/.env"
    else printf 'RF_MODE=%s
' "$2" >> "$ROOT/.env"; fi
    "${COMPOSE[@]}" up -d --force-recreate --wait app
    for _ in $(seq 30); do   # model dimuat di background (~6 s)
      docker logs smile-ingest-app 2>&1 | grep -m1 -E '"event": "rf_loaded"|rf: ' && break; sleep 1
    done
    ;;
  test)
    # Cluster terpisah: tes men-drop role smile_ingest yang juga dipakai DB simulasi.
    shift
    docker start smile-testdb >/dev/null 2>&1 || docker run -d --name smile-testdb \
      -e POSTGRES_PASSWORD=testpw -p 127.0.0.1:55432:5432 postgres:17-alpine >/dev/null
    until docker exec smile-testdb pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
    docker run --rm --network host -v "$ROOT:/src" -w /src python:3.12-slim sh -c \
      "pip install -q --root-user-action=ignore -r requirements-dev.txt && python -m pytest -q -p no:cacheprovider $*"
    ;;
  *)     sed -n '2,15p' "$0"; exit 1 ;;
esac
