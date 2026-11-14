#!/usr/bin/env python3
"""
Photo storage assessment - collector.

Runs on the client's Mac. Collects facts only; all interpretation happens
on the analysis machine.

Steps:
  1. Preflight checks (stop on any failure, nothing written outside out dir)
  2. Copy the Lightroom catalog and verify the copy
  3. Scan the photo tree (metadata only, file contents are not read)
  4. Write manifest.json last; its presence marks a complete run

Output: <out>/<run_id>/
  catalog.lrcat    copy of the Lightroom catalog
  files.csv        one row per file under the scan root
  manifest.json    run metadata, counts, checksums
  collector.log    log of this run

Requires Python 3.9+, standard library only.
Nothing is deleted or modified outside the run folder.
"""

import argparse
import csv
import datetime as dt
import hashlib
import json
import logging
import os
import platform
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import time
import unicodedata
from pathlib import Path
from typing import List, Optional

COLLECTOR_VERSION = "0.1.0"
MANIFEST_SCHEMA = 1
CHUNK = 8 * 1024 * 1024
PROGRESS_EVERY = 25_000

# macOS st_flags bits
UF_HIDDEN = 0x00008000
SF_DATALESS = 0x40000000  # file content not present locally (cloud placeholder)

LR_PROCESS_PATTERN = "/Adobe Lightroom Classic.app/Contents/MacOS/"
LR_SIDE_FILES = ("-wal", "-journal", "-shm")

CSV_COLUMNS = [
    "path",         # absolute, NFC
    "rel_path",     # relative to scan root, NFC
    "top_folder",   # first level under scan root ('' for files in root)
    "parent",       # containing folder, relative to scan root
    "name",
    "ext",          # lowercase, without dot
    "size_bytes",   # logical size
    "alloc_bytes",  # space allocated on disk (st_blocks * 512)
    "mtime",        # ISO 8601 UTC
    "btime",        # ISO 8601 UTC, creation time (empty if unavailable)
    "hidden",       # 1 if name starts with '.' or hidden flag set
    "dataless",     # 1 if content is not stored locally
    "symlink",      # 1 if the entry is a symbolic link (not followed)
]

log = logging.getLogger("collector")


class PreflightError(Exception):
    pass


# ---------------------------------------------------------------- helpers

def nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s)


def utc_iso(ts: Optional[float]) -> str:
    if ts is None:
        return ""
    return dt.datetime.fromtimestamp(ts, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso() -> str:
    return utc_iso(time.time())


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def is_within(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def git_commit(script_dir: Path) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(script_dir), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return "unknown"


def dropbox_roots() -> List[Path]:
    """Dropbox folder locations: from ~/.dropbox/info.json and default paths."""
    roots = []
    info = Path.home() / ".dropbox" / "info.json"
    if info.is_file():
        try:
            data = json.loads(info.read_text())
            for account in data.values():
                p = account.get("path") if isinstance(account, dict) else None
                if p:
                    roots.append(Path(p))
        except (OSError, ValueError) as e:
            log.warning("Could not read %s: %s", info, e)
    for p in [Path.home() / "Dropbox", *(Path.home() / "Library" / "CloudStorage").glob("Dropbox*")]:
        if p.exists() and p not in roots:
            roots.append(p)
    return roots


def lightroom_running() -> bool:
    try:
        out = subprocess.run(["pgrep", "-f", LR_PROCESS_PATTERN],
                             capture_output=True, text=True, timeout=10)
        return out.returncode == 0
    except (OSError, subprocess.SubprocessError):
        log.warning("pgrep not available; relying on lock file check only")
        return False


# ---------------------------------------------------------------- preflight

def preflight(args, run_dir: Path, extra_roots: List[Path]) -> dict:
    problems = []
    facts = {}

    if sys.version_info < (3, 9):
        problems.append(f"Python 3.9+ required, found {platform.python_version()}")

    scan_root = args.scan_root
    if not scan_root.is_dir():
        problems.append(f"Scan root is not a folder: {scan_root}")
    elif not os.access(scan_root, os.R_OK | os.X_OK):
        problems.append(f"Scan root is not readable: {scan_root}")

    out_base = args.out
    if scan_root.is_dir() and is_within(out_base, scan_root):
        problems.append(f"Output folder {out_base} is inside the scan root")

    dbx = dropbox_roots() + extra_roots
    facts["dropbox_roots"] = [str(p) for p in dbx]
    for root in dbx:
        if is_within(out_base, root):
            problems.append(f"Output folder {out_base} is inside a Dropbox folder: {root}")
    facts["scan_root_in_dropbox"] = any(is_within(scan_root, r) for r in dbx) if scan_root.is_dir() else None

    needed = 200 * 1024 * 1024  # margin for files.csv and log
    if not args.skip_catalog:
        cat = args.catalog
        if cat is None:
            problems.append("--catalog is required (or use --skip-catalog)")
        elif not cat.is_file():
            problems.append(f"Catalog not found: {cat}")
        elif cat.suffix.lower() != ".lrcat":
            problems.append(f"Catalog does not end in .lrcat: {cat}")
        else:
            facts["catalog_size"] = cat.stat().st_size
            needed += int(facts["catalog_size"] * 1.1)
            lock = cat.with_name(cat.name + ".lock")
            if lock.exists():
                problems.append(f"Lightroom lock file present ({lock.name}): close Lightroom first")
            for suffix in LR_SIDE_FILES:
                side = cat.with_name(cat.name + suffix)
                if side.exists():
                    problems.append(f"{side.name} present: Lightroom did not close cleanly; "
                                    "open and close Lightroom, then retry")
            if lightroom_running():
                problems.append("Lightroom Classic is running: close it first")

    # Measure free space on the nearest existing folder; create nothing yet
    probe = out_base
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    free = shutil.disk_usage(probe).free
    facts["out_free_bytes"] = free
    if free < needed:
        problems.append(f"Not enough free space at {out_base}: "
                        f"{free / 1e9:.1f} GB free, {needed / 1e9:.1f} GB needed")

    if run_dir.exists():
        problems.append(f"Run folder already exists: {run_dir}")

    if problems:
        raise PreflightError("\n  - ".join(["Preflight failed:"] + problems))
    return facts


# ---------------------------------------------------------------- catalog

def copy_catalog(src: Path, run_dir: Path) -> dict:
    dest = run_dir / "catalog.lrcat"
    part = run_dir / "catalog.lrcat.part"
    log.info("Copying catalog %s (%.2f GB)", src, src.stat().st_size / 1e9)
    t0 = time.time()

    h_src = hashlib.sha256()
    with open(src, "rb") as fin, open(part, "wb") as fout:
        for block in iter(lambda: fin.read(CHUNK), b""):
            h_src.update(block)
            fout.write(block)
        fout.flush()
        os.fsync(fout.fileno())
    src_sha = h_src.hexdigest()

    copy_sha = sha256_file(part)
    if copy_sha != src_sha:
        raise RuntimeError(f"Catalog copy checksum mismatch: source {src_sha}, copy {copy_sha}")
    os.replace(part, dest)
    log.info("Catalog copied and checksum verified in %.0f s", time.time() - t0)

    # integrity check and root folders, read-only on the copy
    uri = f"file:{dest}?mode=ro&immutable=1"
    con = sqlite3.connect(uri, uri=True)
    try:
        t1 = time.time()
        result = [r[0] for r in con.execute("PRAGMA integrity_check")]
        log.info("Integrity check: %s (%.0f s)", ", ".join(result[:3]), time.time() - t1)
        if result != ["ok"]:
            raise RuntimeError(f"Catalog integrity check failed: {result[:5]}")
        try:
            roots = [r[0] for r in con.execute("SELECT absolutePath FROM AgLibraryRootFolder")]
        except sqlite3.Error as e:
            log.warning("Could not read root folders from catalog: %s", e)
            roots = []
    finally:
        con.close()

    return {
        "source_path": str(src),
        "file": dest.name,
        "size_bytes": dest.stat().st_size,
        "sha256": src_sha,
        "integrity_check": "ok",
        "root_folders": roots,
    }


# ---------------------------------------------------------------- scan

def scan(scan_root: Path, run_dir: Path) -> dict:
    dest = run_dir / "files.csv"
    part = run_dir / "files.csv.part"
    root = Path(os.path.abspath(scan_root))
    root_str = str(root)
    log.info("Scanning %s", root)
    t0 = time.time()

    files = dirs = errors = 0
    total_size = total_alloc = dataless_count = 0
    stack = [root_str]

    with open(part, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(CSV_COLUMNS)
        while stack:
            current = stack.pop()
            try:
                it = os.scandir(current)
            except OSError as e:
                errors += 1
                log.error("Cannot read folder %s: %s", current, e)
                continue
            with it:
                for entry in it:
                    try:
                        is_link = entry.is_symlink()
                        if not is_link and entry.is_dir(follow_symlinks=False):
                            dirs += 1
                            stack.append(entry.path)
                            continue
                        st = entry.stat(follow_symlinks=False)
                    except OSError as e:
                        errors += 1
                        log.error("Cannot stat %s: %s", entry.path, e)
                        continue
                    if not (is_link or stat.S_ISREG(st.st_mode)):
                        continue  # sockets, devices, fifos

                    path = nfc(entry.path)
                    rel = nfc(os.path.relpath(entry.path, root_str))
                    parts = rel.split(os.sep)
                    name = nfc(entry.name)
                    ext = os.path.splitext(name)[1][1:].lower()
                    flags = getattr(st, "st_flags", 0)
                    hidden = name.startswith(".") or bool(flags & UF_HIDDEN)
                    dataless = bool(flags & SF_DATALESS)
                    alloc = getattr(st, "st_blocks", 0) * 512

                    w.writerow([
                        path, rel,
                        parts[0] if len(parts) > 1 else "",
                        os.sep.join(parts[:-1]),
                        name, ext,
                        st.st_size, alloc,
                        utc_iso(st.st_mtime),
                        utc_iso(getattr(st, "st_birthtime", None)),
                        int(hidden), int(dataless), int(is_link),
                    ])
                    files += 1
                    total_size += st.st_size
                    total_alloc += alloc
                    dataless_count += dataless
                    if files % PROGRESS_EVERY == 0:
                        log.info("  %d files, %.2f TB, %.0f s",
                                 files, total_size / 1e12, time.time() - t0)
        f.flush()
        os.fsync(f.fileno())

    os.replace(part, dest)
    elapsed = time.time() - t0
    log.info("Scan done: %d files, %d folders, %.2f TB, %d errors, %.0f s",
             files, dirs, total_size / 1e12, errors, elapsed)
    return {
        "file": dest.name,
        "rows": files,
        "folders": dirs,
        "size_bytes": total_size,
        "alloc_bytes": total_alloc,
        "dataless_files": dataless_count,
        "errors": errors,
        "seconds": round(elapsed),
        "sha256": sha256_file(dest),
        "columns": CSV_COLUMNS,
    }


# ---------------------------------------------------------------- main

def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Collect file and catalog data for a photo storage assessment.")
    p.add_argument("--scan-root", required=True, type=Path,
                   help="root of the photo folder tree (e.g. /Volumes/Photos/Photos)")
    p.add_argument("--catalog", type=Path, help="path to the .lrcat file")
    p.add_argument("--out", type=Path, default=Path.home() / "photo-analysis" / "out",
                   help="base output folder (default: ~/photo-analysis/out)")
    p.add_argument("--dropbox-root", type=Path, action="append", default=[],
                   help="extra Dropbox folder to treat as off-limits for output (repeatable)")
    p.add_argument("--skip-catalog", action="store_true",
                   help="scan only, no catalog copy")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    args.scan_root = args.scan_root.expanduser()
    args.out = args.out.expanduser()
    if args.catalog:
        args.catalog = args.catalog.expanduser()

    host = socket.gethostname().split(".")[0]
    run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + host
    run_dir = args.out / run_id

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%H:%M:%S"))
    log.addHandler(console)
    log.setLevel(logging.INFO)

    try:
        facts = preflight(args, run_dir, args.dropbox_root)
    except PreflightError as e:
        log.error("%s", e)
        return 1

    run_dir.mkdir(parents=True)  # first write; only after preflight passed
    fh = logging.FileHandler(run_dir / "collector.log", encoding="utf-8")
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(fh)

    script = Path(__file__).resolve()
    started = now_iso()
    log.info("Collector %s, run %s", COLLECTOR_VERSION, run_id)
    log.info("Preflight passed")

    try:
        catalog = None
        if not args.skip_catalog:
            catalog = copy_catalog(args.catalog, run_dir)
            log.info("=" * 60)
            log.info("Catalog copy complete. Lightroom may be restarted now.")
            log.info("=" * 60)
            # Compare as text, as the join does: a path through a symlink
            # (e.g. /tmp vs /private/tmp on macOS) will not match.
            root_txt = nfc(os.path.abspath(args.scan_root)).rstrip("/") + "/"
            cat_txt = [nfc(r).rstrip("/") + "/" for r in catalog["root_folders"]]
            if cat_txt and not any(root_txt.startswith(c) or c.startswith(root_txt) for c in cat_txt):
                log.warning("Scan root %s does not overlap any catalog root folder %s; "
                            "catalog paths will not match. Pass --scan-root as the catalog "
                            "stores it, or map the prefix with run.sh --path-from/--path-to.",
                            root_txt, catalog["root_folders"])

        files = scan(args.scan_root, run_dir)

        manifest = {
            "schema": MANIFEST_SCHEMA,
            "run_id": run_id,
            "status": "complete",
            "started": started,
            "finished": now_iso(),
            "collector": {
                "version": COLLECTOR_VERSION,
                "git_commit": git_commit(script.parent),
                "script_sha256": sha256_file(script),
            },
            "host": {
                "name": host,
                "macos": platform.mac_ver()[0] or platform.platform(),
                "python": platform.python_version(),
            },
            "scan_root": nfc(os.path.abspath(args.scan_root)),
            "scan_root_in_dropbox": facts.get("scan_root_in_dropbox"),
            "dropbox_roots": facts.get("dropbox_roots", []),
            "catalog": catalog,
            "files": files,
        }
        part = run_dir / "manifest.json.part"
        part.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
        os.replace(part, run_dir / "manifest.json")
    except Exception as e:  # noqa: BLE001 - log and exit non-zero, leave no manifest
        log.exception("Run failed: %s", e)
        log.error("No manifest written; this run is incomplete. Folder: %s", run_dir)
        return 2

    log.info("Run complete: %s", run_dir)
    log.info("Next: ./push.sh %s", run_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
