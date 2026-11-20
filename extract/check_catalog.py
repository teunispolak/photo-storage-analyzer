#!/usr/bin/env python3
"""
Check that a Lightroom Classic catalog has the structure the analysis needs.

Usage:
  python3 extract/check_catalog.py <catalog.lrcat> [--show-roots]

Opens the catalog read-only and reports:
  - required tables and columns (as used by analyse/10_load.sql)
  - row counts and value shapes (counts only, no catalog content)
  - references that do not resolve (files without folder, etc.)
With --show-roots it also prints the root folder paths, which tell you what to
pass as --scan-root.

Run it on a copy, or with Lightroom closed.
Exit 0 if the required structure is present (warnings may be listed), 1 if not.
Requires Python 3.9+, standard library only.
"""

import argparse
import sqlite3
import sys
from pathlib import Path

# settings.py sits next to this script; python -I leaves the script's folder off sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import settings as settings_file  # noqa: E402

# Must match the columns analyse/10_load.sql reads (checked by the tests)
REQUIRED = {
    "AgLibraryRootFolder": ["id_local", "absolutePath"],
    "AgLibraryFolder": ["id_local", "rootFolder", "pathFromRoot"],
    "AgLibraryFile": ["id_local", "folder", "baseName", "extension", "sidecarExtensions", "modTime"],
    "Adobe_images": ["id_local", "rootFile", "masterImage", "captureTime", "fileFormat", "pick", "rating",
                     "touchTime"],
}

TIME_GLOB = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*"


def scalar(con, sql):
    return con.execute(sql).fetchone()[0]


def pct(n, total):
    return f"{100 * n / total:.1f}%" if total else "-"


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Check a Lightroom catalog's structure.")
    p.add_argument("catalog", type=Path, nargs="?",
                   help="path to the .lrcat file; replaces CATALOG of the settings file")
    p.add_argument("--show-roots", action="store_true", help="print root folder paths")
    p.add_argument("--settings", type=Path,
                   help="settings file with CATALOG (./psa passes it when it exists)")
    args = p.parse_args(argv)

    if args.settings is not None:
        try:
            s = settings_file.load(args.settings)
        except (settings_file.SettingsError, UnicodeDecodeError) as e:
            print(f"FAIL {e}")
            return 1
        print(f"settings file: {s.path}")
        if args.catalog is None and s.get("CATALOG"):
            args.catalog = Path(s.get("CATALOG"))
            print(f"  CATALOG from settings file: {args.catalog}")
        elif s.get("CATALOG"):
            print("  CATALOG from the command line; the settings file value is not used")
    else:
        print("settings file: none")
    if args.catalog is None:
        print("FAIL no catalog: give the .lrcat path or CATALOG in the settings file")
        return 1
    cat = args.catalog.expanduser()

    if not cat.is_file():
        print(f"FAIL catalog not found: {cat}")
        return 1
    for suffix in (".lock", "-wal", "-journal", "-shm"):
        side = cat.with_name(cat.name + suffix)
        if side.exists():
            print(f"WARN {side.name} present: Lightroom may have the catalog open; "
                  "results can be inconsistent. Use a copy or close Lightroom.")

    con = sqlite3.connect(f"file:{cat}?mode=ro&immutable=1", uri=True)
    warnings = 0
    try:
        # 1. Structure
        print("Structure")
        missing = 0
        for table, cols in REQUIRED.items():
            have = {r[1] for r in con.execute(f"PRAGMA table_info('{table}')")}
            if not have:
                print(f"  FAIL table {table} missing")
                missing += 1
                continue
            absent = [c for c in cols if c not in have]
            if absent:
                print(f"  FAIL {table}: missing columns {', '.join(absent)}")
                missing += 1
            else:
                print(f"  ok   {table}")
        if missing:
            print("\nThe catalog does not have the expected structure; the join would fail.")
            return 1

        # 2. Counts and shapes
        roots = scalar(con, "SELECT count(*) FROM AgLibraryRootFolder")
        folders = scalar(con, "SELECT count(*) FROM AgLibraryFolder")
        files = scalar(con, "SELECT count(*) FROM AgLibraryFile")
        images = scalar(con, "SELECT count(*) FROM Adobe_images")
        virtual = scalar(con, "SELECT count(*) FROM Adobe_images WHERE masterImage IS NOT NULL")
        print("\nCounts")
        print(f"  root folders   {roots}")
        print(f"  folders        {folders}")
        print(f"  files          {files}")
        print(f"  images         {images}  (virtual copies: {virtual})")

        print("\nShapes")

        def shape(label, n, total, expect_all=True):
            nonlocal warnings
            flag = "ok  " if (n == total if expect_all else True) else "WARN"
            if flag == "WARN":
                warnings += 1
            print(f"  {flag} {label}: {n} of {total} ({pct(n, total)})")

        shape("root paths ending in /",
              scalar(con, "SELECT count(*) FROM AgLibraryRootFolder WHERE absolutePath LIKE '%/'"), roots)
        shape("folder paths empty or ending in /",
              scalar(con, "SELECT count(*) FROM AgLibraryFolder "
                          "WHERE coalesce(pathFromRoot, '') = '' OR pathFromRoot LIKE '%/'"), folders)
        photos = images - virtual
        with_time = scalar(con, f"SELECT count(*) FROM Adobe_images WHERE masterImage IS NULL "
                                f"AND captureTime GLOB '{TIME_GLOB}'")
        print(f"  info capture time in expected format: {with_time} of {photos} photos "
              f"({pct(with_time, photos)}); the rest falls back to the file date")
        no_ext = scalar(con, "SELECT count(*) FROM AgLibraryFile WHERE coalesce(extension, '') = ''")
        print(f"  info files without extension: {no_ext}")

        print("  info attached file extensions, Lightroom sidecarExtensions (value: files)")
        for value, n in con.execute(
                "SELECT sidecarExtensions, count(*) FROM AgLibraryFile "
                "WHERE coalesce(sidecarExtensions, '') <> '' GROUP BY 1 ORDER BY 2 DESC LIMIT 10"):
            print(f"         {value}: {n}")
        print("  info file formats (value: images)")
        for value, n in con.execute(
                "SELECT fileFormat, count(*) FROM Adobe_images GROUP BY 1 ORDER BY 2 DESC LIMIT 10"):
            print(f"         {value}: {n}")

        # 3. References
        print("\nReferences")
        refs = [
            ("folders without root folder",
             "SELECT count(*) FROM AgLibraryFolder f LEFT JOIN AgLibraryRootFolder r "
             "ON r.id_local = f.rootFolder WHERE r.id_local IS NULL"),
            ("files without folder",
             "SELECT count(*) FROM AgLibraryFile f LEFT JOIN AgLibraryFolder d "
             "ON d.id_local = f.folder WHERE d.id_local IS NULL"),
            ("images without file",
             "SELECT count(*) FROM Adobe_images i LEFT JOIN AgLibraryFile f "
             "ON f.id_local = i.rootFile WHERE f.id_local IS NULL"),
            ("files without a photo (non-virtual image)",
             "SELECT count(*) FROM AgLibraryFile f WHERE NOT EXISTS (SELECT 1 FROM Adobe_images i "
             "WHERE i.rootFile = f.id_local AND i.masterImage IS NULL)"),
        ]
        for label, sql in refs:
            n = scalar(con, sql)
            flag = "ok  " if n == 0 else "WARN"
            warnings += n > 0
            print(f"  {flag} {label}: {n}")

        if args.show_roots:
            print("\nRoot folders (pass the one holding the photos as --scan-root)")
            for (path,) in con.execute("SELECT absolutePath FROM AgLibraryRootFolder ORDER BY 1"):
                print(f"  {path}")
    finally:
        con.close()

    print(f"\nStructure ok, {warnings} warning(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
