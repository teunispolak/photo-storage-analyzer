# photo-storage-analyzer

Extracts file and Lightroom Classic catalog metadata on a client's Mac and analyses it with DuckDB on a separate machine, to size and plan a storage migration. It handles metadata only, never the photos.

The repository holds the tool only. Customer data (catalog copies, scan output, reports) stays outside it; `.gitignore` enforces this.

## Quick start

Get the repository on both machines:

```
git clone https://github.com/teunispolak/photo-storage-analyzer
cd photo-storage-analyzer
```

On the client Mac, with Lightroom closed, and client, machine, catalog and scan roots in `~/photo-analysis/settings.env` (see the [Extract runbook](docs/extract.md)):

```
./psa extract
```

On the analysis machine (requires `brew install duckdb`):

```
./psa analyse ~/photo-analysis/extracts/<extract ID>
```

`./psa` first checks the repository against GitHub and updates it if it is behind, then runs the script. If it cannot update (no network, local changes, another branch), it warns and runs the scripts as they are. `./psa status` shows the result without running anything.

This verifies the extract from the inbox `~/photo-analysis/extracts/`, files it in `~/photo-analysis/clients/<client>/<machine>/extracts/`, loads and joins it, and writes the analysis (`analysis.duckdb`, `join_check.csv`, `photos_pivot.xlsx`, `reports/*.csv`) to `~/photo-analysis/clients/<client>/<machine>/analysis/<extract ID>/`. Options: `./psa analyse --help`. Commands: `./psa help`.

## Tests

```
zsh tests/run_tests.sh
```

Builds sample data in `$TMPDIR/photo-storage-analyzer-tests` (or `$TEST_WORK`), outside the repository, and checks the preflight failure cases, a complete extract, verify, the DuckDB load and join, and the reports. Requires `duckdb` (`brew install duckdb`). Remove that folder before running the tests again.

## Docs

- [Extract guide](docs/extract-guide.md): step-by-step instructions for the client
- [Extract runbook](docs/extract.md): extracting on the client Mac
- [Analyse runbook](docs/analyse.md): analysing the received extract on the analysis machine
