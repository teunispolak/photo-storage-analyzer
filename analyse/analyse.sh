#!/bin/zsh
# Photo storage analysis - turn a received extract into an analysis.
#
# Usage:
#   ./psa analyse <extract> [--out <folder>] [--replace]
#                 [--path-from <prefix> --path-to <prefix>]
#
#   <extract>     received extract folder (manifest.json, catalog.lrcat, files.csv)
#   --out         output folder; default, filed by the extract's client and machine:
#                   $PSA_CLIENTS_DIR/<client>/<machine>/analysis/<extract ID>/
#                 with photos_pivot.xlsx also copied to
#                   $PSA_CLIENTS_DIR/<client>/<machine>/latest/
#                 for that machine's pivot workbook
#   --replace     overwrite the generated files in an existing output folder
#   --path-from / --path-to
#                 replace a catalog path prefix, for a volume mounted under
#                 another name than the catalog expects
#   -h, --help    show this usage
#
#   PSA_CLIENTS_DIR  base folder for client output (default: ~/photo-analysis/clients)
#
# Steps: verify -> load -> join -> pivot file -> reports -> summary.
# The extract is only read: the catalog is read from a working copy in a
# temporary folder (an APFS clone where possible), because opening a
# Lightroom catalog makes SQLite create side files next to it. The temporary
# folder is removed when analyse.sh ends. Output: analysis.duckdb, join_check.csv,
# photos_pivot.xlsx, reports/*.csv. Nothing is deleted.

set -euo pipefail

repo="${0:A:h:h}"
self="${0:A}"  # inside a function $0 is the function name
die() { print -u2 "analyse: $*"; exit 1; }
# The usage block of the header above is the only copy of the usage text
usage() { sed -n '/^# Usage:/,/^# Steps:/p' "$self" | sed '$d' | sed 's/^# \{0,1\}//'; }
die_usage() { print -u2 "analyse: $*"; print -u2; usage >&2; exit 1; }

extract_dir="" out="" replace=0 path_from="" path_to=""
while (( $# )); do
  case "$1" in
    --out)       out="${2:?--out needs a folder}"; shift 2 ;;
    --replace)   replace=1; shift ;;
    --path-from) path_from="${2:?--path-from needs a prefix}"; shift 2 ;;
    --path-to)   path_to="${2:?--path-to needs a prefix}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die_usage "unknown option: $1" ;;
    *)           [[ -z "$extract_dir" ]] || die "more than one extract given"; extract_dir="$1"; shift ;;
  esac
done
[[ -n "$extract_dir" ]] || die_usage "no extract given"
[[ -n "$path_from" && -z "$path_to" || -z "$path_from" && -n "$path_to" ]] && die "--path-from and --path-to go together"

# Collapse repeated slashes; catalog paths have single ones
while [[ "$path_from" == *//* ]]; do path_from="${path_from//\/\///}"; done
while [[ "$path_to" == *//* ]];   do path_to="${path_to//\/\///}"; done

command -v duckdb  > /dev/null || die "duckdb not found (brew install duckdb)"
command -v python3 > /dev/null || die "python3 not found"
db() { env -u AI_AGENT -u CLAUDECODE duckdb -bail "$@"; }

extract_dir="${extract_dir:A}"
[[ -d "$extract_dir" ]] || die "not a folder: $extract_dir"

# 1. Verify
print "analyse: verifying extract $extract_dir"
python3 -I "$repo/analyse/verify.py" "$extract_dir" || die "verification failed, stopping before the join"
[[ -f "$extract_dir/catalog.lrcat" ]] || die "extract has no catalog copy (made with --skip-catalog); the join needs one"

# Manifest fields; verify has checked the schema, so they are present
# field <key> [<key>...]: value at that path in manifest.json, empty when absent
field() { python3 -I -c "
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    v = v.get(k) if isinstance(v, dict) else None
print('' if v is None else v)" "$extract_dir/manifest.json" "$@"; }
extract_id=$(field extract_id) client=$(field client) machine=$(field machine)
# Labels end up in folder names; the extract checks them, check again before using them
for l in "$client" "$machine"; do
  [[ "$l" =~ '^[a-z0-9][a-z0-9-]{0,39}$' ]] || die "'$l' in the manifest is not a valid label"
done

# Warn when the extract was made with another commit than the one running now
extracted=$(field tool git_commit); extracted="${extracted:-unknown}"
current=$(git -C "$repo" rev-parse HEAD 2> /dev/null || print unknown)
if [[ "$extracted" != "$current" ]]; then
  print -u2 "analyse: warning: extract made with commit ${extracted:0:7}, analysis runs on ${current:0:7}"
fi

default_out=0
if [[ -z "$out" ]]; then
  default_out=1
  clients="${PSA_CLIENTS_DIR:-$HOME/photo-analysis/clients}"
  out="$clients/$client/$machine/analysis/$extract_id"
fi
out="${out:A}"

# Output must not be inside the repository or the extract
[[ "$out/" == "$repo/"* ]]    && die "output folder is inside the repository: $out"
[[ "$out/" == "$extract_dir/"* ]] && die "output folder is inside the extract: $out"
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
cp -c "$extract_dir/catalog.lrcat" "$work/catalog.lrcat" 2> /dev/null \
  || cp "$extract_dir/catalog.lrcat" "$work/catalog.lrcat" \
  || die "cannot copy the catalog to $work"

vars=(-c "SET VARIABLE extract_dir = '${extract_dir//\'/\'\'}'"
      -c "SET VARIABLE catalog = '${work//\'/\'\'}/catalog.lrcat'"
      -c "SET VARIABLE types_csv = '${repo//\'/\'\'}/analyse/types.csv'")
if [[ -n "$path_from" ]]; then
  vars+=(-c "SET VARIABLE path_from = '${path_from//\'/\'\'}'"
         -c "SET VARIABLE path_to = '${path_to//\'/\'\'}'")
fi

# 2-3. Load and join
print "analyse: loading and joining"
db analysis.duckdb $vars -c ".read $repo/analyse/10_load.sql" -c ".read $repo/analyse/20_join.sql" > /dev/null \
  || die "load or join failed"

# Pivot-ready flat file
db analysis.duckdb -c ".read $repo/analyse/30_pivot.sql" > /dev/null || die "pivot file failed"
latest=""
if (( default_out )); then
  latest="${clients:A}/$client/$machine/latest"
  mkdir -p "$latest" && cp photos_pivot.xlsx "$latest/photos_pivot.xlsx" || die "copy to $latest failed"
fi

# 4. Reports
for r in "$repo"/analyse/reports/*.sql; do
  db analysis.duckdb -c ".read $r" > /dev/null || die "report failed: ${r:t}"
done

# 5. Summary
print
print "analyse: extract $extract_id"
print "  client: $client, machine: $machine"
db -noheader -list analysis.duckdb -c "SELECT '  scan root: ' || scan_root FROM scan_roots ORDER BY scan_root"
db -noheader -list analysis.duckdb -c "
  SELECT '  ' || rpad(metric, 28, ' ') || value FROM join_check
  WHERE metric IN ('disk_files', 'catalog_photos', 'matched', 'disk_only',
                   'catalog_only', 'catalog_outside_scan_root',
                   'matched_case_only', 'date_source_mtime')"
db -noheader -list analysis.duckdb -c "
  SELECT '  ' || rpad('disk_tb', 28, ' ') || round(value / 1e12, 3) FROM join_check WHERE metric = 'disk_bytes'"
print
print "analyse: output in $out"
print "  analysis.duckdb"
print "  join_check.csv"
print "  photos_pivot.xlsx"
if [[ -n "$latest" ]]; then print "  (copied to $latest/photos_pivot.xlsx)"; fi
for f in reports/*.csv; do print "  $f"; done
