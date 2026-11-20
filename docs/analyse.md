# Analyse runbook

Runs on the analysis machine. Starts from an extract received from the client, made with the [Extract runbook](extract.md).

## Terms

| Term | Meaning |
|---|---|
| client | the customer; one name for all their machines |
| machine | one Mac at a client, with its own disk and Lightroom catalog |
| extract | what `./psa extract` produces on one machine: metadata of the photo files and a copy of the Lightroom catalog, in a folder with `manifest.json`, `catalog.lrcat`, `files.csv` and `extract.log`. No photos. Its ID, `extract_id` in the files, is `<client>_<machine>_<UTC timestamp>` |
| analysis | what `./psa analyse` produces from one extract: a folder with `analysis.duckdb`, `join_check.csv`, `photos_pivot.xlsx` and `reports/` |

## Prerequisites

- DuckDB: `brew install duckdb`
- Python 3.9 or newer and git
- The repository: `git clone https://github.com/teunispolak/photo-storage-analyzer`, run the commands below from inside it

## Folders

Extracts arrive in one inbox, `~/photo-analysis/extracts/`: a downloaded extract goes there, and `./psa extract` on this machine writes there. `./psa analyse` files each extract from the inbox in its client and machine folder; the inbox holds only extracts still to be analysed.

Each client and each machine at a client has its own folder; machines are analysed separately.

```
~/photo-analysis/clients/<client>/<machine>/
  extracts/    received extracts, filed here by ./psa analyse
  analysis/    one analysis per extract
  latest/      photos_pivot.xlsx of the last analysis, for this machine's workbook
  pivots.xlsx  your workbook for this machine
```

Client and machine come from the extract's manifest; the extract ID starts with them, e.g. `acme_anna_20261118T091500Z`. `PSA_EXTRACTS_DIR` moves the inbox, `PSA_CLIENTS_DIR` the `clients` folder.

## Steps

1. Put a received extract in the inbox `~/photo-analysis/extracts/` (download it there); an extract made on this machine is there already. Analyse it:
   ```
   ./psa analyse ~/photo-analysis/extracts/<extract ID>
   ```
   It is verified, then filed: copied to `~/photo-analysis/clients/<client>/<machine>/extracts/<extract ID>/` (client and machine from its manifest), verified again, removed from the inbox, and analysed from the filed copy. If the copy fails, the extract stays in the inbox. An extract given from anywhere else, such as Downloads, is filed the same way but left where it was. To analyse an extract again, give its filed copy, with `--replace`.

   An extract already filed under its ID stops the analysis rather than being overwritten, as does an extract inside `clients/` that is not at its own place.
   An extract made by an older version of the tool is refused; extract again.

   This verifies the extract against its manifest, loads and joins it, writes the reports and prints a summary. It stops before the join if verification fails, for example after an incomplete transfer.
2. Read `join_check.csv` before the reports (see below).
3. Open the reports in `reports/`.

`./psa` first checks the repository against GitHub and updates it if it is behind. A warning `extract made with commit ..., analysis runs on ...` means the extract and the analysis used different versions.

## Options

| Option | Purpose |
|---|---|
| `--out <folder>` | output folder instead of `clients/<client>/<machine>/analysis/<extract ID>`; the extract is not filed and `latest/` is left alone |
| `--replace` | overwrite the generated files in an existing output folder |
| `--path-from <prefix> --path-to <prefix>` | replace a catalog path prefix, for a volume mounted under another name than the catalog expects |

The extract is only read, never changed. The catalog is read from a working copy in a temporary folder (an APFS clone where possible, which takes no extra space on the same disk); it is removed when the analysis ends, also when it is interrupted. The analysis is built in a folder next to the output folder and moved into place only when it succeeds: a failed analysis leaves the output folder as it was, absent or with the previous analysis.

## Output

| File | Content |
|---|---|
| `analysis.duckdb` | DuckDB database with the `photos` table, one row per file on disk or in the catalog |
| `join_check.csv` | counts to check the join |
| `photos_pivot.xlsx` | flat file for pivot tables, one row per file; with the default output also copied to the machine's `latest/` |
| `reports/*.csv` | one CSV per report, each starting with `extract_id` and `scan_date` |

Times:
- `scan_date` is the client's local time with its UTC offset, e.g. `2026-11-16 11:22:08+01:00`.
- The extract ID is `<client>_<machine>_<UTC timestamp>`.
- File dates (`mtime`, `btime`) are UTC; Lightroom capture times are the camera's local time. This only matters for files dated within an hour or two of New Year.

## Scope

The scan roots are the scope: every row in the `photos` table, the pivot file and the reports is a file under one of the scan roots, and carries that root in `scan_root`. Folder columns are relative to the file's own root. The catalog is used to look up those files (capture date, catalogued or not). Catalog entries outside all scan roots are not analysed; they are counted once, in `join_check.csv` and `reports/reconciliation.csv`.

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

`matched` = 0 with a large `catalog_outside_scan_root` usually means the catalog stores the photos under another path than the scan root: check `extract.log` for `does not overlap`, and use `--path-from`/`--path-to`.

## Pivot workbook

`photos_pivot.xlsx` has one row per file under the scan root, found in the filesystem, the catalog or both (`source`). Its columns and their meaning are listed in [`analyse/pivot_columns.csv`](../analyse/pivot_columns.csv); that list is the contract, and every change to it comes with pivot impact steps in its PR.

Keep your pivots in a separate workbook per machine, `~/photo-analysis/clients/<client>/<machine>/pivots.xlsx`, so a new analysis only needs a refresh. Excel for Microsoft 365 for Mac.

For a machine that has no workbook yet, take one of the two routes below, not both. Copying is the usual one; a copy keeps all your pivots.

**Copy another machine's workbook**

1. Copy `pivots.xlsx` from another machine's folder to `~/photo-analysis/clients/<client>/<machine>/`, and open the copy.
2. Data > Get Data > Data Source Settings. Select the source, which is the other machine's `latest/photos_pivot.xlsx`, click Change Source, and choose `~/photo-analysis/clients/<client>/<machine>/latest/photos_pivot.xlsx`. OK, then Close.
3. Data > Refresh All. The table and the pivots now show this machine's data.

Do not use Get Data > Excel workbook in a copy: that adds a second query and table (`photos (2)`), which the pivots do not use. If that happened: Data > Queries & Connections, right-click `photos (2)` > Delete, delete the sheet that holds its table, and continue with step 2.

**New workbook**

1. Create a new workbook `~/photo-analysis/clients/<client>/<machine>/pivots.xlsx`.
2. Data > Get Data (Power Query) > Excel workbook, and choose `~/photo-analysis/clients/<client>/<machine>/latest/photos_pivot.xlsx`.
3. Select the sheet `photos` and load it to a table on a new sheet. Do not load it to the Data Model: Excel for Mac cannot refresh that.
4. Data > Get Data (Power Query) > Launch Power Query Editor, select the query `photos`, and under Applied Steps delete `Changed column type` (right-click > Delete). Then Home > Close & Load. Excel adds that step automatically and it names every column; when a column is later removed or renamed, the refresh stops with an error. The pivot file already stores numbers as numbers, so the step is not needed.
5. Click inside the table, then Insert > PivotTable.

After each `./psa analyse` with the default output, Data > Refresh All updates the table and the pivots.

If a refresh stops with `The column '…' of the table wasn't found`, the workbook still has the `Changed column type` step: delete it as in step 4 of New workbook, then refresh again.

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

It analyses the baseline extract again into a temporary folder and compares the result with the stored baseline analysis: each report, `join_check.csv`, and the contents of `photos_pivot.xlsx` when the baseline has one. Each output is compared as a table. For an output that differs, it shows:

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

The baseline is `~/photo-analysis/baseline/` with `extract/` (an extract, never changed) and `analysis/` (its analysis); `PSA_BASELINE` sets another location.

When a change is meant to alter the results, review the differences, then:

```
./psa regress --refresh
```

It asks for confirmation, keeps the previous analysis as `analysis.<timestamp>`, and replaces `baseline/analysis` with the new output. `baseline/extract` is never touched.

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
