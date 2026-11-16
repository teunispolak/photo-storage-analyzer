#!/usr/bin/env python3
"""
Compare two CSV files as tables and print a summary of the differences.

Usage: compare_csv.py <label> <baseline.csv> <new.csv> <diff file> [--full]

Prints nothing and exits 0 when the files are equal. Otherwise prints:
  --- <label>: <summary>
  then per column the number of rows that differ in it (same row count),
  or the number of rows only in the baseline and only in the new file,
  then up to 5 example lines.
Writes the full unified diff to <diff file>; --full also prints it.
Exit: 0 equal, 1 different, 2 error. Standard library only.
"""

import csv
import difflib
import sys
from collections import Counter

EXAMPLES = 5


def read(path):
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f))
    return (rows[0], rows[1:]) if rows else ([], [])


def n(x):
    return f"{x:,}"


def main(argv):
    full = "--full" in argv
    args = [a for a in argv if a != "--full"]
    if len(args) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    label, old_path, new_path, diff_path = args
    try:
        old_head, old_rows = read(old_path)
        new_head, new_rows = read(new_path)
        old_text = open(old_path, encoding="utf-8").read().splitlines(keepends=True)
        new_text = open(new_path, encoding="utf-8").read().splitlines(keepends=True)
    except (OSError, UnicodeDecodeError, csv.Error) as e:
        print(f"--- {label}: cannot compare: {e}")
        return 2

    if old_head == new_head and old_rows == new_rows:
        return 0

    diff = list(difflib.unified_diff(old_text, new_text, "baseline/" + label, "new/" + label))
    with open(diff_path, "w", encoding="utf-8") as f:
        f.writelines(diff)

    lines = []
    if old_head != new_head:
        gone = [c for c in old_head if c not in new_head]
        added = [c for c in new_head if c not in old_head]
        parts = []
        if gone:
            parts.append("removed " + ", ".join(gone))
        if added:
            parts.append("added " + ", ".join(added))
        if not parts:
            parts.append("same columns, different order")
        lines.append(f"      columns: {'; '.join(parts)}")

    if len(old_rows) == len(new_rows):
        changed = [i for i, (a, b) in enumerate(zip(old_rows, new_rows)) if a != b]
        if changed and Counter(map(tuple, old_rows)) == Counter(map(tuple, new_rows)):
            summary = f"same {n(len(new_rows))} rows, in a different order"
        else:
            summary = f"{n(len(changed))} of {n(len(new_rows))} rows differ"
            common = [c for c in new_head if c in old_head]
            oi = {c: old_head.index(c) for c in common}
            ni = {c: new_head.index(c) for c in common}
            per_col = Counter()
            for i in changed:
                a, b = old_rows[i], new_rows[i]
                for c in common:
                    va = a[oi[c]] if oi[c] < len(a) else None
                    vb = b[ni[c]] if ni[c] < len(b) else None
                    if va != vb:
                        per_col[c] += 1
            width = max((len(c) for c in per_col), default=0)
            for c in common:  # in column order
                if per_col[c]:
                    k = per_col[c]
                    lines.append(f"      {c.ljust(width)}  {n(k).rjust(8)} {'row' if k == 1 else 'rows'}")
    else:
        only_old = Counter(map(tuple, old_rows)) - Counter(map(tuple, new_rows))
        only_new = Counter(map(tuple, new_rows)) - Counter(map(tuple, old_rows))
        summary = (f"{n(len(old_rows))} rows in the baseline, {n(len(new_rows))} in the new analysis: "
                   f"{n(sum(only_old.values()))} only in the baseline, {n(sum(only_new.values()))} only in the new")

    print(f"--- {label}: {summary}")
    for line in lines:
        print(line)
    examples = [d.rstrip("\n") for d in diff if d[:1] in "-+" and not d.startswith(("---", "+++"))]
    if full:
        sys.stdout.writelines(diff)
    elif examples:
        print(f"      examples (full diff: {diff_path}):")
        for d in examples[: 2 * EXAMPLES]:
            print("        " + (d if len(d) <= 160 else d[:157] + "..."))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
