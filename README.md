# photo-storage-analyzer

Collects file and Lightroom Classic catalog data on a client's Mac and analyses it with DuckDB on a separate machine, to size and plan a storage migration.

The repository holds the tool only. Customer data (catalog copies, scan output, reports) stays outside it; `.gitignore` enforces this.

## Layout

```
collector/collect.py   client Mac: preflight, catalog copy, scan, manifest
collector/push.sh      client Mac: rsync the run folder to the analysis machine
analysis/verify.py     analysis machine: check a received run against its manifest
analysis/...           DuckDB SQL (to follow)
tests/                 sample data builder and test script
docs/                  runbooks
```

## Quick start

On the client Mac, with Lightroom closed:

```
python3 collector/collect.py --scan-root "/Volumes/<drive>/<photo root>" --catalog "<path>.lrcat"
./collector/push.sh ~/photo-analysis/out/<run_id> intake@<analysis-host>:runs/
```

On the analysis machine:

```
python3 analysis/verify.py <intake folder>/runs/<run_id>
```

## Tests

```
zsh tests/run_tests.sh
```

Builds sample data in `tests/_work/` (git-ignored) and checks the preflight failure cases, a complete run, push and verify. Remove `tests/_work/` before a new run.

## Docs

- [Collection runbook](docs/collection.md): running the collector and push on the client Mac
- [Intake setup](docs/intake-setup.md): one-time setup of the analysis machine and client key, and teardown
