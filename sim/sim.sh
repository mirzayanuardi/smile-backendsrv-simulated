#!/usr/bin/env bash
# Pengendali stack SIMULASI SMILE (smile-backendsrv-simulated). Tidak menyentuh produksi.
#
#   sim/sim.sh up        build + jalankan app & db (http://127.0.0.1:8080)
#   sim/sim.sh down      hentikan (data DB tetap)
#   sim/sim.sh reset     hapus data DB, ulang dari migrasi + seed
#   sim/sim.sh logs      ikuti log app
#   sim/sim.sh psql      buka psql sebagai admin DB simulasi
#   sim/sim.sh node ...  jalankan scripts/sim_node.py ke server simulasi (node 1)
#   sim/sim.sh test      jalankan pytest (Postgres terpisah smile-testdb:55432, Python 3.12)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml")
URL="http://127.0.0.1:8080"
NODE1="11111111-1111-1111-1111-111111111111"
TOKEN1="sim-token-node-1"

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
  node)  shift; python3 "$ROOT/scripts/sim_node.py" --url "$URL" --node "$NODE1" --token "$TOKEN1" "$@" ;;
  test)
    # Cluster terpisah: tes men-drop role smile_ingest yang juga dipakai DB simulasi.
    shift
    docker start smile-testdb >/dev/null 2>&1 || docker run -d --name smile-testdb \
      -e POSTGRES_PASSWORD=testpw -p 127.0.0.1:55432:5432 postgres:17-alpine >/dev/null
    until docker exec smile-testdb pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
    docker run --rm --network host -v "$ROOT:/src" -w /src python:3.12-slim sh -c \
      "pip install -q --root-user-action=ignore -r requirements-dev.txt && python -m pytest -q -p no:cacheprovider $*"
    ;;
  *)     sed -n '2,10p' "$0"; exit 1 ;;
esac
