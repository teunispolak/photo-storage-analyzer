# Analysis runbook

Runs on the analysis machine. Starts from the received run folder produced by the [collector runbook](collector.md).

## Prerequisites

- DuckDB: `brew install duckdb`
- Python 3.9 or newer and git
- The repository: `git clone https://github.com/teunispolak/photo-storage-analyzer`, run the commands below from inside it

## Folders

Each client and each machine at a client has its own folder; machines are analysed separately.

```
~/photo-analysis/clients/<client>/<machine>/
  runs/        received run folders (put them here; the analysis does not move them)
  analysis/    one folder per analysed run
  latest/      photos_pivot.xlsx of the last analysed run, for this machine's workbook
  pivots.xlsx  your workbook for this machine
```

Client and machine come from the run's manifest; the run folder name starts with them, e.g. `acme_anna_20261118T091500Z`. `PSA_CLIENTS_DIR` moves the `clients` folder elsewhere.

## Steps

1. Put the received run folder in `~/photo-analysis/clients/<client>/<machine>/runs/` and analyse it:
   ```
   ./psa analyse ~/photo-analysis/clients/<client>/<machine>/runs/<run folder>
   ```
   Runs collected before client and machine were recorded need them as arguments: `--client <client> --machine <machine>`.

   This verifies the run against its manifest, loads and joins it, writes the reports and prints a summary. It stops before the join if verification fails, for example after an incomplete transfer.
2. Read `join_check.csv` before the reports (see below).
3. Open the reports in `reports/`.

`./psa` first checks the repository against GitHub and updates it if it is behind. A warning `run collected with commit ..., analysis runs on ...` means the collector and the analysis used different versions.

## Options

| Option | Purpose |
|---|---|
| `--out <folder>` | output folder instead of `clients/<client>/<machine>/analysis/<run_id>`; `latest/` is then left alone |
| `--client <client> --machine <machine>` | client and machine for a run collected without them; must match the manifest when it has them |
| `--replace` | overwrite the generated files in an existing output folder |
| `--path-from <prefix> --path-to <prefix>` | replace a catalog path prefix, for a volume mounted under another name than the catalog expects |

The received run folder is only read, never changed. The catalog is read from a working copy in a temporary folder (an APFS clone where possible, which takes no extra space on the same disk); it is removed when the analysis ends, also when it is interrupted.

## Output

| File | Content |
|---|---|
| `analysis.duckdb` | DuckDB database with the `photos` table, one row per file on disk or in the catalog |
| `join_check.csv` | counts to check the join |
| `photos_pivot.xlsx` | flat file for pivot tables, one row per file; with the default output also copied to the machine's `latest/` |
| `reports/*.csv` | one CSV per report, each starting with `run_id` and `scan_date` |

Times:
- `scan_date` is the client's local time with its UTC offset, e.g. `2026-11-16 11:22:08+01:00`. Runs collected before this was recorded show UTC with `+00:00`.
- The run ID is `<client>_<machine>_<UTC timestamp>`; runs collected before labels were recorded are `<UTC timestamp>-<host>`.
- File dates (`mtime`, `btime`) are UTC; Lightroom capture times are the camera's local time. This only matters for files dated within an hour or two of New Year.

## Scope

The scan roots are the scope: every row in the `photos` table, the pivot file and the reports is a file under one of the scan roots, and carries that root in `scan_root`. Folder columns are relative to the file's own root. The catalog is used to look up those files (capture date, catalogued or not). Catalog entries outside all scan roots are not analysed; they are counted once, in `join_check.csv` and `reports/reconciliation.csv`.

Runs collected before multiple scan roots were supported analyse the same way, with their single root.

## Join check

| Metric | Read as |
|---|---|
| `matched` | files both on disk and in the catalog |
| `disk_only` | files on disk the catalog does not know |
| `catalog_only` | files the catalog expects under the scan root that are not on disk |
| `catalog_outside_scan_root` | catalog entries outside the scan root; not analysed |
| `matched_case_only` | matched only after ignoring upper and lower case |
| `catalog_paths_nfc_changed` | catalog paths with a different Unicode form, matched after normalizing |
| `catalog_paths_prefix_mapped` | catalog paths changed by `--path-from`/`--path-to` |
| `virtual_copies_excluded` | virtual copies left out; they share the photo's file |
| `date_source_catalog`, `date_source_mtime` | files dated by catalog capture time, or by file date as fallback |

`matched` = 0 with a large `catalog_outside_scan_root` usually means the catalog stores the photos under another path than the scan root: check the collector log for `does not overlap`, and use `--path-from`/`--path-to`.

## Pivot workbook

`photos_pivot.xlsx` has one row per file under the scan root, found in the filesystem, the catalog or both (`source`). Its columns and their meaning are listed in [`analysis/pivot_columns.csv`](../analysis/pivot_columns.csv); that list is the contract, and every change to it comes with pivot impact steps in its PR.

Keep your pivots in a separate workbook per machine, so a new run only needs a refresh. Set it up once per machine, in Excel for Microsoft 365 for Mac:

1. Create a new workbook `~/photo-analysis/clients/<client>/<machine>/pivots.xlsx`, or copy another machine's workbook there and change its source in step 2 (Data > Get Data > Data Source Settings > Change Source).
2. Data > Get Data (Power Query) > Excel workbook, and choose `~/photo-analysis/clients/<client>/<machine>/latest/photos_pivot.xlsx`.
3. Select the sheet `photos` and load it to a table on a new sheet. Do not load it to the Data Model: Excel for Mac cannot refresh that.
4. Data > Get Data (Power Query) > Launch Power Query Editor, select the query `photos`, and under Applied Steps delete `Changed column type` (right-click > Delete). Then Home > Close & Load. Excel adds that step automatically and it names every column; when a column is later removed or renamed, the refresh stops with an error. The pivot file already stores numbers as numbers, so the step is not needed.
5. Click inside the table, then Insert > PivotTable.

After each `./psa analyse` with the default output, Data > Refresh All updates the table and the pivots.

If a refresh stops with `The column '…' of the table wasn't found`, the workbook still has the `Changed column type` step: delete it as in step 4, then refresh again.

Reconciliation, the same split as `reports/reconciliation.csv`:
- Rows: `source`, `catalog_role`
- Values: Count of `name`, Sum of `size_mb`

The grand total is all files in scope; check it against the first line of `reconciliation.csv`.

Example, files on disk that Lightroom does not know:
- Filters: `type_group` = raw, `source` = filesystem only
- Rows: `top_folder`, `folder`
- Columns: `hint`
- Values: Count of `name`, Sum of `size_mb`

`hint` = `moved?`: the catalog has a file with that name at `catalog_folder`, which may be outside the scan root. Outside it, this is usually a copy of the same photo in another tree; inside it, the file may have been moved outside Lightroom (Find Missing Folder). `dng original?`: the raw original next to its DNG. Empty: not imported.

## Regression check

After a change to the tool, check whether the analysis results changed:

```
./psa regress
```

It analyses the baseline run again into a temporary folder and compares the result with the stored baseline analysis: each report, `join_check.csv`, and the contents of `photos_pivot.xlsx` when the baseline has one. Each output is compared as a table. For an output that differs, it shows:

- how many rows differ, and per column in how many rows; or, when the row count changed, how many rows are only in the baseline and only in the new analysis
- up to five example lines, and the file with the full diff

```
--- reports/volume_by_type.csv: 1 of 5 rows differ
      type_group         1 row
      examples (full diff: /tmp/psa-regress.XXXX/diff/reports_volume_by_type.csv.diff):
        -...,sidecar,1,3,0.0,0.0
        +...,metadata,1,3,0.0,0.0
```

`./psa regress --full` prints the full diffs as well. The last line is the verdict:

| Verdict | Exit |
|---|---|
| `regression: no differences` | 0 |
| `regression: differences in <outputs>` | 1 |
| `regression: could not run: <reason>` | 2 |

The baseline is `~/photo-analysis/baseline/` with `run/` (a collected run folder, never changed) and `analysis/` (its analysis); `PSA_BASELINE` sets another location.

When a change is meant to alter the results, review the differences, then:

```
./psa regress --refresh
```

It asks for confirmation, keeps the previous analysis as `analysis.<timestamp>`, and replaces `baseline/analysis` with the new output. `baseline/run` is never touched.

## Reports

| Report | Content |
|---|---|
| `volume_by_type` | files and volume by type group |
| `volume_by_year` | by capture year, with running total and how each year was dated |
| `volume_by_scan_root` | files and volume per scan root, by source |
| `volume_by_folder` | by scan root and top-level folder under it |
| `size_buckets` | by file size bucket |
| `not_catalogued` | files on disk not in the catalog, by type and year |
| `missing_from_disk` | files in the catalog not on disk, one row per file |
| `reconciliation` | all files in scope, split level by level: filesystem (filesystem and catalog, by catalog role; filesystem only) and catalog only (by catalog role); each line adds up to its parent; catalog entries outside the scan root and virtual copies on separate lines |

Volume reports count files on disk; units are decimal (1 GB = 10^9 bytes). The output holds customer data.
