# Collection runbook

Runs on the client Mac. Requires the [intake setup](intake-setup.md) to be done.

## Prerequisites

- Python 3.9 or newer: `python3 --version`
- Photo drive mounted
- SSH key `~/.ssh/photo_intake` installed on the analysis machine

## Steps

1. Close Lightroom Classic.
2. Run the collector:
   ```
   python3 collector/collect.py \
     --scan-root "/Volumes/<drive>/<photo root>" \
     --catalog "$HOME/Pictures/Lightroom/<name>.lrcat"
   ```
   Output goes to `~/photo-analysis/out/<run_id>/`; `--out` changes it. The output folder must not be inside the scan root or a Dropbox folder; preflight checks this.
3. When the log shows `Lightroom may be restarted now`, Lightroom can be reopened. The scan reads metadata only.
4. Push the run:
   ```
   PHOTO_INTAKE_DEST="intake@<analysis-host>:runs/" ./collector/push.sh ~/photo-analysis/out/<run_id>
   ```
   If the connection drops, run the same command again; it resumes.
5. On the analysis machine, verify the run:
   ```
   python3 analysis/verify.py <intake folder>/runs/<run_id>
   ```
6. After verification, the local run folder can be removed. `push.sh` prints the command; nothing is removed automatically.

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
| 2 | run failed; no manifest, the run folder is incomplete and `push.sh` refuses it |

## Output

| File | Content |
|---|---|
| `catalog.lrcat` | copy of the Lightroom catalog |
| `files.csv` | one row per file under the scan root |
| `manifest.json` | run metadata, counts, checksums; written last |
| `collector.log` | log of the run |

The run folder holds customer data: file paths and the full Lightroom catalog (keywords, GPS, face names).
