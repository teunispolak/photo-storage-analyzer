#!/bin/zsh
# Photo storage analysis - turn a received run into reports.
#
# Usage:
#   analysis/run.sh <run_dir> [--out <folder>] [--replace]
#                   [--path-from <prefix> --path-to <prefix>]
#
#   run_dir      received run folder (files.csv, catalog.lrcat, manifest.json)
#   --out        output folder (default: $PSA_ANALYSIS_DIR/<run_id>;
#                with the default, photos_pivot.xlsx is also copied to
#                $PSA_ANALYSIS_DIR/latest/ for the pivot workbook)
#
# PSA_ANALYSIS_DIR   base folder for analysis output
#                    (default: ~/photo-analysis/analysis)
#   --replace    overwrite the generated files in an existing output folder
#   --path-from / --path-to
#                replace a catalog path prefix, for a volume mounted under
#                another name than the catalog expects
#
# Steps: verify -> load -> join -> pivot file -> reports -> summary.
# The run folder is only read: the catalog is read from a working copy in a
# temporary folder (an APFS clone where possible), because opening a
# Lightroom catalog makes SQLite create side files next to it. The temporary
# folder is removed when run.sh ends. Output: analysis.duckdb, join_check.csv,
# photos_pivot.xlsx, reports/*.csv. Nothing is deleted.

set -euo pipefail

repo="${0:A:h:h}"
die() { print -u2 "run: $*"; exit 1; }

run_dir="" out="" replace=0 path_from="" path_to=""
while (( $# )); do
  case "$1" in
    --out)       out="${2:?--out needs a folder}"; shift 2 ;;
    --replace)   replace=1; shift ;;
    --path-from) path_from="${2:?--path-from needs a prefix}"; shift 2 ;;
    --path-to)   path_to="${2:?--path-to needs a prefix}"; shift 2 ;;
    -*)          die "unknown option: $1" ;;
    *)           [[ -z "$run_dir" ]] || die "more than one run folder given"; run_dir="$1"; shift ;;
  esac
done
[[ -n "$run_dir" ]] || die "usage: analysis/run.sh <run_dir> [--out <folder>] [--replace] [--path-from <p> --path-to <p>]"
[[ -n "$path_from" && -z "$path_to" || -z "$path_from" && -n "$path_to" ]] && die "--path-from and --path-to go together"

# Collapse repeated slashes; catalog paths have single ones
while [[ "$path_from" == *//* ]]; do path_from="${path_from//\/\///}"; done
while [[ "$path_to" == *//* ]];   do path_to="${path_to//\/\///}"; done

command -v duckdb  > /dev/null || die "duckdb not found (brew install duckdb)"
command -v python3 > /dev/null || die "python3 not found"
db() { env -u AI_AGENT -u CLAUDECODE duckdb -bail "$@"; }

run_dir="${run_dir:A}"
[[ -d "$run_dir" ]] || die "not a folder: $run_dir"

# 1. Verify
print "run: verifying $run_dir"
python3 -I "$repo/analysis/verify.py" "$run_dir" || die "verification failed, stopping before the join"
[[ -f "$run_dir/catalog.lrcat" ]] || die "run has no catalog copy (collected with --skip-catalog); the join needs one"

run_id=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['run_id'])" "$run_dir/manifest.json")

# Warn when the run was collected with another commit than the one running now
collected=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['collector'].get('git_commit', 'unknown'))" "$run_dir/manifest.json")
current=$(git -C "$repo" rev-parse HEAD 2> /dev/null || print unknown)
if [[ "$collected" != "$current" ]]; then
  print -u2 "run: warning: run collected with commit ${collected:0:7}, analysis runs on ${current:0:7}"
fi
default_out=0
[[ -z "$out" ]] && default_out=1
base="${PSA_ANALYSIS_DIR:-$HOME/photo-analysis/analysis}"
out="${out:-$base/$run_id}"
out="${out:A}"

# Output must not be inside the repository or the run folder
[[ "$out/" == "$repo/"* ]]    && die "output folder is inside the repository: $out"
[[ "$out/" == "$run_dir/"* ]] && die "output folder is inside the run folder: $out"
if [[ -e "$out" && $replace -eq 0 ]]; then
  die "output folder exists: $out (use --replace to overwrite its generated files)"
fi
mkdir -p "$out/reports"
cd "$out"

# Working copy of the catalog, so nothing is written next to the original
work=$(mktemp -d "${TMPDIR:-/tmp}/psa-catalog.XXXXXX") || die "cannot create a temporary folder"
# Removed on exit, and also on Ctrl-C, broken pipe or termination, which
# would otherwise skip the EXIT trap and leave a catalog copy behind
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; exit 130' INT
trap 'rm -rf "$work"; exit 141' PIPE
trap 'rm -rf "$work"; exit 143' TERM HUP
cp -c "$run_dir/catalog.lrcat" "$work/catalog.lrcat" 2> /dev/null \
  || cp "$run_dir/catalog.lrcat" "$work/catalog.lrcat" \
  || die "cannot copy the catalog to $work"

vars=(-c "SET VARIABLE run_dir = '${run_dir//\'/\'\'}'"
      -c "SET VARIABLE catalog = '${work//\'/\'\'}/catalog.lrcat'"
      -c "SET VARIABLE types_csv = '${repo//\'/\'\'}/analysis/types.csv'")
if [[ -n "$path_from" ]]; then
  vars+=(-c "SET VARIABLE path_from = '${path_from//\'/\'\'}'"
         -c "SET VARIABLE path_to = '${path_to//\'/\'\'}'")
fi

# 2-3. Load and join
print "run: loading and joining"
db analysis.duckdb $vars -c ".read $repo/analysis/10_load.sql" -c ".read $repo/analysis/20_join.sql" > /dev/null \
  || die "load or join failed"

# Pivot-ready flat file
db analysis.duckdb -c ".read $repo/analysis/30_pivot.sql" > /dev/null || die "pivot file failed"
latest=""
if (( default_out )); then
  latest="${base:A}/latest"
  mkdir -p "$latest" && cp photos_pivot.xlsx "$latest/photos_pivot.xlsx" || die "copy to $latest failed"
fi

# 4. Reports
for r in "$repo"/analysis/reports/*.sql; do
  db analysis.duckdb -c ".read $r" > /dev/null || die "report failed: ${r:t}"
done

# 5. Summary
print
print "run: $run_id"
db -noheader -list analysis.duckdb -c "
  SELECT '  ' || rpad(metric, 28, ' ') || value FROM join_check
  WHERE metric IN ('disk_files', 'catalog_photos', 'matched', 'disk_only',
                   'catalog_only', 'matched_case_only', 'date_source_mtime')"
db -noheader -list analysis.duckdb -c "
  SELECT '  ' || rpad('disk_tb', 28, ' ') || round(value / 1e12, 3) FROM join_check WHERE metric = 'disk_bytes'"
print
print "run: output in $out"
print "  analysis.duckdb"
print "  join_check.csv"
print "  photos_pivot.xlsx"
if [[ -n "$latest" ]]; then print "  (copied to $latest/photos_pivot.xlsx)"; fi
for f in reports/*.csv; do print "  $f"; done
