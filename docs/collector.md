# Collector runbook

The collector runs on the client Mac; the analysis on the analysis machine.

## Prerequisites

- Python 3.9 or newer: `python3 --version`
- Photo drive mounted

## Steps

1. Close Lightroom Classic.
   Optional, recommended on a new client: check the catalog's structure and see its root folders:
   ```
   python3 collector/check_catalog.py "$HOME/Pictures/Lightroom/<name>.lrcat" --show-roots
   ```
   Exit 1 means the catalog lacks tables or columns the join needs; stop and report it. The root folder that holds the photos is the value for `--scan-root`.
2. Run the collector:
   ```
   python3 collector/collect.py \
     --scan-root "/Volumes/<drive>/<photo root>" \
     --catalog "$HOME/Pictures/Lightroom/<name>.lrcat"
   ```
   Output goes to `~/photo-analysis/out/<run_id>/`; `--out` changes it. The output folder must not be inside the scan root or a Dropbox folder; preflight checks this.
3. When the log shows `Lightroom may be restarted now`, Lightroom can be reopened. The scan reads metadata only.
4. Transfer the run folder `~/photo-analysis/out/<run_id>/` to the analysis machine.
5. On the analysis machine, verify and analyse the run:
   ```
   analysis/run.sh <received run folder>
   ```
   It stops before the join if verification fails, for example after an incomplete transfer.
6. After verification, the run folder on the client Mac can be removed. Nothing is removed automatically.

On first run, macOS asks to allow Terminal access to the removable volume. Allow it.

## Options

| Option | Purpose |
|---|---|
| `--out <folder>` | base output folder (default `~/photo-analysis/out`) |
| `--dropbox-root <folder>` | extra Dropbox folder to keep output out of (repeatable) |
| `--skip-catalog` | scan only, no catalog copy |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | complete |
| 1 | preflight failed; nothing written |
| 2 | run failed; no manifest, the run folder is incomplete and `run.sh` refuses it |

## Output

| File | Content |
|---|---|
| `catalog.lrcat` | copy of the Lightroom catalog |
| `files.csv` | one row per file under the scan root |
| `manifest.json` | run metadata, counts, checksums; written last |
| `collector.log` | log of the run |

The run folder holds customer data: file paths and the full Lightroom catalog (keywords, GPS, face names).
