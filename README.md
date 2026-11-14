# photo-storage-analyzer

Collects file and Lightroom Classic catalog data on a client's Mac and analyses it with DuckDB on a separate machine, to size and plan a storage migration.

The repository holds the tool only. Customer data (catalog copies, scan output, reports) stays outside it; `.gitignore` enforces this.

```
collector/collect.py   client Mac: preflight, catalog copy, scan, manifest
collector/push.sh      client Mac: rsync the run folder to the analysis machine
analysis/verify.py     analysis machine: check a received run against its manifest
analysis/...           DuckDB SQL (to follow)
tests/                 sample data builder and test script
```

## Run on the client Mac

Prerequisites: Python 3.9+ (`python3 --version`), the photo drive mounted, SSH key set up (below).

1. Close Lightroom Classic.
2. Run the collector:
   ```
   python3 collector/collect.py \
     --scan-root "/Volumes/<drive>/<photo root>" \
     --catalog "$HOME/Pictures/Lightroom/<name>.lrcat"
   ```
   Output goes to `~/photo-analysis/out/<run_id>/`. Use `--out` to change it. The output folder must not be inside the scan root or a Dropbox folder; preflight checks this.
3. When the log shows `Lightroom may be restarted now`, Lightroom can be reopened. The scan reads metadata only.
4. Push the run:
   ```
   PHOTO_INTAKE_DEST="intake@<m5-tailnet-name>:runs/" ./collector/push.sh ~/photo-analysis/out/<run_id>
   ```
   If the connection drops, run the same command again; it resumes.

On first run, macOS asks to allow Terminal access to the removable volume. Allow it.

Exit codes of `collect.py`: 0 complete, 1 preflight failed (nothing written), 2 run failed (no manifest; the run folder is incomplete and `push.sh` refuses it).

## Verify on the analysis machine

```
python3 analysis/verify.py /Users/intake/runs/<run_id>
```

Checks that the manifest exists and is complete, and that every file matches its checksum.

## Tests

```
zsh tests/run_tests.sh
```

Builds sample data in `tests/_work/` (git-ignored), then checks the preflight failure cases, a complete run, push and verify. The script refuses to run while `tests/_work/` exists; remove it before a new run.

## One-time setup

### Analysis machine (M5)

1. Create a standard (non-admin) user `intake`.
2. System Settings > General > Sharing > Remote Login: on, access for `intake` only.
3. Restrict the client key to rsync into one folder. Install rsync 3 (`brew install rsync`) and check that `rrsync` is available. Then in `/Users/intake/.ssh/authorized_keys`:
   ```
   restrict,command="rrsync /Users/intake/runs" ssh-ed25519 AAAA... photo_intake
   ```
   Without `rrsync`, use `restrict` only; the key can then run commands as `intake`, limited by that account's rights.
4. Tailscale ACL: allow the client Mac to reach the M5 on port 22 only, and nothing else. Example in the tailnet policy file:
   ```
   "grants": [
     { "src": ["tag:client"], "dst": ["tag:intake"], "ip": ["tcp:22"] }
   ]
   ```
   This only restricts traffic if the policy has no allow-all rule.

### Client Mac

```
ssh-keygen -t ed25519 -f ~/.ssh/photo_intake -C photo_intake
```

Add `~/.ssh/photo_intake.pub` to the M5 as in step 3.

## After the engagement

- Turn off Remote Login on the M5, or remove the key from `authorized_keys`.
- Remove the client from the tailnet.
- Remove `~/.ssh/photo_intake*` and `~/photo-analysis/out/` on the client Mac.
- Delete the run folders on the M5 according to the agreed retention period.

## Data handling

The run folder holds customer data: file paths and the full Lightroom catalog (keywords, GPS, face names). In transit it's protected by Tailscale (WireGuard); at rest by FileVault on both machines.
