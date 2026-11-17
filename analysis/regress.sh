#!/bin/zsh
# Regression check: analyse the baseline run again and compare with the
# stored baseline analysis.
#
# Usage:
#   analysis/regress.sh [--full] [--refresh]
#
#   --full      print the full diff of each output, not only the summary
#   --refresh   after the comparison, replace baseline/analysis with the new
#               output; asks for confirmation; the previous analysis is kept
#               as analysis.<timestamp>; baseline/run is never touched
#
# PSA_BASELINE   baseline folder with run/ and analysis/
#                (default: ~/photo-analysis/baseline)
#
# Compares reports/*.csv, join_check.csv and, when the baseline has one, the
# contents of photos_pivot.xlsx, as tables: per output the number of rows
# that differ and in which columns, with a few examples. Full diffs are
# written to the temporary folder. Ends with one verdict line.
# Exit: 0 no differences, 1 differences, 2 could not run.

set -uo pipefail

repo="${0:A:h:h}"
base="${PSA_BASELINE:-$HOME/photo-analysis/baseline}"
refresh=0 full=()

for arg in "$@"; do
  case "$arg" in
    --refresh) refresh=1 ;;
    --full)    full=(--full) ;;
    *) print -u2 "regress: unknown option: $arg"; exit 2 ;;
  esac
done

fail() { print "regression: could not run: $*"; exit 2; }
db() { env -u AI_AGENT -u CLAUDECODE duckdb -bail "$@"; }

[[ -d "$base/run" ]]      || fail "baseline collection missing: $base/run"
[[ -d "$base/analysis" ]] || fail "baseline analysis folder missing: $base/analysis"
command -v duckdb > /dev/null || fail "duckdb not found"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/psa-regress.XXXXXX") || fail "cannot create a temporary folder"
new="$tmp/analysis"
print "regress: analysing $base/run into $new"
zsh "$repo/analysis/run.sh" "$base/run" --out "$new" > "$tmp/run.log" 2>&1 \
  || { cat "$tmp/run.log"; fail "analysis failed (log: $tmp/run.log)"; }

old="$base/analysis"
differ=()
mkdir -p "$tmp/diff"
compare() {  # compare <label> <baseline csv> <new csv>: summary, adds to differ
  local d="$tmp/diff/${1//\//_}.diff"
  python3 -I "$repo/analysis/compare_csv.py" "$1" "$2" "$3" "$d" $full
  case $? in
    0) ;;
    1) differ+=("$1") ;;
    *) fail "cannot compare $1" ;;
  esac
}

# Reports, file by file, including files on one side only
for r in ${(f)"$( { cd "$old/reports" 2>/dev/null && print -l *.csv(N); cd "$new/reports" && print -l *.csv(N); } | sort -u )"}; do
  if [[ ! -f "$old/reports/$r" ]]; then
    print -r -- "--- reports/$r: only in the new analysis"; differ+=("reports/$r")
  elif [[ ! -f "$new/reports/$r" ]]; then
    print -r -- "--- reports/$r: only in the baseline"; differ+=("reports/$r")
  else
    compare "reports/$r" "$old/reports/$r" "$new/reports/$r"
  fi
done

compare "join_check.csv" "$old/join_check.csv" "$new/join_check.csv"

# Pivot file, compared as data
pivot_csv() {  # pivot_csv <xlsx> <csv>: the sheet "photos" as text
  db -c "LOAD excel; COPY (SELECT * FROM read_xlsx('$1', sheet = 'photos', all_varchar = true)) TO '$2' (HEADER)" > "$tmp/pivot_read.log" 2>&1
}
if [[ -f "$old/photos_pivot.xlsx" ]]; then
  # the new file is the tool's own output: unreadable means the tool is broken
  pivot_csv "$new/photos_pivot.xlsx" "$tmp/pivot_new.csv" \
    || { cat "$tmp/pivot_read.log"; fail "cannot read the new photos_pivot.xlsx"; }
  # the baseline file may be something else, e.g. a workbook with pivots
  if ! pivot_csv "$old/photos_pivot.xlsx" "$tmp/pivot_old.csv"; then
    print -r -- "--- photos_pivot.xlsx: the baseline file is not a tool output (no readable sheet \"photos\")"
    differ+=("photos_pivot.xlsx")
  else
    compare "photos_pivot.xlsx" "$tmp/pivot_old.csv" "$tmp/pivot_new.csv"
  fi
else
  print "regress: baseline has no photos_pivot.xlsx; not compared"
fi

print "regress: new analysis kept in $new"
if (( ${#differ} )); then print "regress: full diffs in $tmp/diff/"; fi
if (( ${#differ} )); then
  print "regression: differences in ${(j:, :)differ}"; code=1
else
  print "regression: no differences"; code=0
fi

if (( refresh )); then
  print -n "regress: replace $old with the new analysis? The current one is kept as analysis.<timestamp>. [y/N] "
  read -r answer
  if [[ "$answer" == [yY] ]]; then
    keep="$base/analysis.$(date +%Y%m%dT%H%M%S)"
    mv "$old" "$keep" && cp -R "$new" "$old" \
      && print "regress: baseline analysis replaced; previous kept in $keep" \
      || { print "regress: refresh failed"; exit 2; }
  else
    print "regress: baseline analysis not changed"
  fi
fi
exit $code
