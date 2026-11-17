#!/usr/bin/env python3
"""
Verify a received collection against its manifest.

Usage: python3 verify.py <run_dir>
Exit 0 if complete and checksums match, 1 otherwise.
"""

import hashlib
import json
import sys
from pathlib import Path

CHUNK = 8 * 1024 * 1024


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify.py <run_dir>", file=sys.stderr)
        return 1
    run_dir = Path(sys.argv[1])
    mpath = run_dir / "manifest.json"
    if not mpath.is_file():
        print(f"FAIL no manifest.json in {run_dir}")
        return 1
    m = json.loads(mpath.read_text(encoding="utf-8"))
    if m.get("status") != "complete":
        print(f"FAIL manifest status is {m.get('status')!r}")
        return 1

    checks = [("files", m["files"])]
    if m.get("catalog"):
        checks.append(("catalog", m["catalog"]))

    ok = True
    for label, entry in checks:
        p = run_dir / entry["file"]
        if not p.is_file():
            print(f"FAIL {label}: {p.name} missing")
            ok = False
            continue
        actual = sha256_file(p)
        if actual != entry["sha256"]:
            print(f"FAIL {label}: {p.name} checksum mismatch")
            ok = False
        else:
            print(f"ok   {label}: {p.name}")

    if ok:
        f = m["files"]
        print(f"ok   collection {m['run_id']}: {f['rows']} files, "
              f"{f['size_bytes'] / 1e12:.2f} TB, {f['errors']} scan errors")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
