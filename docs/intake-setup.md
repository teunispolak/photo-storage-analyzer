# Intake setup

One-time setup so the client Mac can push runs to the analysis machine over SSH on a tailnet, and the teardown afterwards.

## Analysis machine

1. Create a standard (non-admin) user `intake`.
2. System Settings > General > Sharing > Remote Login: on, access for `intake` only.
3. Restrict the client key to rsync into one folder. Install rsync 3 (`brew install rsync`) and check that `rrsync` is available. Then in `/Users/intake/.ssh/authorized_keys`:
   ```
   restrict,command="rrsync /Users/intake/runs" ssh-ed25519 AAAA... photo_intake
   ```
   Without `rrsync`, use `restrict` only; the key can then run commands as `intake`, limited by that account's rights.
4. Tailscale ACL: allow the client Mac to reach the analysis machine on port 22 only, and nothing else. Example in the tailnet policy file:
   ```
   "grants": [
     { "src": ["tag:client"], "dst": ["tag:intake"], "ip": ["tcp:22"] }
   ]
   ```
   This only restricts traffic if the policy has no allow-all rule.

## Client Mac

```
ssh-keygen -t ed25519 -f ~/.ssh/photo_intake -C photo_intake
```

Add `~/.ssh/photo_intake.pub` to the analysis machine as in step 3.

## Protection

In transit, Tailscale (WireGuard) encrypts the traffic. At rest, FileVault on both machines encrypts the data.

## Teardown

- Turn off Remote Login on the analysis machine, or remove the key from `authorized_keys`.
- Remove the client Mac from the tailnet.
- Remove `~/.ssh/photo_intake*` and `~/photo-analysis/out/` on the client Mac.
- Delete the run folders on the analysis machine at the end of the agreed retention period.
