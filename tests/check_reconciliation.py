#!/usr/bin/env python3
"""
Check reports/reconciliation.csv of an analysis output folder:
- every line's files (and bytes, where present) equal the sum of its children
- the lines match join_check.csv
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
        "on disk": jc["disk_files"],
        "on disk/matched": jc["matched"],
        "on disk/matched/photo": jc["matched_photo"],
        "on disk/matched/attached": jc["matched_attached"],
        "on disk/disk only": jc["disk_only"],
        "catalog only": jc["catalog_only"],
        "virtual copies (not files)": jc["virtual_copies_excluded"],
    }
    for cat, val in expect.items():
        if files.get(cat) != val:
            problems.append(f"{cat}: {files.get(cat)} != join_check {val}")
    cat_photo = files["catalog only/outside scan root/photo"] + files["catalog only/in scan root/photo"]
    cat_att = files["catalog only/outside scan root/attached"] + files["catalog only/in scan root/attached"]
    if cat_photo != jc["catalog_photos"] - jc["matched_photo"]:
        problems.append("catalog-only photos != catalog_photos - matched_photo")
    if cat_att != jc["catalog_attached"] - jc["matched_attached"]:
        problems.append("catalog-only attached != catalog_attached - matched_attached")
    if bytes_.get("on disk") != jc["disk_bytes"]:
        problems.append("on disk bytes != disk_bytes")

    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
