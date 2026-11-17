#!/usr/bin/env python3
"""
Check reports/reconciliation.csv of an analysis output folder:
- every line's files (and bytes, where present) equal the sum of its children
- the lines match join_check.csv, and the catalog side adds up
Usage: check_reconciliation.py <analysis output folder>. Exit 0 when all hold.
"""

import csv
import sys
from pathlib import Path


def main() -> int:
    out = Path(sys.argv[1])
    rows = list(csv.DictReader(open(out / "reports" / "reconciliation.csv")))
    jc = {r["metric"]: int(r["value"]) for r in csv.DictReader(open(out / "join_check.csv"))}
    files = {r["category"]: int(r["files"]) for r in rows}
    bytes_ = {r["category"]: int(r["bytes"]) for r in rows if r["bytes"]}
    problems = []

    # children add up to their parent
    tree = [r["category"] for r in rows if r["level"]]
    for parent in tree:
        kids = [c for c in tree if c.rsplit("/", 1)[0] == parent and c != parent]
        if parent == "all files":
            kids = [c for c in tree if "/" not in c and c != "all files"]
        if kids:
            if sum(files[k] for k in kids) != files[parent]:
                problems.append(f"files of {parent} != sum of {kids}")
            if parent in bytes_ and all(k in bytes_ for k in kids) and sum(bytes_[k] for k in kids) != bytes_[parent]:
                problems.append(f"bytes of {parent} != sum of {kids}")

    expect = {
        "all files": jc["matched"] + jc["disk_only"] + jc["catalog_only"],
        "filesystem": jc["disk_files"],
        "filesystem/filesystem and catalog": jc["matched"],
        "filesystem/filesystem and catalog/photo": jc["matched_photo"],
        "filesystem/filesystem and catalog/attached": jc["matched_attached"],
        "filesystem/filesystem only": jc["disk_only"],
        "catalog only": jc["catalog_only"],
        "catalog entries outside the scan root (not analysed)": jc["catalog_outside_scan_root"],
        "virtual copies (not files)": jc["virtual_copies_excluded"],
    }
    for cat, val in expect.items():
        if files.get(cat) != val:
            problems.append(f"{cat}: {files.get(cat)} != join_check {val}")
    # the catalog side: every catalog entry is matched, catalog only in scope, or outside the scan root
    entries = jc["catalog_photos"] + jc["catalog_attached"] - jc["catalog_duplicate_keys"]
    if entries != jc["matched"] + jc["catalog_only"] + jc["catalog_outside_scan_root"]:
        problems.append("catalog entries != matched + catalog only + outside the scan root")
    if bytes_.get("filesystem") != jc["disk_bytes"]:
        problems.append("filesystem bytes != disk_bytes")

    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
