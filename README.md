# photo-storage-analyzer

Collects file and Lightroom Classic catalog data on a client's Mac and analyses it with DuckDB on a separate machine, to size and plan a storage migration.

The repository holds the tool only. Customer data (catalog copies, scan output, reports) stays outside it; `.gitignore` enforces this.

## Quick start

Get the repository on both machines:

```
git clone https://github.com/teunispolak/photo-storage-analyzer
cd photo-storage-analyzer
```

On the client Mac, with Lightroom closed, and client, machine, catalog and scan roots in `~/photo-analysis/settings.env` (see the [collector runbook](docs/collector.md)):

```
./psa collect
```

On the analysis machine (requires `brew install duckdb`):

```
./psa analyse <received collection>
```

`./psa` first checks the repository against GitHub and updates it if it is behind, then runs the script. If it cannot update (no network, local changes, another branch), it warns and runs the scripts as they are. `./psa status` shows the result without running anything.

This verifies the collection (the folder the collector produced), loads and joins it, and writes the analysis (`analysis.duckdb`, `join_check.csv`, `photos_pivot.xlsx`, `reports/*.csv`) to `~/photo-analysis/clients/<client>/<machine>/analysis/<collection ID>/`. Options: `--out`, `--replace`, `--path-from`/`--path-to`; see the header of `analysis/run.sh`. Commands: see the header of `psa`.

## Tests

```
zsh tests/run_tests.sh
```

Builds sample data in `$TMPDIR/photo-storage-analyzer-tests` (or `$TEST_WORK`), outside the repository, and checks the preflight failure cases, a complete collection, verify, the DuckDB load and join, and the reports. Requires `duckdb` (`brew install duckdb`). Remove that folder before running the tests again.

## Docs

- [Collector runbook](docs/collector.md): collecting on the client Mac
- [Analysis runbook](docs/analysis.md): analysing the received collection on the analysis machine
