#!/usr/bin/env python3
"""
Build sample data for tests: a small photo tree and a minimal Lightroom catalog.

Usage: python3 tests/make_fixture.py <work_dir>

Creates:
  <work_dir>/vol/Photos/...   photo tree (raw, xmp, jpeg with NFD name, dot file,
                              symlink, file with the hidden flag on macOS)
  <work_dir>/lr/Test.lrcat    SQLite file with AgLibraryRootFolder pointing at the tree
No real customer data is used.
"""

import os
import sqlite3
import subprocess
import sys
import unicodedata
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: make_fixture.py <work_dir>", file=sys.stderr)
        return 1
    # Absolute but not resolved: the catalog root must match --scan-root as
    # the test passes it, also where TMPDIR is a symlink (macOS)
    work = Path(os.path.abspath(sys.argv[1]))
    if work.exists() and any(work.iterdir()):
        print(f"work dir not empty: {work}", file=sys.stderr)
        return 1

    base = work / "vol" / "Photos"
    for d in ("2014/Trip", "2015", "2023"):
        (base / d).mkdir(parents=True)
    (work / "lr").mkdir()
    (work / "out").mkdir()

    # On disk (9 files)
    (base / "2014" / "Trip" / "IMG_0001.CR2").write_bytes(b"x" * 5000)   # raw, catalogued
    (base / "2014" / "Trip" / "IMG_0001.xmp").write_text("xmp")          # its sidecar
    (base / "2015" / "IMG_0100.NEF").write_bytes(b"n" * 4000)            # RAW+JPEG pair
    (base / "2015" / "IMG_0100.JPG").write_bytes(b"j" * 900)             # JPEG of the pair
    (base / "2023" / unicodedata.normalize("NFD", "Café.JPG")).write_bytes(b"y" * 1234)
    (base / ".DS_Store").write_bytes(b"z")
    (base / "root.txt").write_text("r")
    os.symlink("2014", base / "link2014")
    flagged = base / "2023" / "flagged.jpg"
    flagged.write_bytes(b"f" * 10)
    if sys.platform == "darwin":
        subprocess.run(["chflags", "hidden", str(flagged)], check=True)

    # Catalog: untyped columns, as Lightroom declares many of them
    con = sqlite3.connect(work / "lr" / "Test.lrcat")
    con.executescript("""
        CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath NOT NULL DEFAULT '', name);
        CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, pathFromRoot NOT NULL DEFAULT '', rootFolder INTEGER);
        CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, baseName NOT NULL DEFAULT '',
                                    extension NOT NULL DEFAULT '', folder INTEGER, sidecarExtensions);
        CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, masterImage INTEGER,
                                   captureTime, fileFormat, pick NOT NULL DEFAULT 0, rating);
    """)
    con.execute("INSERT INTO AgLibraryRootFolder VALUES (1, ?, 'Photos')", (str(base) + "/",))
    con.executemany("INSERT INTO AgLibraryFolder VALUES (?, ?, 1)",
                    [(10, "2014/Trip/"), (11, "2015/"), (12, "2016/"), (13, "2023/")])
    con.executemany("INSERT INTO AgLibraryFile VALUES (?, ?, ?, ?, ?)", [
        (100, "IMG_0001", "CR2", 10, "xmp"),                          # raw + xmp sidecar
        (101, "IMG_0100", "NEF", 11, "JPG"),                          # RAW+JPEG pair
        (102, "GONE", "DNG", 12, None),                               # missing from disk
        (103, unicodedata.normalize("NFD", "Café"), "jpg", 13, None),  # NFD name, case differs
    ])
    con.executemany("INSERT INTO Adobe_images VALUES (?, ?, ?, ?, ?, ?, ?)", [
        (1000, 100, None, "2014-07-01T10:00:00.25", "RAW", 1, 4),
        (1001, 100, 1000, "2014-07-01T10:00:00.25", "RAW", 0, None),  # virtual copy
        (1002, 101, None, "2015-03-02T08:00:00", "RAW", 0, 3),
        (1003, 102, None, "2016-01-01T00:00:00", "RAW", -1, None),
        (1004, 103, None, None, "JPG", 0, None),                      # no capture time
    ])
    con.commit()
    con.close()
    print(work)
    return 0


if __name__ == "__main__":
    sys.exit(main())
