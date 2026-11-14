#!/bin/zsh
# Photo storage assessment - push a completed run to the analysis machine.
#
# Usage:
#   ./push.sh <run_dir> [destination]
#
# destination: user@host:path  (default: $PHOTO_INTAKE_DEST)
#   With rrsync on the receiving side, path is relative to the intake folder,
#   e.g. intake@m5-mbp:runs/
#
# SSH key: $PHOTO_INTAKE_KEY (default: ~/.ssh/photo_intake)
#
# Uses only rsync options supported by macOS openrsync.
# Safe to re-run: an interrupted transfer resumes (--partial).
# Nothing is deleted, locally or remotely.

set -euo pipefail

run_dir="${1:-}"
dest="${2:-${PHOTO_INTAKE_DEST:-}}"
key="${PHOTO_INTAKE_KEY:-$HOME/.ssh/photo_intake}"

die() { print -u2 "push: $*"; exit 1; }

[[ -n "$run_dir" ]] || die "usage: ./push.sh <run_dir> [user@host:path]"
[[ -n "$dest" ]]    || die "no destination: pass it as 2nd argument or set PHOTO_INTAKE_DEST"
[[ -d "$run_dir" ]] || die "not a folder: $run_dir"
[[ -f "$run_dir/manifest.json" ]] || die "no manifest.json in $run_dir: run is incomplete, not pushing"
[[ -f "$key" ]]     || die "SSH key not found: $key"

# Refuse partial files left by an interrupted collector run
if [[ -n "$(find "$run_dir" -name '*.part' -print -quit)" ]]; then
  die "partial files in $run_dir: run is incomplete, not pushing"
fi

run_dir="${run_dir%/}"
print "push: $run_dir -> $dest"
print "push: $(du -sh "$run_dir" | cut -f1) to transfer"

rsync -rtv --partial --timeout=120 \
  -e "ssh -i $key -o IdentitiesOnly=yes -o ServerAliveInterval=30" \
  "$run_dir" "$dest"

print "push: transfer finished."
print "push: on the analysis machine, run: analysis/run.sh <intake>/runs/$(basename "$run_dir")"
print "push: after verification, the local run folder can be removed manually:"
print "      rm -r \"$run_dir\""
