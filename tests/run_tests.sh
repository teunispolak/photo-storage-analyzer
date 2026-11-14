#!/bin/zsh
# Run collector, push and verify against generated sample data.
# Usage: tests/run_tests.sh      (from the repository root)
# Exit 0 if all checks pass.

set -uo pipefail

repo="${0:A:h:h}"
work="$repo/tests/_work"
collect=(python3 -I "$repo/collector/collect.py")
fails=0

check() {  # check <description> <expected exit> <command...>
  local desc="$1" expected="$2"; shift 2
  "$@" > "$work/last.out" 2>&1
  local rc=$?
  if [[ $rc -eq $expected ]]; then
    print "ok   $desc"
  else
    print "FAIL $desc (exit $rc, expected $expected)"; sed 's/^/     /' "$work/last.out"
    (( fails++ ))
  fi
}

if [[ -e "$work" ]]; then
  print "tests: $work exists from an earlier run; remove it first"; exit 1
fi
mkdir -p "$work"
python3 -I "$repo/tests/make_fixture.py" "$work/data" > /dev/null || exit 1
d="$work/data"
args=(--scan-root "$d/vol/Photos" --catalog "$d/lr/Test.lrcat")

# Preflight failures
check "preflight: output inside scan root" 1 $collect $args --out "$d/vol/Photos/out"
check "preflight: output inside Dropbox folder" 1 $collect $args --out "$d/vol/x" --dropbox-root "$d/vol"
touch "$d/lr/Test.lrcat.lock"
check "preflight: lock file present" 1 $collect $args --out "$d/out"
mv "$d/lr/Test.lrcat.lock" "$d/lr/Test.lrcat-wal"
check "preflight: -wal file present" 1 $collect $args --out "$d/out"
mv "$d/lr/Test.lrcat-wal" "$work/removed-wal"
check "preflight: missing catalog" 1 $collect --scan-root "$d/vol/Photos" --catalog "$d/lr/None.lrcat" --out "$d/out"

# Complete run
check "collector: complete run" 0 $collect $args --out "$d/out"
run=("$d"/out/*(/N))
if (( ${#run} != 1 )); then
  print "FAIL expected one run folder, found ${#run}"; exit 1
fi
run="${run[1]}"
for f in catalog.lrcat files.csv manifest.json collector.log; do
  check "run folder has $f" 0 test -f "$run/$f"
done
check "files.csv has 6 rows" 0 test "$(( $(wc -l < "$run/files.csv") - 1 ))" -eq 6
check "failed preflight wrote nothing" 0 test ! -e "$d/vol/Photos/out" -a ! -e "$d/vol/x"
check "file names are NFC" 0 python3 -I -c "
import sys, unicodedata
t = open(sys.argv[1], encoding='utf-8').read()
sys.exit(0 if t == unicodedata.normalize('NFC', t) and 'Café.JPG' in t else 1)" "$run/files.csv"

# Push and verify
key="$work/key"; touch "$key"
mkdir -p "$work/incomplete" "$work/recv"; touch "$work/incomplete/files.csv"
check "push: refuses run without manifest" 1 env PHOTO_INTAKE_KEY="$key" zsh "$repo/collector/push.sh" "$work/incomplete" "$work/recv/"
check "push: complete run" 0 env PHOTO_INTAKE_KEY="$key" zsh "$repo/collector/push.sh" "$run" "$work/recv/"
recv="$work/recv/${run:t}"
check "verify: intact run passes" 0 python3 -I "$repo/analysis/verify.py" "$recv"
print x >> "$recv/files.csv"
check "verify: modified files.csv fails" 1 python3 -I "$repo/analysis/verify.py" "$recv"

print
if (( fails )); then print "$fails check(s) failed"; exit 1; fi
print "all checks passed (sample data kept in $work)"
