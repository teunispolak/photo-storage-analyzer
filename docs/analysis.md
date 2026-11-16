# Analysis runbook

Runs on the analysis machine. Starts from the received run folder produced by the [collector runbook](collector.md).

## Prerequisites

- DuckDB: `brew install duckdb`
- Python 3.9 or newer and git
- The repository: `git clone https://github.com/teunispolak/photo-storage-analyzer`, run the commands below from inside it

## Steps

1. Analyse the received run folder:
   ```
   ./psa analyse <received run folder>
   ```
   This verifies the run against its manifest, loads and joins it, writes the reports and prints a summary. It stops before the join if verification fails, for example after an incomplete transfer.
2. Read `join_check.csv` before the reports (see below).
3. Open the reports in `reports/`.

`./psa` first checks the repository against GitHub and updates it if it is behind. A warning `run collected with commit ..., analysis runs on ...` means the collector and the analysis used different versions.

## Options

| Option | Purpose |
|---|---|
| `--out <folder>` | output folder (default `~/photo-analysis/analysis/<run_id>`) |
| `--replace` | overwrite the generated files in an existing output folder |
| `--path-from <prefix> --path-to <prefix>` | replace a catalog path prefix, for a volume mounted under another name than the catalog expects |

The received run folder is only read, never changed.

## Output

| File | Content |
|---|---|
| `analysis.duckdb` | DuckDB database with the `photos` table, one row per file on disk or in the catalog |
| `join_check.csv` | counts to check the join |
| `reports/*.csv` | one CSV per report, each starting with `run_id` and `scan_date` |

Times:
- `scan_date` is the client's local time with its UTC offset, e.g. `2026-11-16 11:22:08+01:00`. Runs collected before this was recorded show UTC with `+00:00`.
- The run ID is in UTC (`...Z`), for sorting.
- File dates (`mtime`, `btime`) are UTC; Lightroom capture times are the camera's local time. This only matters for files dated within an hour or two of New Year.

## Join check

| Metric | Read as |
|---|---|
| `matched` | files both on disk and in the catalog |
| `disk_only` | files on disk the catalog does not know |
| `catalog_only` | files the catalog knows that are not on disk |
| `matched_case_only` | matched only after ignoring upper and lower case |
| `catalog_paths_nfc_changed` | catalog paths with a different Unicode form, matched after normalizing |
| `catalog_paths_prefix_mapped` | catalog paths changed by `--path-from`/`--path-to` |
| `virtual_copies_excluded` | virtual copies left out; they share the master's file |
| `date_source_catalog`, `date_source_mtime` | files dated by catalog capture time, or by file date as fallback |

`matched` = 0 with many `catalog_only` usually means the catalog stores the photos under another path than the scan root: check the collector log for `does not overlap`, and use `--path-from`/`--path-to`.

## Reports

| Report | Content |
|---|---|
| `volume_by_type` | files and volume by type group |
| `volume_by_year` | by capture year, with running total and how each year was dated |
| `volume_by_folder` | by top-level folder under the scan root |
| `size_buckets` | by file size bucket |
| `not_catalogued` | files on disk not in the catalog, by type and year |
| `missing_from_disk` | files in the catalog not on disk, one row per file |

Volume reports count files on disk; units are decimal (1 GB = 10^9 bytes). The output holds customer data.
