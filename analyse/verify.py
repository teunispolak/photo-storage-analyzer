#!/usr/bin/env python3
"""
Verify a received extract against its manifest.

Usage: python3 verify.py <extract_dir>
Exit 0 if complete, of the current schema, and checksums match; 1 otherwise.
"""

import csv
import hashlib
import json
import sys
from pathlib import Path
from typing import List, Optional

CHUNK = 8 * 1024 * 1024
# Manifest schema the analysis reads; extract/extract.py writes the same number
SCHEMA = 2


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def csv_problem(path: Path, columns: List[str], rows: int) -> Optional[str]:
    """None if path reads back as the header plus rows rows of len(columns)
    fields; otherwise what is wrong. A field with an unquoted line break
    splits its row, which this catches."""
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        if next(reader, None) != columns:
            return "header differs from the expected columns"
        n = 0
        for row in reader:
            if len(row) != len(columns):
                return f"line {reader.line_num}: {len(row)} fields, expected {len(columns)}"
            n += 1
    if n != rows:
        return f"{n} rows, expected {rows}"
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify.py <extract_dir>", file=sys.stderr)
        return 1
    extract_dir = Path(sys.argv[1])
    mpath = extract_dir / "manifest.json"
    if not mpath.is_file():
        print(f"FAIL no manifest.json in {extract_dir}")
        return 1
    m = json.loads(mpath.read_text(encoding="utf-8"))
    if m.get("status") != "complete":
        print(f"FAIL manifest status is {m.get('status')!r}")
        return 1
    if m.get("schema") != SCHEMA:
        print(f"FAIL extract has manifest schema {m.get('schema')!r}, the analysis reads {SCHEMA}: "
              "made by another version; extract again with the current version")
        return 1

    checks = [("files", m["files"])]
    if m.get("catalog"):
        checks.append(("catalog", m["catalog"]))

    ok = True
    for label, entry in checks:
        p = extract_dir / entry["file"]
        if not p.is_file():
            print(f"FAIL {label}: {p.name} missing")
            ok = False
            continue
        actual = sha256_file(p)
        if actual != entry["sha256"]:
            print(f"FAIL {label}: {p.name} checksum mismatch")
            ok = False
            continue
        if label == "files":
            problem = csv_problem(p, entry["columns"], entry["rows"])
            if problem:
                print(f"FAIL {label}: {p.name} does not read back ({problem}); extract again with the current version")
                ok = False
                continue
        print(f"ok   {label}: {p.name}")

    if ok:
        f = m["files"]
        print(f"ok   extract {m['extract_id']}: {f['rows']} files, "
              f"{f['size_bytes'] / 1e12:.2f} TB, {f['errors']} scan errors")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
