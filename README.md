# photo-storage-analyzer

Collects file and Lightroom Classic catalog data on a client's Mac and analyses it with DuckDB on a separate machine, to size and plan a storage migration.

The repository holds the tool only. Customer data (catalog copies, scan output, reports) stays outside it; `.gitignore` enforces this.

## Layout

```
collector/collect.py   client Mac: preflight, catalog copy, scan, manifest
collector/push.sh      client Mac: rsync the run folder to the analysis machine
analysis/run.sh        analysis machine: verify, load, join, reports in one command
analysis/verify.py     analysis machine: check a received run against its manifest
analysis/types.csv     extension to type group mapping
analysis/10_load.sql   load files.csv and the catalog copy into DuckDB
analysis/20_join.sql   join into the photos table, write join_check.csv
analysis/reports/      one SQL file per report, each writes reports/<name>.csv
tests/                 sample data builder and test script
docs/                  runbooks
```

## Quick start

On the client Mac, with Lightroom closed:

```
python3 collector/collect.py --scan-root "/Volumes/<drive>/<photo root>" --catalog "<path>.lrcat"
./collector/push.sh ~/photo-analysis/out/<run_id> intake@<analysis-host>:runs/
```

On the analysis machine (requires `brew install duckdb`):

```
analysis/run.sh <intake folder>/runs/<run_id>
```

This verifies the run, loads and joins it, and writes `analysis.duckdb`, `join_check.csv` and `reports/*.csv` to `~/photo-analysis/analysis/<run_id>/`. Options: `--out`, `--replace`, `--path-from`/`--path-to`; see the header of `analysis/run.sh`.

## Tests

```
zsh tests/run_tests.sh
```

Builds sample data in `$TMPDIR/photo-storage-analyzer-tests` (or `$TEST_WORK`), outside the repository, and checks the preflight failure cases, a complete run, push, verify, the DuckDB load and join, and the reports. Requires `duckdb` (`brew install duckdb`). Remove that folder before a new run.

## Docs

- [Collection runbook](docs/collection.md): running the collector and push on the client Mac
- [Intake setup](docs/intake-setup.md): one-time setup of the analysis machine and client key, and teardown
