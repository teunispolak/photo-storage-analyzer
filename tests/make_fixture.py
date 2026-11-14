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
    work = Path(sys.argv[1]).resolve()
    if work.exists() and any(work.iterdir()):
        print(f"work dir not empty: {work}", file=sys.stderr)
        return 1

    base = work / "vol" / "Photos"
    (base / "2014" / "Trip").mkdir(parents=True)
    (base / "2023").mkdir(parents=True)
    (work / "lr").mkdir()
    (work / "out").mkdir()

    (base / "2014" / "Trip" / "IMG_0001.CR2").write_bytes(b"x" * 5000)
    (base / "2014" / "Trip" / "IMG_0001.xmp").write_text("xmp")
    (base / "2023" / unicodedata.normalize("NFD", "Café.JPG")).write_bytes(b"y" * 1234)
    (base / ".DS_Store").write_bytes(b"z")
    (base / "root.txt").write_text("r")
    os.symlink("2014", base / "link2014")
    flagged = base / "2023" / "flagged.jpg"
    flagged.write_bytes(b"f" * 10)
    if sys.platform == "darwin":
        subprocess.run(["chflags", "hidden", str(flagged)], check=True)

    con = sqlite3.connect(work / "lr" / "Test.lrcat")
    con.execute("CREATE TABLE AgLibraryRootFolder (id_local INTEGER, absolutePath TEXT)")
    con.execute("INSERT INTO AgLibraryRootFolder VALUES (1, ?)", (str(base) + "/",))
    con.commit()
    con.close()
    print(work)
    return 0


if __name__ == "__main__":
    sys.exit(main())
