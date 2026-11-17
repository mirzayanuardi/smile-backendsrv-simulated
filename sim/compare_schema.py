#!/usr/bin/env python3
"""Bandingkan skema DB simulasi (container `db`) dengan supabase_database.md (ekspor produksi).

Yang dibandingkan: tabel, kolom (tipe udt + nullable), enum (nilai berurutan),
dan RLS policy (nama, command, roles, permissive). Index, fungsi, trigger, view,
dan GRANT TIDAK ada di supabase_database.md, jadi tidak bisa dibandingkan di sini.

Jalankan setelah `sim/sim.sh up`:
  python3 sim/compare_schema.py
Hanya stdlib; membaca DB lewat `docker compose exec db psql`.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MD = ROOT / "supabase_database.md"


def psql(sql: str) -> list[list[str]]:
    out = subprocess.run(
        ["docker", "compose", "--project-directory", str(ROOT), "-f", str(ROOT / "docker-compose.yml"), "-f", str(ROOT / "docker-compose.sim.yml"),
         "exec", "-T", "db", "psql", "-U", "postgres", "-d", "smile", "-At", "-F", "\x1f", "-c", sql],
        check=True, capture_output=True, text=True,
    ).stdout
    return [line.split("\x1f") for line in out.splitlines() if line]


def parse_md(text: str):
    tables: dict[str, dict[str, tuple[str, bool]]] = {}
    enums: dict[str, list[str]] = {}
    policies: set[tuple[str, str, str, str, str]] = set()
    section = cur = None
    for line in text.splitlines():
        if m := re.match(r"^## Table `([^`]+)`", line):
            section, cur = "table", m.group(1)
            tables[cur] = {}
        elif line.startswith("## Custom Types"):
            section, cur = "enum", None
        elif line.startswith("## RLS Policies"):
            section, cur = "rls", None
        elif section == "enum" and (m := re.match(r"^### `([^`]+)`", line)):
            cur = m.group(1)
        elif section == "enum" and cur and line.startswith("`"):
            enums[cur] = re.findall(r"`([^`]+)`", line)
        elif section == "rls" and (m := re.match(r"^### `([^`]+)`", line)):
            cur = m.group(1)
        elif line.startswith("| `") and section == "table":
            cells = [c.strip() for c in line.strip("|").split("|")]
            tables[cur][cells[0].strip("`")] = (cells[1].strip("`"), "Nullable" in cells[2])
        elif line.startswith("| `") and section == "rls":
            cells = [c.strip() for c in line.strip("|").split("|")]
            policies.add((cur, cells[0].strip("`"), cells[1], cells[2], cells[3]))
    return tables, enums, policies


def main() -> int:
    md_tables, md_enums, md_policies = parse_md(MD.read_text())

    db_tables: dict[str, dict[str, tuple[str, bool]]] = {}
    for t, c, udt, nullable in psql(
        "select c.table_name, c.column_name, c.udt_name, c.is_nullable from information_schema.columns c "
        "join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name "
        "where c.table_schema = 'public' and t.table_type = 'BASE TABLE' order by c.table_name, c.ordinal_position"
    ):
        db_tables.setdefault(t, {})[c] = (udt, nullable == "YES")
    db_enums: dict[str, list[str]] = {}
    for name, label in psql(
        "select t.typname, e.enumlabel from pg_type t join pg_enum e on e.enumtypid = t.oid "
        "join pg_namespace n on n.oid = t.typnamespace where n.nspname = 'public' order by t.typname, e.enumsortorder"
    ):
        db_enums.setdefault(name, []).append(label)
    db_policies = {
        (t, p, cmd, roles.strip("{}").replace(",", ", "), perm)
        for t, p, cmd, roles, perm in psql(
            "select tablename, policyname, cmd, roles::text, permissive from pg_policies where schemaname = 'public'"
        )
    }

    diffs = 0

    def report(title: str, items: list[str]) -> None:
        nonlocal diffs
        if items:
            diffs += len(items)
            print(f"\n## {title} ({len(items)})")
            for i in items:
                print(f"  - {i}")

    report("Tabel ada di PRODUKSI, tidak ada di simulasi", sorted(set(md_tables) - set(db_tables)))
    report("Tabel ada di simulasi, tidak ada di PRODUKSI", sorted(set(db_tables) - set(md_tables)))
    col_diffs = []
    for t in sorted(set(md_tables) & set(db_tables)):
        md_cols, db_cols = md_tables[t], db_tables[t]
        for c in md_cols.keys() - db_cols.keys():
            col_diffs.append(f"{t}.{c}: hanya di PRODUKSI ({md_cols[c][0]})")
        for c in db_cols.keys() - md_cols.keys():
            col_diffs.append(f"{t}.{c}: hanya di simulasi ({db_cols[c][0]})")
        for c in md_cols.keys() & db_cols.keys():
            (mt, mn), (dt, dn) = md_cols[c], db_cols[c]
            if mt != dt:
                col_diffs.append(f"{t}.{c}: tipe produksi {mt} != simulasi {dt}")
            if mn != dn:
                col_diffs.append(f"{t}.{c}: nullable produksi {mn} != simulasi {dn}")
    report("Kolom berbeda", sorted(col_diffs))
    enum_diffs = []
    for e in sorted(set(md_enums) | set(db_enums)):
        if md_enums.get(e) != db_enums.get(e):
            enum_diffs.append(f"{e}: produksi {md_enums.get(e)} | simulasi {db_enums.get(e)}")
    report("Enum berbeda", enum_diffs)
    # Hanya tabel yang ada di ekspor produksi: ekspor tidak memuat tabel tanpa policy.
    md_pol_tables = {p[0] for p in md_policies}
    sim_pols = {p for p in db_policies if p[0] in md_tables}
    report("Policy hanya di PRODUKSI", sorted(" | ".join(p) for p in md_policies - sim_pols))
    report("Policy hanya di simulasi", sorted(" | ".join(p) for p in sim_pols - md_policies))
    print(f"\nTabel produksi: {len(md_tables)}, simulasi: {len(db_tables)}; "
          f"tabel ber-policy di ekspor: {len(md_pol_tables)}. Total perbedaan: {diffs}")
    print("Catatan: index, fungsi, trigger, view, dan GRANT tidak terbandingkan (tidak ada di ekspor).")
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
