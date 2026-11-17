#!/usr/bin/env python3
"""
Photo storage assessment - collector.

Runs on the client's Mac. Collects facts only; all interpretation happens
on the analysis machine.

Steps:
  1. Settings file (--settings) and preflight checks (stop on any failure,
     nothing written outside out dir)
  2. Copy the Lightroom catalog and verify the copy
  3. Scan the photo trees, one per --scan-root (metadata only, file contents
     are not read)
  4. Write manifest.json last; its presence marks a complete run

Output: <out>/<run_id>/, run_id = <client>_<machine>_<UTC timestamp>
  catalog.lrcat    copy of the Lightroom catalog
  files.csv        one row per file under the scan roots
  manifest.json    run metadata, counts, checksums
  collector.log    log of the collector

Requires Python 3.9+, standard library only.
Nothing is deleted or modified outside the collection folder.
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
    "scan_root",    # the scan root this file was found under (absolute, NFC)
]

# settings.py sits next to this script; python -I leaves the script's folder off sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import settings as settings_file  # noqa: E402

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


def local_iso(ts: float) -> str:
    """Local time of this Mac with its UTC offset, e.g. 2026-11-16T11:22:08+01:00."""
    return dt.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


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

    roots = args.scan_roots
    out_base = args.out
    for scan_root in roots:
        if not scan_root.is_dir():
            problems.append(f"Scan root is not a folder: {scan_root}")
        elif not os.access(scan_root, os.R_OK | os.X_OK):
            problems.append(f"Scan root is not readable: {scan_root}")
        if scan_root.is_dir() and is_within(out_base, scan_root):
            problems.append(f"Output folder {out_base} is inside the scan root {scan_root}")
    # Each file must belong to exactly one scan root
    for i, a in enumerate(roots):
        for b in roots[i + 1:]:
            if a.is_dir() and b.is_dir():
                if a.resolve() == b.resolve():
                    problems.append(f"Scan root given twice: {a}")
                elif is_within(a, b) or is_within(b, a):
                    problems.append(f"Scan roots are nested, files would be counted twice: {a} and {b}")

    dbx = dropbox_roots() + extra_roots
    facts["dropbox_roots"] = [str(p) for p in dbx]
    for root in dbx:
        if is_within(out_base, root):
            problems.append(f"Output folder {out_base} is inside a Dropbox folder: {root}")
    facts["scan_root_in_dropbox"] = {
        nfc(os.path.abspath(r)): any(is_within(r, d) for d in dbx) for r in roots if r.is_dir()}

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

def scan(scan_roots: List[Path], run_dir: Path) -> dict:
    dest = run_dir / "files.csv"
    part = run_dir / "files.csv.part"
    t0 = time.time()

    files = dirs = errors = 0
    total_size = total_alloc = dataless_count = 0
    per_root = {}

    with open(part, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(CSV_COLUMNS)
        for scan_root in scan_roots:
            root_str = os.path.abspath(scan_root)
            root_nfc = nfc(root_str)
            log.info("Scanning %s", root_str)
            before_files, before_size = files, total_size
            stack = [root_str]
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
                            root_nfc,
                        ])
                        files += 1
                        total_size += st.st_size
                        total_alloc += alloc
                        dataless_count += dataless
                        if files % PROGRESS_EVERY == 0:
                            log.info("  %d files, %.2f TB, %.0f s",
                                     files, total_size / 1e12, time.time() - t0)
            per_root[root_nfc] = {"rows": files - before_files, "size_bytes": total_size - before_size}
            log.info("  %s: %d files, %.2f TB", root_nfc, files - before_files,
                     (total_size - before_size) / 1e12)
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
        "per_root": per_root,
    }


# ---------------------------------------------------------------- main

def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Collect file and catalog data for a photo storage assessment.")
    p.add_argument("--scan-root", type=Path, action="append", dest="scan_roots", default=[],
                   help="root of a photo folder tree (e.g. /Volumes/Photos/Photos); "
                        "repeat for more roots, roots must not be nested; "
                        "replaces all SCAN_ROOT lines of the settings file")
    p.add_argument("--catalog", type=Path, help="path to the .lrcat file; replaces CATALOG of the settings file")
    p.add_argument("--client", help="client name; replaces CLIENT of the settings file")
    p.add_argument("--machine", help="machine within the client; replaces MACHINE of the settings file")
    p.add_argument("--settings", type=Path,
                   help="settings file with CATALOG and SCAN_ROOT (./psa passes it when it exists)")
    p.add_argument("--out", type=Path, default=Path.home() / "photo-analysis" / "out",
                   help="base output folder (default: ~/photo-analysis/out)")
    p.add_argument("--dropbox-root", type=Path, action="append", default=[],
                   help="extra Dropbox folder to treat as off-limits for output (repeatable)")
    p.add_argument("--skip-catalog", action="store_true",
                   help="scan only, no catalog copy")
    return p.parse_args(argv)


def apply_settings(args) -> Optional[dict]:
    """Fill scan roots and catalog from the settings file where the command
    line gave none. Returns the manifest record, or None without a file."""
    if args.settings is None:
        return None
    s = settings_file.load(args.settings)  # SettingsError stops the run
    used, replaced = {}, []
    if s.get_list("SCAN_ROOT"):
        if args.scan_roots:
            replaced.append("SCAN_ROOT")
        else:
            args.scan_roots = [Path(r) for r in s.get_list("SCAN_ROOT")]
            used["SCAN_ROOT"] = s.get_list("SCAN_ROOT")
    for key, attr in (("CLIENT", "client"), ("MACHINE", "machine")):
        if s.get(key):
            if getattr(args, attr):
                replaced.append(key)
            else:
                setattr(args, attr, s.get(key))
                used[key] = s.get(key)
    if s.get("CATALOG"):
        if args.catalog:
            replaced.append("CATALOG")
        else:
            args.catalog = Path(s.get("CATALOG"))
            used["CATALOG"] = s.get("CATALOG")
    return {"file": str(s.path), "sha256": s.sha256, "used": used,
            "replaced_by_command_line": replaced}


def log_settings(record: Optional[dict], out: logging.Logger) -> None:
    if record is None:
        out.info("Settings file: none")
        return
    out.info("Settings file: %s", record["file"])
    for key, value in record["used"].items():
        for v in (value if isinstance(value, list) else [value]):
            out.info("  %s from settings file: %s", key, v)
    for key in record["replaced_by_command_line"]:
        out.info("  %s from the command line; the settings file value is not used", key)


def main(argv=None) -> int:
    args = parse_args(argv)

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%H:%M:%S"))
    log.addHandler(console)
    log.setLevel(logging.INFO)

    try:
        settings_record = apply_settings(args)
    except (settings_file.SettingsError, UnicodeDecodeError) as e:
        log.error("%s", e)
        return 1
    if not args.scan_roots:
        log.error("No scan root: give --scan-root or SCAN_ROOT in the settings file")
        return 1
    for key, attr in (("CLIENT", "client"), ("MACHINE", "machine")):
        value = getattr(args, attr)
        if not value:
            log.error("No %s: give --%s or %s in the settings file", attr, attr, key)
            return 1
        if settings_file.label_error(f"--{attr}", value):
            log.error("%s", settings_file.label_error(f"--{attr}", value))
            return 1
    args.scan_roots = [r.expanduser() for r in args.scan_roots]
    args.out = args.out.expanduser()
    if args.catalog:
        args.catalog = args.catalog.expanduser()
    log_settings(settings_record, log)

    host = socket.gethostname().split(".")[0]
    # client and machine first, so the folder name says whose run it is
    run_id = f"{args.client}_{args.machine}_" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = args.out / run_id

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
    log.info("Collector %s, collection %s", COLLECTOR_VERSION, run_id)
    log.info("Client %s, machine %s, host %s", args.client, args.machine, host)
    # The settings lines went to the console before preflight; repeat them in the log file
    file_log = logging.getLogger("collector.file")
    file_log.propagate = False
    file_log.addHandler(fh)
    file_log.setLevel(logging.INFO)
    log_settings(settings_record, file_log)
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
            cat_txt = [nfc(r).rstrip("/") + "/" for r in catalog["root_folders"]]
            for scan_root in args.scan_roots:
                root_txt = nfc(os.path.abspath(scan_root)).rstrip("/") + "/"
                if cat_txt and not any(root_txt.startswith(c) or c.startswith(root_txt) for c in cat_txt):
                    log.warning("Scan root %s does not overlap any catalog root folder %s; "
                                "catalog paths will not match. Pass --scan-root as the catalog "
                                "stores it, or map the prefix with run.sh --path-from/--path-to.",
                                root_txt, catalog["root_folders"])

        files = scan(args.scan_roots, run_dir)

        finished_ts = time.time()
        manifest = {
            "schema": MANIFEST_SCHEMA,
            "run_id": run_id,
            "client": args.client,
            "machine": args.machine,
            "status": "complete",
            "started": started,
            "finished": utc_iso(finished_ts),
            "finished_local": local_iso(finished_ts),  # same moment, client's clock
            "collector": {
                "version": COLLECTOR_VERSION,
                "git_commit": git_commit(script.parent),
                "script_sha256": sha256_file(script),
                "settings_module_sha256": settings_file.module_sha256(),
                # set by ./psa; absent when the collector is called directly
                "update_check": {
                    "status": os.environ.get("PSA_UPDATE_STATUS", "not_run"),
                    "detail": os.environ.get("PSA_UPDATE_DETAIL", "collector called without ./psa"),
                },
            },
            "host": {
                "name": host,
                "macos": platform.mac_ver()[0] or platform.platform(),
                "python": platform.python_version(),
            },
            # settings file and the values taken from it; null without a file
            "settings": settings_record,
            "scan_roots": [nfc(os.path.abspath(r)) for r in args.scan_roots],
            "scan_root_in_dropbox": facts.get("scan_root_in_dropbox"),
            "dropbox_roots": facts.get("dropbox_roots", []),
            "catalog": catalog,
            "files": files,
        }
        part = run_dir / "manifest.json.part"
        part.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
        os.replace(part, run_dir / "manifest.json")
    except Exception as e:  # noqa: BLE001 - log and exit non-zero, leave no manifest
        log.exception("Collection failed: %s", e)
        log.error("No manifest written; this collection is incomplete. Folder: %s", run_dir)
        return 2

    log.info("Collection complete: %s", run_dir)
    log.info("Next: transfer this collection to the analysis machine: %s", run_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
