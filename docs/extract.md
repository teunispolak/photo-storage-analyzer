# Extract runbook

Runs on the client Mac. Produces an extract for the [Analyse runbook](analyse.md).

For the client there is a step-by-step [Extract guide](extract-guide.md). With it, the client sends you the locations of their catalog and photo folder; you write their `settings.env` from those (see [Settings file](#settings-file)) and send it back.

Each extract carries a copy of the `settings.env` it was made with; after the analysis it is in `clients/<client>/<machine>/latest/settings.env`. To change what the next extract covers, such as the scan roots, edit that copy and send it to the client, who saves it as in step 5 of the guide. Keep `CLIENT` and `MACHINE` unchanged, so the next extract is filed with the previous ones.

## Terms

| Term | Meaning |
|---|---|
| client | the customer; one name for all their machines |
| machine | one Mac at a client, with its own disk and Lightroom catalog |
| extract | what `./psa extract` produces on one machine: metadata of the photo files and a copy of the Lightroom catalog, in a folder with `manifest.json`, `catalog.lrcat`, `files.csv` and `extract.log`. No photos. Its ID, `extract_id` in the files, is `<client>_<machine>_<UTC timestamp>` |
| analysis | what `./psa analyse` produces from one extract: a folder with `analysis.duckdb`, `join_check.csv`, `photos_pivot.xlsx` and `reports/` |

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
   CLIENT="<client>"
   MACHINE="<machine>"
   CATALOG="$HOME/Pictures/Lightroom/<name>.lrcat"
   SCAN_ROOT="/Volumes/<drive>/<photo root>"
   ```
   `CLIENT` names the client, `MACHINE` this machine within the client, for example its user. Both are required, and start the extract ID; use lowercase letters, digits and hyphens. Use the same `CLIENT` on every machine of one client.
   For photos in more than one folder tree, add a `SCAN_ROOT` line per tree. The roots must not be nested; preflight refuses a root inside another, or the same root twice. The log and the manifest give the files and volume per root.
3. Extract:
   ```
   ./psa extract
   ```
   It prints the settings file and the values it took from it.

   The extract goes to `~/photo-analysis/extracts/<extract ID>/`, the inbox the analysis files from; `--out` or `PSA_EXTRACTS_DIR` changes the base folder. The output folder must not be inside a scan root or a Dropbox folder; preflight checks this.
4. When the log shows `Lightroom may be restarted now`, Lightroom can be reopened. The scan reads metadata only.
5. Transfer the extract `~/photo-analysis/extracts/<extract ID>/` to the analysis machine, into its inbox `~/photo-analysis/extracts/`. On the analysis machine itself, it is there already.
6. After the analysis has verified the received extract, the extract on the client Mac can be removed. Nothing is removed automatically.

The first time, macOS asks to allow Terminal access to the removable volume. Allow it.

Each `./psa` command first checks the repository against GitHub and updates it if it is behind. A warning such as `not updated: offline` means the scripts run as they are; the manifest records the result.

## Settings file

`./psa extract` and `./psa check-catalog` read `~/photo-analysis/settings.env` when it exists. `PSA_SETTINGS=<file>` names another file; `PSA_SETTINGS=""` uses none.

- One `KEY="value"` per line; blank lines and lines starting with `#` are ignored.
- `CLIENT` and `MACHINE`: once each, lowercase letters, digits and hyphens, at most 40 characters. `CATALOG`: the `.lrcat` file, once. `SCAN_ROOT`: a photo folder tree, one line per tree.
- The file is read, not executed: `$HOME` and a leading `~` are expanded, nothing else.
- Arguments replace the file's values: `--client`, `--machine` and `--catalog` (or the catalog argument of `check-catalog`) replace their key; any `--scan-root` replaces all `SCAN_ROOT` lines.
- A line that is not `KEY="value"`, an unknown key, a key other than `SCAN_ROOT` twice, an empty value, an invalid label or a missing file stops the extract with exit 1, before anything is written.

The manifest records the file, its checksum, the values taken from it and the keys replaced by arguments.

## Options

| Option | Purpose |
|---|---|
| `--client <client>`, `--machine <machine>` | client and machine labels; replace the settings file's `CLIENT` and `MACHINE` |
| `--scan-root <folder>` | photo folder tree (repeatable); replaces the settings file's `SCAN_ROOT` lines |
| `--catalog <file>` | the `.lrcat` file; replaces the settings file's `CATALOG` |
| `--out <folder>` | base output folder (default `$PSA_EXTRACTS_DIR`, or `~/photo-analysis/extracts`) |
| `--dropbox-root <folder>` | extra Dropbox folder to keep output out of (repeatable) |
| `--skip-catalog` | scan only, no catalog copy |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | complete |
| 1 | settings file or preflight failed; nothing written |
| 2 | extract failed; no manifest, the extract is incomplete and the analysis refuses it |

## Output

| File | Content |
|---|---|
| `catalog.lrcat` | copy of the Lightroom catalog |
| `files.csv` | one row per file under the scan roots, with the root it was found under |
| `manifest.json` | extract metadata, counts, checksums, tool version; written last |
| `extract.log` | log of the extract |
| `settings.env` | exact copy of the settings file used; absent without one |
| `README.txt` | plain-text index of the extract, for the client and for you |

The extract holds customer data: file paths and the full Lightroom catalog (keywords, GPS, face names).
