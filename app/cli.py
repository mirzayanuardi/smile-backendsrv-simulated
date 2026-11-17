"""CLI admin untuk token node.

    python -m app.cli create-token --node <uuid>
    python -m app.cli rotate-token --node <uuid>
    python -m app.cli create-token --node <uuid> --sql-only

Menulis api_token_hash butuh koneksi admin (role smile_ingest sengaja tidak
punya hak itu). URL admin dibaca dari env DATABASE_ADMIN_URL kalau ada; kalau
tidak, diminta lewat prompt tersembunyi dan tidak pernah disimpan ke disk.
Dengan --sql-only tidak ada koneksi DB sama sekali: CLI mencetak token dan
perintah UPDATE untuk dijalankan sendiri di Supabase SQL Editor.
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import os
import secrets
import sys
import uuid

import asyncpg

from .auth import hash_token


def _admin_url() -> str:
    url = os.environ.get("DATABASE_ADMIN_URL", "").strip()
    if url:
        return url
    if not sys.stdin.isatty():
        sys.exit("DATABASE_ADMIN_URL kosong dan tidak ada TTY untuk prompt.")
    url = getpass.getpass("DATABASE_ADMIN_URL (tidak ditampilkan, tidak disimpan): ").strip()
    if not url:
        sys.exit("dibatalkan")
    return url


def _print_token(node_id: uuid.UUID, token: str) -> None:
    print()
    print(f"Node   : {node_id}")
    print(f"Token  : {token}")
    print()
    print("Salin token ini ke secrets.h firmware SEKARANG. Token tidak disimpan")
    print("di mana pun dan tidak bisa ditampilkan lagi (hanya hash-nya di DB).")
    print("Server menerima token baru langsung; token lama bisa tetap diterima")
    print("paling lama 60 detik karena cache.")


async def _write_hash(node_id: uuid.UUID, token_hash: str, rotate: bool) -> None:
    # statement_cache_size=0 supaya aman juga lewat transaction pooler.
    conn = await asyncpg.connect(_admin_url(), statement_cache_size=0, timeout=15)
    try:
        async with conn.transaction():
            row = await conn.fetchrow(
                "select api_token_hash from public.nodes where id = $1 for update", node_id
            )
            if row is None:
                sys.exit(f"node {node_id} tidak ditemukan di public.nodes")
            if row["api_token_hash"] and not rotate:
                sys.exit("node ini sudah punya token. Pakai rotate-token untuk menggantinya.")
            await conn.execute(
                "update public.nodes set api_token_hash = $2 where id = $1", node_id, token_hash
            )
    finally:
        await conn.close()


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="python -m app.cli")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("create-token", "rotate-token"):
        sp = sub.add_parser(name)
        sp.add_argument("--node", required=True, help="UUID node (public.nodes.id)")
        sp.add_argument(
            "--sql-only",
            action="store_true",
            help="jangan konek ke DB; cetak perintah UPDATE untuk SQL Editor",
        )
    args = p.parse_args(argv)

    try:
        node_id = uuid.UUID(args.node)
    except ValueError:
        sys.exit("--node harus UUID")

    token = secrets.token_urlsafe(32)
    token_hash = hash_token(token)

    if args.sql_only:
        _print_token(node_id, token)
        print()
        print("Jalankan di Supabase SQL Editor:")
        print(f"  update public.nodes set api_token_hash = '{token_hash}' where id = '{node_id}';")
        return

    asyncio.run(_write_hash(node_id, token_hash, rotate=args.cmd == "rotate-token"))
    _print_token(node_id, token)


if __name__ == "__main__":
    main()
