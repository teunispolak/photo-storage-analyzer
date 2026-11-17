# Collector runbook

Runs on the client Mac. Produces a run folder for the [analysis runbook](analysis.md).

## Prerequisites

- Python 3.9 or newer and git: `python3 --version`, `git --version` (both come with the Command Line Tools; macOS offers to install them on first use)
- The repository: `git clone https://github.com/teunispolak/photo-storage-analyzer`, run the commands below from inside it
- Photo drive mounted

## Steps

1. Close Lightroom Classic.
   Optional, recommended on a new client: check the catalog's structure and see its root folders:
   ```
   ./psa check-catalog "$HOME/Pictures/Lightroom/<name>.lrcat" --show-roots
   ```
   Exit 1 means the catalog lacks tables or columns the join needs; stop and report it. The root folder that holds the photos is the value for `SCAN_ROOT`.
2. Once per client, create the [settings file](#settings-file) `~/photo-analysis/settings.env`:
   ```
   CATALOG="$HOME/Pictures/Lightroom/<name>.lrcat"
   SCAN_ROOT="/Volumes/<drive>/<photo root>"
   ```
   For photos in more than one folder tree, add a `SCAN_ROOT` line per tree. The roots must not be nested; preflight refuses a root inside another, or the same root twice. The log and the manifest give the files and volume per root.
3. Run the collector:
   ```
   ./psa collect
   ```
   It prints the settings file and the values it took from it.

   Output goes to `~/photo-analysis/out/<run_id>/`; `--out` changes it. The output folder must not be inside a scan root or a Dropbox folder; preflight checks this.
4. When the log shows `Lightroom may be restarted now`, Lightroom can be reopened. The scan reads metadata only.
5. Transfer the run folder `~/photo-analysis/out/<run_id>/` to the analysis machine.
6. After the analysis has verified the received run folder, the run folder on the client Mac can be removed. Nothing is removed automatically.

On first run, macOS asks to allow Terminal access to the removable volume. Allow it.

Each `./psa` command first checks the repository against GitHub and updates it if it is behind. A warning such as `not updated: offline` means the scripts run as they are; the manifest records the result.

## Settings file

`./psa collect` and `./psa check-catalog` read `~/photo-analysis/settings.env` when it exists. `PSA_SETTINGS=<file>` names another file; `PSA_SETTINGS=""` uses none.

- One `KEY="value"` per line; blank lines and lines starting with `#` are ignored.
- `CATALOG`: the `.lrcat` file, once. `SCAN_ROOT`: a photo folder tree, one line per tree.
- The file is read, not executed: `$HOME` and a leading `~` are expanded, nothing else.
- Arguments replace the file's values: any `--scan-root` replaces all `SCAN_ROOT` lines, `--catalog` (or the catalog argument of `check-catalog`) replaces `CATALOG`.
- A line that is not `KEY="value"`, an unknown key, `CATALOG` twice, an empty value or a missing file stops the run with exit 1, before anything is written.

The manifest records the file, its checksum, the values taken from it and the keys replaced by arguments.

## Options

| Option | Purpose |
|---|---|
| `--scan-root <folder>` | photo folder tree (repeatable); replaces the settings file's `SCAN_ROOT` lines |
| `--catalog <file>` | the `.lrcat` file; replaces the settings file's `CATALOG` |
| `--out <folder>` | base output folder (default `~/photo-analysis/out`) |
| `--dropbox-root <folder>` | extra Dropbox folder to keep output out of (repeatable) |
| `--skip-catalog` | scan only, no catalog copy |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | complete |
| 1 | settings file or preflight failed; nothing written |
| 2 | run failed; no manifest, the run folder is incomplete and the analysis refuses it |

## Output

| File | Content |
|---|---|
| `catalog.lrcat` | copy of the Lightroom catalog |
| `files.csv` | one row per file under the scan roots, with the root it was found under |
| `manifest.json` | run metadata, counts, checksums; written last |
| `collector.log` | log of the run |

The run folder holds customer data: file paths and the full Lightroom catalog (keywords, GPS, face names).
