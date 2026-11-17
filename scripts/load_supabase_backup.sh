#!/usr/bin/env bash
# Muat backup `supabase db dump` (skema + data) ke database BARU di Postgres lokal (Docker).
# Database simulasi yang sekarang tidak disentuh; setelah selesai, arahkan DATABASE_URL ke TARGET_DB.
#
#   PG_CONTAINER=<nama container postgres> bash scripts/load_supabase_backup.sh supabase_backup
#
# Hanya schema public yang dimuat. Data auth.* (sesi, refresh token, hash password) dan storage.*
# dilewati; auth.users diisi id saja (diambil dari kolom FK di public) supaya relasi tetap utuh.
set -euo pipefail

DIR=${1:?pemakaian: $0 <folder backup>}
PG_CONTAINER=${PG_CONTAINER:?isi PG_CONTAINER, lihat: docker ps}
PG_USER=${PG_USER:-postgres}
TARGET_DB=${TARGET_DB:-smile_supabase_copy}
SCHEMA=$(ls "$DIR"/backup_skema_*.sql)
DATA=$(ls "$DIR"/backup_isi_data_*.sql)
LOG=./load_${TARGET_DB}.log

dst() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -q "$@"; }

if [ -n "$(dst -d postgres -Atc "select 1 from pg_database where datname = '$TARGET_DB'")" ]; then
  echo "Database $TARGET_DB sudah ada. Drop dulu atau pakai TARGET_DB lain." >&2
  exit 1
fi

echo "1/5 Buat database $TARGET_DB + stub Supabase (role, schema auth/extensions)"
dst -d postgres -v ON_ERROR_STOP=1 -c "create database $TARGET_DB"
dst -d "$TARGET_DB" -v ON_ERROR_STOP=1 <<'SQL'
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
    end if;
  end loop;
  if not exists (select 1 from pg_roles where rolname = 'smile_ingest') then
    raise warning 'role smile_ingest belum ada; dibuat tanpa password (set: alter role smile_ingest password ...)';
    create role smile_ingest login;
  end if;
end $$;

create schema extensions;
-- Sama seperti tests/schema_stub.sql: auth.users cukup id untuk FK.
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $f$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')), '')::uuid
$f$;
create function auth.role() returns text language sql stable as $f$
  select nullif(coalesce(current_setting('request.jwt.claim.role', true),
                         (current_setting('request.jwt.claims', true)::jsonb ->> 'role')), '')
$f$;
create function auth.jwt() returns jsonb language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''),
                  nullif(current_setting('request.jwt.claims', true), ''))::jsonb
$f$;
-- smile_ingest sengaja TIDAK diberi usage schema auth (sama dengan Supabase).
grant usage on schema auth, extensions to anon, authenticated, service_role;
SQL

echo "2/5 Muat skema ($SCHEMA)"
# pg_cron, pg_net, supabase_vault hanya ada di image Supabase; tidak dipakai objek public.
sed 's/\r$//' "$SCHEMA" \
  | grep -vE '^CREATE EXTENSION IF NOT EXISTS "(pg_cron|pg_net|supabase_vault)"' \
  | dst -d "$TARGET_DB" 2> "$LOG" || true
if grep -q 'ERROR' "$LOG"; then
  echo "  Ada error saat memuat skema (lihat $LOG):"
  grep 'ERROR' "$LOG" | head -20 | sed 's/^/  /'
fi

echo "3/5 Muat data public ($DATA), satu transaksi"
# File diawali SET session_replication_role = replica: FK dan trigger tidak dicek selama load.
sed 's/\r$//' "$DATA" \
  | awk '/^SELECT pg_catalog\.setval\(.*"(auth|storage)"\./ { next }
         /^INSERT INTO "(auth|storage)"\./ { skip = 1 }
         skip { if (/;$/) skip = 0; next }
         { print }' \
  | dst -d "$TARGET_DB" -v ON_ERROR_STOP=1 -1

echo "4/5 Isi auth.users dari kolom FK di public"
dst -d "$TARGET_DB" -v ON_ERROR_STOP=1 -At <<'SQL'
do $$
declare c record;
begin
  for c in
    select con.conrelid::regclass as tbl, a.attname as col
    from pg_constraint con
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
    where con.contype = 'f' and con.confrelid = 'auth.users'::regclass
  loop
    execute format('insert into auth.users (id) select distinct %I from %s where %I is not null on conflict do nothing',
                   c.col, c.tbl, c.col);
  end loop;
end $$;
select count(*) || ' user' from auth.users;
SQL

echo "5/5 Jumlah baris per tabel public"
dst -d "$TARGET_DB" -v ON_ERROR_STOP=1 <<'SQL'
select format('select %L as tabel, count(*) as baris from %I.%I', tablename, schemaname, tablename)
from pg_tables where schemaname = 'public' order by tablename
\gexec
SQL

echo
echo "Selesai. Arahkan app ke salinan ini: ganti nama database di DATABASE_URL (.env) menjadi /$TARGET_DB,"
echo "lalu: docker compose up -d"
