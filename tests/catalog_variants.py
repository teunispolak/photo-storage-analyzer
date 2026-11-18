#!/usr/bin/env python3
"""
Build catalog variants from the test catalog, to check that the columns in
extract/check_catalog.py REQUIRED are exactly what analyse/10_load.sql needs.

Usage: python3 tests/catalog_variants.py <src.lrcat> <check_catalog.py> <out_dir>

Writes to <out_dir>:
  minimal.lrcat                 only the required tables and columns
  without-<table>.<col>.lrcat   minimal, minus one required column
Prints the names of the without-* files, one per line.
"""

import importlib.util
import sqlite3
import sys
from pathlib import Path


def build(src: Path, dest: Path, required: dict, drop=None) -> None:
    out = sqlite3.connect(f"file:{dest}", uri=True)
    # read the source without creating -wal/-shm next to it (Apple's SQLite
    # keeps them after closing, and the extract then refuses the catalog)
    out.execute("ATTACH ? AS src", (f"file:{src}?mode=ro&immutable=1",))
    for table, cols in required.items():
        keep = [c for c in cols if (table, c) != drop]
        # untyped columns, as Lightroom declares many of them
        out.execute(f"CREATE TABLE {table} ({', '.join(keep)})")
        out.execute(f"INSERT INTO {table} SELECT {', '.join(keep)} FROM src.{table}")
    out.commit()
    out.execute("DETACH src")
    out.close()


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 1
    src, checker, out_dir = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    spec = importlib.util.spec_from_file_location("check_catalog", checker)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    required = mod.REQUIRED

    out_dir.mkdir(parents=True, exist_ok=False)
    build(src, out_dir / "minimal.lrcat", required)
    for table, cols in required.items():
        for col in cols:
            name = f"without-{table}.{col}.lrcat"
            build(src, out_dir / name, required, drop=(table, col))
            print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
