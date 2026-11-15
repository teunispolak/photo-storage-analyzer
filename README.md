# photo-storage-analyzer

Collects file and Lightroom Classic catalog data on a client's Mac and analyses it with DuckDB on a separate machine, to size and plan a storage migration.

The repository holds the tool only. Customer data (catalog copies, scan output, reports) stays outside it; `.gitignore` enforces this.

## Quick start

On the client Mac, with Lightroom closed:

```
python3 collector/collect.py --scan-root "/Volumes/<drive>/<photo root>" --catalog "<path>.lrcat"
```

On the analysis machine (requires `brew install duckdb`):

```
analysis/run.sh <received run folder>
```

This verifies the run, loads and joins it, and writes `analysis.duckdb`, `join_check.csv` and `reports/*.csv` to `~/photo-analysis/analysis/<run_id>/`. Options: `--out`, `--replace`, `--path-from`/`--path-to`; see the header of `analysis/run.sh`.

## Tests

```
zsh tests/run_tests.sh
```

Builds sample data in `$TMPDIR/photo-storage-analyzer-tests` (or `$TEST_WORK`), outside the repository, and checks the preflight failure cases, a complete run, verify, the DuckDB load and join, and the reports. Requires `duckdb` (`brew install duckdb`). Remove that folder before a new run.

## Docs

- [Collector runbook](docs/collector.md): running the collector on the client Mac and the analysis on the analysis machine
