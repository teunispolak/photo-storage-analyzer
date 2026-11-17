#!/bin/zsh
# Run collector, verify and analysis against generated sample data.
# Usage: tests/run_tests.sh      (from the repository root)
#   PYTHON=/usr/bin/python3 tests/run_tests.sh   to test a specific interpreter
# Exit 0 if all checks pass.

set -uo pipefail

repo="${0:A:h:h}"
work="${TEST_WORK:-${TMPDIR:-/tmp}/photo-storage-analyzer-tests}"  # outside the repository
work="${work:a}"  # absolute, no // (macOS TMPDIR ends in /); symlinks kept
py="${PYTHON:-python3}"
collect_raw=($py -I "$repo/collector/collect.py")
collect=($collect_raw --client test --machine m1)  # labels are required; tests of labels use collect_raw
# psa reads ~/photo-analysis/settings.env; tests use no settings file unless they set one
export PSA_SETTINGS=""
fails=0

print "python: $(command -v $py) $($py --version 2>&1)"
print "duckdb: $(command -v duckdb) $(env -u AI_AGENT -u CLAUDECODE duckdb --version 2>&1)"
print

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
$py -I "$repo/tests/make_fixture.py" "$work/data" > /dev/null || exit 1
d="$work/data"
args=(--scan-root "$d/vol/Photos" --catalog "$d/lr/Test.lrcat")

# Guard: no zsh-only commands inside sh -c in this script
check "lint: test script passes the guards" 0 $py -I "$repo/tests/lint_tests.py" "$repo/tests/run_tests.sh"
zprint=print  # assembled, so this script does not contain the pattern itself
printf 'check "x" 0 sh -c "%s -r -- hi | grep -q hi"\n' "$zprint" > "$work/planted.sh"
check "lint: catches a planted print inside sh -c" 1 $py -I "$repo/tests/lint_tests.py" "$work/planted.sh"
lastout=last.out  # assembled, as above
printf 'check "x" 0 grep -q hi "$work/%s"\n' "$lastout" > "$work/planted_last.sh"
check "lint: catches a planted check reading the output file of check" 1 $py -I "$repo/tests/lint_tests.py" "$work/planted_last.sh"

# Test catalog uses WAL mode, as Lightroom catalogs (header bytes 18 and 19 are 2)
check "fixture: test catalog in WAL mode" 0 $py -I -c "
import sys; h = open(sys.argv[1], 'rb').read(20); sys.exit(0 if h[18] == 2 and h[19] == 2 else 1)" "$d/lr/Test.lrcat"

check "fixture: no SQLite side files next to the test catalogs" 0 test -z "$(ls "$d/lr" | grep -E 'lrcat-(wal|shm)')"

# Catalog structure check
chk=($py -I "$repo/collector/check_catalog.py")
check "check_catalog: test catalog has the required structure" 0 $chk "$d/lr/Test.lrcat"
check "check_catalog: counts the virtual copy" 0 sh -c "$py -I '$repo/collector/check_catalog.py' '$d/lr/Test.lrcat' | grep -q 'virtual copies: 1'"
check "check_catalog: --show-roots prints the root folder" 0 sh -c "$py -I '$repo/collector/check_catalog.py' '$d/lr/Test.lrcat' --show-roots | grep -qF '$d/vol/Photos/'"
check "check_catalog: no root paths without --show-roots" 1 sh -c "$py -I '$repo/collector/check_catalog.py' '$d/lr/Test.lrcat' | grep -qF '$d/vol/Photos/'"
$py -I -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE AgLibraryRootFolder (id_local, absolutePath)'); c.commit()" "$work/broken.lrcat"
check "check_catalog: fails on a catalog missing tables" 1 $chk "$work/broken.lrcat"

# Settings file (collector/settings.py), passed with --settings
sd="$work/settings"; mkdir -p "$sd"
# value of a manifest field, as JSON: mq <run folder> <python expression on m>
mq() { $py -I -c "import json,sys; m=json.load(open(sys.argv[1]+'/manifest.json')); print(json.dumps(eval(sys.argv[2])))" "$1" "$2"; }
onerun() { local r=("$1"/*(/N)); print -- "${r[1]:-$1/none}"; }
printf '# client settings\n\nCLIENT="acme"\nMACHINE="anna"\nCATALOG="%s"\nSCAN_ROOT="%s"\n  SCAN_ROOT="%s"  \n' "$d/lr/Multi.lrcat" "$d/vol/Photos" "$d/vol/Extra" > "$sd/two.env"
check "settings: run with labels, catalog and two roots from the file" 0 $collect_raw --settings "$sd/two.env" --out "$work/out_set"
srun=$(onerun "$work/out_set")
check "settings: scan roots taken from the file" 0 test "$(mq "$srun" "m['scan_roots']")" = "[\"$d/vol/Photos\", \"$d/vol/Extra\"]"
check "settings: manifest records file, values and checksum" 0 test "$(mq "$srun" "[m['settings']['file'], m['settings']['used'], m['settings']['replaced_by_command_line'], len(m['settings']['sha256']), len(m['collector']['settings_module_sha256'])]")" = "[\"$sd/two.env\", {\"SCAN_ROOT\": [\"$d/vol/Photos\", \"$d/vol/Extra\"], \"CLIENT\": \"acme\", \"MACHINE\": \"anna\", \"CATALOG\": \"$d/lr/Multi.lrcat\"}, [], 64, 64]"
check "labels: from the settings file into manifest and run folder name" 0 test "$(mq "$srun" "[m['client'], m['machine'], m['run_id'].rsplit('_', 1)[0]]")/${srun:t}" = "[\"acme\", \"anna\", \"acme_anna\"]/$(mq "$srun" "m['run_id']" | tr -d '\"')"
check "settings: collector.log names the file and values" 0 grep -q "SCAN_ROOT from settings file: $d/vol/Extra" "$srun/collector.log"
check "settings: --scan-root replaces all SCAN_ROOT lines" 0 $collect_raw --settings "$sd/two.env" --scan-root "$d/vol/Photos" --machine bob --out "$work/out_set_arg"
srun=$(onerun "$work/out_set_arg")
check "settings: only the command-line root is scanned" 0 test "$(mq "$srun" "[m['scan_roots'], list(m['settings']['used']), m['settings']['replaced_by_command_line']]")" = "[[\"$d/vol/Photos\"], [\"CLIENT\", \"CATALOG\"], [\"SCAN_ROOT\", \"MACHINE\"]]"
check "labels: --machine replaces MACHINE" 0 test "$(mq "$srun" "[m['client'], m['machine']]")" = "[\"acme\", \"bob\"]"
print -r -- 'CATALOG="$HOME/lr/Test.lrcat"' > "$sd/home.env"; print -r -- 'SCAN_ROOT="~/vol/Photos"' >> "$sd/home.env"
check "settings: \$HOME and ~ expanded" 0 env HOME="$d" $collect --settings "$sd/home.env" --out "$work/out_set_home"
check "settings: expanded values in the manifest" 0 test "$(mq "$(onerun "$work/out_set_home")" "m['settings']['used']")" = "{\"SCAN_ROOT\": [\"$d/vol/Photos\"], \"CATALOG\": \"$d/lr/Test.lrcat\"}"
print -r -- "SCAN_ROOT=\"$d/\$USER/Photos\"" > "$sd/var.env"
check "settings: other variables are not expanded" 1 $collect --settings "$sd/var.env" --skip-catalog --out "$work/out_set_var"
cp "$work/last.out" "$sd/var.out"
check "settings: path kept as written" 0 grep -qF "$d/\$USER/Photos" "$sd/var.out"
print -r -- "CATALOG=\"$d/lr/Test.lrcat\"" > "$sd/noroot.env"
check "settings: no scan root anywhere stops the run" 1 $collect --settings "$sd/noroot.env" --out "$work/out_set_bad"
for name content in \
    unquoted "SCAN_ROOT=$d/vol/Photos" \
    unknown_key "SCANROOT=\"$d/vol/Photos\"" \
    catalog_twice "CATALOG=\"$d/lr/Test.lrcat\"\nCATALOG=\"$d/lr/Multi.lrcat\"" \
    empty_value "SCAN_ROOT=\"\"" \
    shell_line "export SCAN_ROOT=\"$d/vol/Photos\""; do
  printf "SCAN_ROOT=\"$d/vol/Photos\"\n$content\n" > "$sd/$name.env"
  check "settings: $name stops the run" 1 $collect --settings "$sd/$name.env" --out "$work/out_set_bad"
  cp "$work/last.out" "$sd/$name.out"
  check "settings: $name is reported with its line number" 0 grep -q 'line [0-9]' "$sd/$name.out"
done
# Labels: required, valid
check "labels: no client stops the run" 1 $collect_raw $args --machine m1 --out "$work/out_set_bad"
cp "$work/last.out" "$sd/noclient.out"
check "labels: says the client is missing" 0 grep -q 'No client' "$sd/noclient.out"
check "labels: no machine stops the run" 1 $collect_raw $args --client test --out "$work/out_set_bad"
for bad in Acme 'a b' -acme 'acme/x' "$(printf 'a%.0s' {1..41})"; do
  check "labels: invalid client '$bad' stops the run" 1 $collect_raw $args --client="$bad" --machine m1 --out "$work/out_set_bad"
done
printf 'CLIENT="Acme Photo"\n' > "$sd/badlabel.env"
check "labels: invalid CLIENT in the settings file stops the run" 1 $collect $args --settings "$sd/badlabel.env" --out "$work/out_set_bad"
cp "$work/last.out" "$sd/badlabel.out"
check "labels: settings file label error gives the line" 0 grep -q 'line 1: CLIENT' "$sd/badlabel.out"
check "settings: missing file stops the run" 1 $collect --settings "$sd/none.env" --out "$work/out_set_bad"
check "settings: stopped runs wrote nothing" 0 test ! -e "$work/out_set_bad"
check "check_catalog: CATALOG from the settings file" 0 sh -c "$py -I '$repo/collector/check_catalog.py' --settings '$sd/two.env' | grep -qF 'CATALOG from settings file: $d/lr/Multi.lrcat'"
check "check_catalog: argument replaces CATALOG" 0 sh -c "$py -I '$repo/collector/check_catalog.py' '$d/lr/Test.lrcat' --settings '$sd/two.env' | grep -q 'CATALOG from the command line'"
check "check_catalog: bad settings file fails" 1 $chk --settings "$sd/unknown_key.env"

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
check "settings: run without a file says so" 0 grep -q 'Settings file: none' "$run/collector.log"
check "manifest: settings null without a file" 0 test "$(mq "$run" "m['settings']")" = null
for f in catalog.lrcat files.csv manifest.json collector.log; do
  check "run folder has $f" 0 test -f "$run/$f"
done
check "files.csv has 9 rows" 0 test "$(( $(wc -l < "$run/files.csv") - 1 ))" -eq 9
check "failed preflight wrote nothing" 0 test ! -e "$d/vol/Photos/out" -a ! -e "$d/vol/x"
check "file names are NFC" 0 $py -I -c "
import sys, unicodedata
t = open(sys.argv[1], encoding='utf-8').read()
sys.exit(0 if t == unicodedata.normalize('NFC', t) and 'Café.JPG' in t else 1)" "$run/files.csv"

# Scan root through a symlink: paths differ from the catalog's, collector must warn
ln -s "$d/vol" "$work/vol_link"
check "collector: warns when scan root does not match catalog root" 0 sh -c \
  "$py -I '$repo/collector/collect.py' --client test --machine m1 --scan-root '$work/vol_link/Photos' --catalog '$d/lr/Test.lrcat' --out '$work/out_link' 2>&1 | grep -q 'does not overlap'"
check "collector: no warning when scan root matches" 1 grep -q 'does not overlap' "$run/collector.log"

# macOS only: creation date and hidden flag
if [[ "$(uname)" == Darwin ]]; then
  check "macOS: btime filled for every row" 0 $py -I -c "
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding='utf-8')))
sys.exit(0 if rows and all(r['btime'] for r in rows) else 1)" "$run/files.csv"
  check "macOS: hidden flag detected" 0 $py -I -c "
import csv, sys
rows = {r['name']: r for r in csv.DictReader(open(sys.argv[1], encoding='utf-8'))}
sys.exit(0 if rows['flagged.jpg']['hidden'] == '1' and rows['root.txt']['hidden'] == '0' else 1)" "$run/files.csv"
fi

# Analysis (run.sh: verify, load, join, reports), output outside the run folder
if ! command -v duckdb > /dev/null; then
  print "FAIL duckdb not found"; (( fails++ ))
else
  runsh=(zsh "$repo/analysis/run.sh")
  ana="$work/ana"
  before=$(cd "$run" && ls -lR)
  check "run.sh: complete run" 0 $runsh "$run" --out "$ana"
  check "run.sh: run folder left unchanged" 0 test "$(cd "$run" && ls -lR)" = "$before"
  check "run.sh: no SQLite side files in the run folder" 0 test -z "$(ls "$run" | grep -E 'lrcat-(wal|shm)')"
  mkdir -p "$work/tmp_normal" "$work/tmp_pipe"
  check "run.sh: working copy removed after a normal run" 0 sh -c "TMPDIR='$work/tmp_normal' zsh '$repo/analysis/run.sh' '$run' --out '$work/ana_tmpcheck' > /dev/null 2>&1 && test -z \"\$(ls '$work/tmp_normal')\""
  TMPDIR="$work/tmp_pipe" zsh "$repo/analysis/run.sh" "$run" --out "$work/ana_pipe" 2>&1 | grep -q 'loading and joining'
  sleep 1
  check "run.sh: working copy removed when output is cut off (broken pipe)" 0 test -z "$(ls "$work/tmp_pipe")"
  check "run.sh: refuses existing output without --replace" 1 $runsh "$run" --out "$ana"
  check "run.sh: --replace overwrites" 0 $runsh "$run" --out "$ana" --replace
  check "run.sh: refuses output inside the run folder" 1 $runsh "$run" --out "$run/x"
  check "run.sh: refuses output inside the repository" 1 $runsh "$run" --out "$repo/x"
  check "run.sh: --path-from needs --path-to" 1 $runsh "$run" --out "$work/ana_x" --path-from /a
  check "run.sh: join_check.csv written" 0 test -f "$ana/join_check.csv"
  check "run.sh: second run gives identical reports" 0 sh -c "zsh '$repo/analysis/run.sh' '$run' --out '$work/ana2' > /dev/null 2>&1 && diff -r '$ana/reports' '$work/ana2/reports' && diff '$ana/join_check.csv' '$work/ana2/join_check.csv'"

  expected=(
    disk_files 9  catalog_photos 4  catalog_attached 2  catalog_duplicate_keys 0
    virtual_copies_excluded 1  matched 5  matched_photo 3  matched_attached 2
    disk_only 4  catalog_only 1  catalog_outside_scan_root 0  matched_case_only 1  catalog_paths_nfc_changed 1
    catalog_paths_prefix_mapped 0  date_source_catalog 5  date_source_mtime 5  date_source_none 0
  )
  metric_is() { $py -I -c "
import csv, sys
m = {r['metric']: r['value'] for r in csv.DictReader(open(sys.argv[1]))}
sys.exit(0 if m.get(sys.argv[2]) == sys.argv[3] else (print(m.get(sys.argv[2])) or 1))" "$@"; }
  for metric value in $expected; do
    check "join: $metric = $value" 0 metric_is "$ana/join_check.csv" $metric $value
  done
  q() { env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list "$ana/analysis.duckdb" -c "$1"; }
  check "join: JPEG of RAW+JPEG pair is an attached file" 0 test "$(q "SELECT catalog_role FROM photos WHERE name = 'IMG_0100.JPG'")" = attached
  check "join: catalog roles are photo and attached" 0 test "$(q "SELECT string_agg(DISTINCT catalog_role, ',' ORDER BY catalog_role) FROM photos")" = "attached,photo"
  check "join: types for metadata and thumbnails" 0 test "$(q "SELECT string_agg(ext || ':' || type_group, ' ' ORDER BY ext) FROM types WHERE ext IN ('aae','pp3','thm','xmp')")" = "aae:metadata pp3:metadata thm:thumbnail xmp:metadata"
  check "join: no master or sidecar left in values or metric names" 0 test "$(q "SELECT count(*) FROM (SELECT catalog_role AS v FROM photos UNION ALL SELECT type_group FROM photos UNION ALL SELECT metric FROM join_check) WHERE v ILIKE '%master%' OR v ILIKE '%sidecar%'")" = 0
  check "join: raw capture year from catalog" 0 test "$(q "SELECT capture_year || '/' || date_source FROM photos WHERE name = 'IMG_0001.CR2'")" = "2014/catalog"
  check "join: type groups" 0 test "$(q "SELECT string_agg(name || ':' || type_group, ' ' ORDER BY name) FROM photos WHERE name IN ('.DS_Store','IMG_0001.xmp','IMG_0100.NEF','root.txt')")" = ".DS_Store:system IMG_0001.xmp:metadata IMG_0100.NEF:raw root.txt:other"

  check "join: prefix mapping run" 0 $runsh "$run" --out "$work/ana_mapped" --path-from "$d/vol/Photos/" --path-to /elsewhere/
  check "join: prefix mapping applied to all catalog paths" 0 metric_is "$work/ana_mapped/join_check.csv" catalog_paths_prefix_mapped 6
  check "join: prefix mapping leaves nothing matched" 0 metric_is "$work/ana_mapped/join_check.csv" matched 0
  check "join: double slash in --path-from is collapsed" 0 $runsh "$run" --out "$work/ana_slash" --path-from "${d%/*}//${d:t}/vol//Photos/" --path-to /elsewhere/
  check "join: double slash mapping applied to all catalog paths" 0 metric_is "$work/ana_slash/join_check.csv" catalog_paths_prefix_mapped 6

  # Required catalog columns (check_catalog.py) are exactly what the load needs
  variants="$work/variants"
  cols=("${(@f)$($py -I "$repo/tests/catalog_variants.py" "$d/lr/Test.lrcat" "$repo/collector/check_catalog.py" "$variants")}")
  load_with() {  # load_with <catalog> <out_dir>: load and join a run copy that uses <catalog>
    local rc="$2/run"; mkdir -p "$rc"
    cp "$run/files.csv" "$run/manifest.json" "$rc/"; cp "$1" "$rc/catalog.lrcat"
    (cd "$2" && env -u AI_AGENT -u CLAUDECODE duckdb -bail analysis.duckdb \
      -c "SET VARIABLE run_dir = '$rc'" -c "SET VARIABLE types_csv = '$repo/analysis/types.csv'" \
      -c ".read $repo/analysis/10_load.sql" -c ".read $repo/analysis/20_join.sql") > /dev/null 2>&1
  }
  check "catalog columns: sample catalog still has no SQLite side files" 0 test -z "$(ls "$d/lr" | grep -E 'lrcat-(wal|shm)')"
  check "catalog columns: minimal catalog loads" 0 load_with "$variants/minimal.lrcat" "$variants/minimal"
  check "catalog columns: minimal catalog gives the same join" 0 diff "$ana/join_check.csv" "$variants/minimal/join_check.csv"
  check "catalog columns: one variant per required column" 0 test ${#cols} -eq 17
  for c in $cols; do
    check "catalog columns: load fails ${c%.lrcat}" 1 load_with "$variants/$c" "$variants/${c%.lrcat}"
  done

  for r in "$repo"/analysis/reports/*.sql; do
    check "reports: ${r:t:r}.csv written" 0 test -f "$ana/reports/${r:t:r}.csv"
  done
  # Reconciliation report
  check "reconciliation: levels add up and match join_check" 0 $py -I "$repo/tests/check_reconciliation.py" "$ana"
  check "reconciliation: all catalog files outside the scan root (prefix mapping)" 0 $py -I "$repo/tests/check_reconciliation.py" "$work/ana_mapped"
  check "reconciliation: mapped run counts 6 catalog entries outside the scan root" 0 test "$(grep ',catalog entries outside the scan root (not analysed),' "$work/ana_mapped/reports/reconciliation.csv" | cut -d, -f5)" = 6
  check "scope: mapped run has no catalog files in scope" 0 metric_is "$work/ana_mapped/join_check.csv" catalog_only 0
  check "scope: mapped run counts them outside the scan root" 0 metric_is "$work/ana_mapped/join_check.csv" catalog_outside_scan_root 6

  # Pivot file (photos_pivot.xlsx)
  dq() { env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list "$@"; }
  check "pivot: photos_pivot.xlsx written" 0 test -f "$ana/photos_pivot.xlsx"
  contract_cols=$($py -I -c "import csv,sys; print(','.join(r['column'] for r in csv.DictReader(open(sys.argv[1]))))" "$repo/analysis/pivot_columns.csv")
  contract_types=$($py -I -c "import csv,sys; print(','.join(r['type'] for r in csv.DictReader(open(sys.argv[1]))))" "$repo/analysis/pivot_columns.csv")
  check "pivot: xlsx columns and order match the contract" 0 test "$(dq -c "LOAD excel; SELECT string_agg(column_name, ',') FROM (DESCRIBE SELECT * FROM read_xlsx('$ana/photos_pivot.xlsx', sheet = 'photos', all_varchar = true))")" = "$contract_cols"
  check "pivot: column types match the contract" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT string_agg(column_type, ',') FROM (DESCRIBE photos_pivot)")" = "$contract_types"
  check "pivot: one row per file" 0 test "$(dq -c "LOAD excel; SELECT count(*) FROM read_xlsx('$ana/photos_pivot.xlsx', sheet = 'photos', all_varchar = true)")" = 10
  check "pivot: files in the scan root are (root)" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT top_folder || '|' || folder FROM photos_pivot WHERE name = 'root.txt'")" = "(root)|(root)"
  check "pivot: folder is relative, folder_path is full" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT top_folder || '|' || folder || '|' || (folder_path = '$d/vol/Photos/2014/Trip') FROM photos_pivot WHERE name = 'IMG_0001.CR2'")" = "2014|2014/Trip|true"
  check "pivot: source values" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT string_agg(source || '=' || n, ' ' ORDER BY source) FROM (SELECT source, count(*) AS n FROM photos_pivot GROUP BY 1)")" = "catalog only=1 filesystem and catalog=5 filesystem only=4"
  check "scope: mapped run has only scanned files as rows" 0 test "$(dq "$work/ana_mapped/analysis.duckdb" -c "SELECT count(*) || '/' || count(*) FILTER (WHERE source = 'catalog only') FROM photos_pivot")" = "9/0"
  check "pivot: scan_root column" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT string_agg(DISTINCT scan_root, ',') FROM photos_pivot")" = "$d/vol/Photos"
  check "pivot: every row has the scan root" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT count(*) FROM photos_pivot WHERE scan_root IS NULL")" = 0

  rq() { env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list -c "$1"; }

  # Multiple scan roots: a second tree, Extra, with its own catalog root (Multi.lrcat, from make_fixture.py)
  check "multi: nested scan roots refused" 1 $collect --scan-root "$d/vol/Photos" --scan-root "$d/vol/Photos/2014" --catalog "$d/lr/Multi.lrcat" --out "$work/out_nested"
  cp "$work/last.out" "$work/nested.out"
  check "multi: says the roots are nested" 0 grep -q 'Scan roots are nested' "$work/nested.out"
  check "multi: same scan root twice refused" 1 $collect --scan-root "$d/vol/Photos" --scan-root "$d/vol/Photos/" --catalog "$d/lr/Multi.lrcat" --out "$work/out_twice"
  cp "$work/last.out" "$work/twice.out"
  check "multi: says the root is given twice" 0 grep -q 'Scan root given twice' "$work/twice.out"
  check "multi: refused runs wrote nothing" 0 test ! -e "$work/out_nested" -a ! -e "$work/out_twice"
  check "multi: collector run with two roots" 0 $collect --scan-root "$d/vol/Photos" --scan-root "$d/vol/Extra" --catalog "$d/lr/Multi.lrcat" --out "$work/out_multi"
  mrun=("$work"/out_multi/*(/N)); mrun="${mrun[1]:-$work/out_multi/none}"
  check "multi: manifest lists both roots with per-root counts" 0 $py -I -c "
import json, sys
m = json.load(open(sys.argv[1])); d = sys.argv[2]
roots = [d + '/vol/Photos', d + '/vol/Extra']
pr = m['files']['per_root']
sys.exit(0 if m['scan_roots'] == roots and [pr[r]['rows'] for r in roots] == [9, 2]
         and pr[roots[1]]['size_bytes'] == 5 and 'scan_root' not in m else 1)" "$mrun/manifest.json" "$d"
  check "multi: files.csv rel_path relative to its own root" 0 $py -I -c "
import csv, sys
r = {x['name']: x for x in csv.DictReader(open(sys.argv[1], encoding='utf-8'))}['X1.CR2']
sys.exit(0 if (r['rel_path'], r['top_folder'], r['scan_root']) == ('2020/X1.CR2', '2020', sys.argv[2]) else 1)" "$mrun/files.csv" "$d/vol/Extra"
  check "multi: no overlap warning when every root is a catalog root" 1 grep -q 'does not overlap' "$mrun/collector.log"
  check "multi: analysis" 0 $runsh "$mrun" --out "$work/ana_multi"
  for metric value in disk_files 11 matched 6 disk_only 5 catalog_only 1 catalog_outside_scan_root 0; do
    check "multi: join $metric = $value" 0 metric_is "$work/ana_multi/join_check.csv" $metric $value
  done
  check "multi: reconciliation adds up" 0 $py -I "$repo/tests/check_reconciliation.py" "$work/ana_multi"
  check "multi: pivot rows per scan root" 0 test "$(dq "$work/ana_multi/analysis.duckdb" -c "SELECT string_agg(scan_root || '=' || n, ' ' ORDER BY scan_root) FROM (SELECT scan_root, count(*) AS n FROM photos_pivot GROUP BY 1)")" = "$d/vol/Extra=2 $d/vol/Photos=10"
  check "multi: folder relative to its own scan root" 0 test "$(dq "$work/ana_multi/analysis.duckdb" -c "SELECT top_folder || '|' || folder || '|' || source || '|' || capture_year FROM photos_pivot WHERE name = 'X1.CR2'")" = "2020|2020|filesystem and catalog|2020"
  check "multi: volume_by_scan_root per root and source" 0 test "$(rq "SELECT string_agg(regexp_extract(scan_root, '[^/]+\$') || ':' || source || '=' || files || '/' || bytes, ' ' ORDER BY scan_root, source) FROM read_csv('$work/ana_multi/reports/volume_by_scan_root.csv', all_varchar = true)")" = "Extra:filesystem and catalog=1/2 Extra:filesystem only=1/3 Photos:catalog only=1/0 Photos:filesystem and catalog=5/11137 Photos:filesystem only=4/16"
  check "multi: volume_by_folder split by scan root" 0 test "$(rq "SELECT count(DISTINCT scan_root) FROM read_csv('$work/ana_multi/reports/volume_by_folder.csv', all_varchar = true)")" = 2

  # Runs collected before multiple scan roots: no scan_root column, single scan_root in the manifest
  cp -R "$run" "$work/old_format"
  $py -I -c "
import csv, hashlib, json, sys
run = sys.argv[1]
rows = list(csv.reader(open(run + '/files.csv', newline='', encoding='utf-8')))
i = rows[0].index('scan_root')
csv.writer(open(run + '/files.csv', 'w', newline='', encoding='utf-8'), lineterminator='\n').writerows(r[:i] + r[i+1:] for r in rows)
m = json.load(open(run + '/manifest.json'))
m['scan_root'] = m.pop('scan_roots')[0]
m['files'].pop('per_root'); m['files']['columns'].remove('scan_root')
m['files']['sha256'] = hashlib.sha256(open(run + '/files.csv', 'rb').read()).hexdigest()
json.dump(m, open(run + '/manifest.json', 'w'), indent=2)" "$work/old_format"
  check "old format: files.csv has no scan_root column" 1 grep -q 'scan_root' "$work/old_format/files.csv"
  check "old format: analysis" 0 $runsh "$work/old_format" --out "$work/ana_oldformat"
  check "old format: same join check and reports as the new format" 0 sh -c "diff '$ana/join_check.csv' '$work/ana_oldformat/join_check.csv' && diff -r '$ana/reports' '$work/ana_oldformat/reports'"
  check "old format: pivot rows carry the single scan root" 0 test "$(dq "$work/ana_oldformat/analysis.duckdb" -c "SELECT string_agg(DISTINCT scan_root, ',') || '/' || count(*) FROM photos_pivot")" = "$d/vol/Photos/10"

  # Hints, with planted cases on a copy of the database
  mkdir -p "$work/hints" && cp "$ana/analysis.duckdb" "$work/hints/"
  check "pivot: hints computed on planted cases" 0 sh -c "cd '$work/hints' && env -u AI_AGENT -u CLAUDECODE duckdb -bail analysis.duckdb -c \"
    INSERT INTO photos (path, parent, name, ext, size_bytes, on_disk, in_catalog, type_group, catalog_role) VALUES
      ('$d/vol/Photos/2019/IMG_9.CR2', '2019', 'IMG_9.CR2', 'cr2', 25000000, true, false, 'raw', NULL),
      ('$d/vol/Photos/2015/IMG_8.CR2', '2015', 'IMG_8.CR2', 'cr2', 24000000, true, false, 'raw', NULL),
      ('$d/vol/Photos/2015/IMG_8.dng', '2015', 'IMG_8.dng', 'dng', 26000000, true, true, 'raw', 'photo');
    INSERT INTO catalog_entries (file_id, catalog_role, path, match_key, in_scope) VALUES
      (900, 'photo', '/old tree/2018/IMG_9.CR2', '/old tree/2018/img_9.cr2', false)\" -c '.read $repo/analysis/30_pivot.sql' > /dev/null"
  check "pivot: moved? also when the name is only outside the scan root" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT hint || '|' || catalog_folder FROM photos_pivot WHERE name = 'IMG_9.CR2' AND source = 'filesystem only'")" = "moved?|/old tree/2018"
  check "pivot: raw next to its DNG gets dng original?" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT hint FROM photos_pivot WHERE name = 'IMG_8.CR2'")" = "dng original?"
  check "pivot: files without a cause get no hint" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT count(*) FROM photos_pivot WHERE hint IS NOT NULL")" = 2

  # Default output: filed by client and machine, latest per machine
  cl_dir="$work/clients"; runsh_c=(env PSA_CLIENTS_DIR="$cl_dir" zsh "$repo/analysis/run.sh")
  check "clients: default output for test/m1" 0 $runsh_c "$run"
  cp "$work/last.out" "$work/clients_m1.out"
  check "clients: analysis filed under client/machine/analysis/run" 0 test -f "$cl_dir/test/m1/analysis/${run:t}/photos_pivot.xlsx"
  check "clients: latest per machine holds this run's pivot file" 0 cmp -s "$cl_dir/test/m1/analysis/${run:t}/photos_pivot.xlsx" "$cl_dir/test/m1/latest/photos_pivot.xlsx"
  check "clients: summary names client and machine" 0 grep -q 'client: test, machine: m1' "$work/clients_m1.out"
  cp "$cl_dir/test/m1/latest/photos_pivot.xlsx" "$work/latest_m1.xlsx"
  check "clients: second machine of another client" 0 $runsh_c "$(onerun "$work/out_set")"
  check "clients: its own latest" 0 test -f "$cl_dir/acme/anna/latest/photos_pivot.xlsx"
  check "clients: other machine's latest unchanged" 0 cmp -s "$work/latest_m1.xlsx" "$cl_dir/test/m1/latest/photos_pivot.xlsx"
  check "clients: --out leaves latest alone" 0 sh -c "PSA_CLIENTS_DIR='$work/clients2' zsh '$repo/analysis/run.sh' '$run' --out '$work/ana_noLatest' > /dev/null 2>&1 && test -f '$work/ana_noLatest/photos_pivot.xlsx' && test ! -e '$work/clients2'"
  check "clients: --client differing from the manifest stops" 1 $runsh_c "$run" --client other --replace
  check "clients: PSA_ANALYSIS_DIR set stops" 1 env PSA_ANALYSIS_DIR="$work/base" zsh "$repo/analysis/run.sh" "$run" --out "$work/ana_oldvar"
  check "clients: PSA_ANALYSIS_DIR stop wrote nothing" 0 test ! -e "$work/ana_oldvar" -a ! -e "$work/base"
  # A run collected before labels: none in the manifest
  cp -R "$run" "$work/unlabelled"
  $py -I -c "
import json, sys
p = sys.argv[1] + '/manifest.json'; m = json.load(open(p))
del m['client'], m['machine']; json.dump(m, open(p, 'w'), indent=2)" "$work/unlabelled"
  check "clients: unlabelled run without --client/--machine stops" 1 $runsh_c "$work/unlabelled"
  check "clients: unlabelled run filed by --client and --machine" 0 $runsh_c "$work/unlabelled" --client old --machine m5
  check "clients: filed under old/m5" 0 test -f "$cl_dir/old/m5/analysis/${run:t}/photos_pivot.xlsx" -a -f "$cl_dir/old/m5/latest/photos_pivot.xlsx"
  check "clients: invalid --machine stops" 1 $runsh_c "$work/unlabelled" --client old --machine 'M 5' --replace
  check "clients: unlabelled run with --out needs no labels" 0 $runsh_c "$work/unlabelled" --out "$work/ana_unlabelled"

  # Regression check (./psa regress), against a baseline made from the test run
  rg() {  # rg <baseline> [args...]: run regress, keep output in $work/rg.out
    local b="$1"; shift
    PSA_BASELINE="$b" zsh "$repo/analysis/regress.sh" "$@" > "$work/rg.out" 2>&1
  }
  verdict() { grep '^regression:' "$work/rg.out"; }
  mkbase() { rm -rf "$1"; mkdir -p "$1"; cp -R "$run" "$1/run"; cp -R "$ana" "$1/analysis"; }
  mkbase "$work/bl"
  check "regress: unchanged baseline gives exit 0" 0 rg "$work/bl"
  check "regress: verdict no differences" 0 test "$(verdict)" = "regression: no differences"
  check "regress: pivot file compared" 1 grep -q "not compared" "$work/rg.out"

  mkbase "$work/bl"; sed -i.bak 's/^\(.*\),raw,/\1,raw_x,/' "$work/bl/analysis/reports/volume_by_type.csv"; rm -f "$work/bl/analysis/reports/volume_by_type.csv.bak"
  check "regress: changed report gives exit 1" 1 rg "$work/bl"
  check "regress: verdict names the report" 0 test "$(verdict)" = "regression: differences in reports/volume_by_type.csv"
  check "regress: summary counts rows and names the column" 0 sh -c "grep -q '^--- reports/volume_by_type.csv: 1 of [0-9]* rows differ' '$work/rg.out' && grep -Eq '^ +type_group +1 row\$' '$work/rg.out'"
  check "regress: summary shows examples and the diff file" 0 sh -c "grep -q 'examples (full diff: ' '$work/rg.out' && grep -q '^ *-.*,raw_x,' '$work/rg.out'"
  check "regress: full diff written to a file" 0 sh -c "f=\$(sed -n 's/.*examples (full diff: \(.*\)):/\1/p' '$work/rg.out' | head -1); test -s \"\$f\" && grep -q '^@@' \"\$f\""
  check "regress: no full diff on screen by default" 1 grep -q '^@@' "$work/rg.out"
  check "regress: --full prints the full diff" 1 sh -c "PSA_BASELINE='$work/bl' zsh '$repo/analysis/regress.sh' --full > '$work/rg.out' 2>&1"
  check "regress: --full output has the diff" 0 grep -q '^@@' "$work/rg.out"

  # two columns changed in the same rows, as with a rename
  mkbase "$work/bl"; $py -I -c "
import csv, sys
p = sys.argv[1]; rows = list(csv.reader(open(p, newline='')))
h = rows[0]; r, t = h.index('catalog_role'), h.index('type_group')
for row in rows[1:]: row[r] = 'master'; row[t] = 'old_' + row[t]
csv.writer(open(p, 'w', newline=''), lineterminator='\n').writerows(rows)" "$work/bl/analysis/reports/missing_from_disk.csv"
  check "regress: two changed columns give exit 1" 1 rg "$work/bl"
  check "regress: summary names both columns, nothing else" 0 sh -c "awk '/^--- reports\/missing_from_disk.csv/{p=1;next} /^      examples/{p=0} p' '$work/rg.out' | sed -E 's/ *[0-9,]+ rows?\$//; s/^ *//' | sort | tr '\n' ' ' | grep -qx 'catalog_role type_group '"

  # a column added in the new analysis, existing values unchanged
  mkbase "$work/bl"; $py -I -c "
import csv, sys
p = sys.argv[1]; rows = list(csv.reader(open(p, newline='')))
i = rows[0].index('dated_by_mtime'); rows = [r[:i] + r[i+1:] for r in rows]
csv.writer(open(p, 'w', newline=''), lineterminator='\\n').writerows(rows)" "$work/bl/analysis/reports/volume_by_year.csv"
  check "regress: added column gives exit 1" 1 rg "$work/bl"
  check "regress: names the added column" 0 grep -q '^ *columns: added dated_by_mtime' "$work/rg.out"
  check "regress: added column alone changes no existing values" 0 grep -q '^--- reports/volume_by_year.csv: no differences in the existing columns' "$work/rg.out"

  # a column and rows removed at once: rows compared on the shared columns
  mkbase "$work/bl"; $py -I -c "
import csv, sys
p = sys.argv[1]; rows = list(csv.reader(open(p, newline='')))
rows[0].append('old_col'); rows = [rows[0]] + [r + ['x'] for r in rows[1:]] + [r + ['x'] for r in rows[1:3]]
csv.writer(open(p, 'w', newline=''), lineterminator='\\n').writerows(rows)" "$work/bl/analysis/reports/volume_by_type.csv"
  check "regress: removed column and rows give exit 1" 1 rg "$work/bl"
  check "regress: counts only the removed rows" 0 grep -q '^--- reports/volume_by_type.csv: .* 2 only in the baseline, 0 only in the new' "$work/rg.out"
  check "regress: names the removed column" 0 grep -q '^ *columns: removed old_col' "$work/rg.out"

  # rows added and removed
  mkbase "$work/bl"; sed -i.bak '$d' "$work/bl/analysis/reports/volume_by_type.csv"; rm -f "$work/bl/analysis/reports/volume_by_type.csv.bak"
  check "regress: row added in the new analysis gives exit 1" 1 rg "$work/bl"
  check "regress: says 1 only in the new" 0 grep -q '^--- reports/volume_by_type.csv: .* 0 only in the baseline, 1 only in the new' "$work/rg.out"
  mkbase "$work/bl"; tail -1 "$work/bl/analysis/reports/volume_by_type.csv" >> "$work/bl/analysis/reports/volume_by_type.csv"
  check "regress: row removed in the new analysis gives exit 1" 1 rg "$work/bl"
  check "regress: says 1 only in the baseline" 0 grep -q '^--- reports/volume_by_type.csv: .* 1 only in the baseline, 0 only in the new' "$work/rg.out"

  # same rows, other order
  mkbase "$work/bl"; $py -I -c "
import sys
p = sys.argv[1]; lines = open(p).read().splitlines(); body = lines[1:]; body.reverse()
open(p, 'w').write('\n'.join([lines[0]] + body) + '\n')" "$work/bl/analysis/reports/volume_by_type.csv"
  check "regress: reordered rows give exit 1" 1 rg "$work/bl"
  check "regress: reordered rows are reported as such" 0 grep -q 'volume_by_type.csv: same [0-9]* rows, in a different order' "$work/rg.out"


  mkbase "$work/bl"; print "a,b" > "$work/bl/analysis/reports/extra.csv"
  check "regress: report only in the baseline gives exit 1" 1 rg "$work/bl"
  check "regress: says only in the baseline" 0 grep -q "reports/extra.csv: only in the baseline" "$work/rg.out"

  mkbase "$work/bl"; rm "$work/bl/analysis/reports/size_buckets.csv"
  check "regress: report only in the new analysis gives exit 1" 1 rg "$work/bl"
  check "regress: says only in the new analysis" 0 grep -q "reports/size_buckets.csv: only in the new analysis" "$work/rg.out"

  mkbase "$work/bl"; sed -i.bak 's/^matched,5$/matched,6/' "$work/bl/analysis/join_check.csv"; rm -f "$work/bl/analysis/join_check.csv.bak"
  check "regress: changed join check gives exit 1" 1 rg "$work/bl"
  check "regress: verdict names join_check.csv" 0 test "$(verdict)" = "regression: differences in join_check.csv"

  mkbase "$work/bl"; cp "$work/hints/photos_pivot.xlsx" "$work/bl/analysis/photos_pivot.xlsx"
  check "regress: changed pivot contents give exit 1" 1 rg "$work/bl"
  check "regress: verdict names photos_pivot.xlsx" 0 test "$(verdict)" = "regression: differences in photos_pivot.xlsx"

  mkbase "$work/bl"; env -u AI_AGENT -u CLAUDECODE duckdb -c "LOAD excel; COPY (SELECT 1 AS x) TO '$work/bl/analysis/photos_pivot.xlsx' (FORMAT xlsx, HEADER true, SHEET 'jpegs')" > /dev/null
  check "regress: baseline pivot file that is not a tool output gives exit 1" 1 rg "$work/bl"
  check "regress: says the baseline file is not a tool output" 0 grep -q "baseline file is not a tool output" "$work/rg.out"
  check "regress: other outputs still compared" 0 test "$(verdict)" = "regression: differences in photos_pivot.xlsx"
  check "regress: --refresh repairs it" 1 sh -c "printf 'y\\n' | PSA_BASELINE='$work/bl' zsh '$repo/analysis/regress.sh' --refresh > '$work/rg.out' 2>&1"
  check "regress: no differences after the repair" 0 rg "$work/bl"

  mkbase "$work/bl"; rm "$work/bl/analysis/photos_pivot.xlsx"
  check "regress: baseline without pivot file still runs" 0 rg "$work/bl"
  check "regress: says pivot not compared" 0 grep -q "baseline has no photos_pivot.xlsx; not compared" "$work/rg.out"

  check "regress: missing baseline gives exit 2" 2 rg "$work/nobaseline"
  check "regress: says why it could not run" 0 grep -q "^regression: could not run: baseline run folder missing" "$work/rg.out"

  mkbase "$work/bl"; sed -i.bak 's/^matched,5$/matched,6/' "$work/bl/analysis/join_check.csv"; rm -f "$work/bl/analysis/join_check.csv.bak"
  runsum=$(cd "$work/bl/run" && ls -lR | cksum)
  check "regress: --refresh answered n keeps the baseline" 1 sh -c "printf 'n\\n' | PSA_BASELINE='$work/bl' zsh '$repo/analysis/regress.sh' --refresh > '$work/rg.out' 2>&1"
  check "regress: baseline unchanged after n" 0 grep -q '^matched,6$' "$work/bl/analysis/join_check.csv"
  check "regress: --refresh answered y replaces the analysis" 1 sh -c "printf 'y\\n' | PSA_BASELINE='$work/bl' zsh '$repo/analysis/regress.sh' --refresh > '$work/rg.out' 2>&1"
  check "regress: baseline analysis is the new one" 0 grep -q '^matched,5$' "$work/bl/analysis/join_check.csv"
  check "regress: previous analysis kept" 0 sh -c "ls -d '$work/bl'/analysis.* > /dev/null 2>&1 && grep -q '^matched,6$' '$work/bl'/analysis.*/join_check.csv"
  check "regress: baseline run untouched" 0 test "$(cd "$work/bl/run" && ls -lR | cksum)" = "$runsum"
  check "regress: after refresh, no differences" 0 rg "$work/bl"
  check "psa: regress command dispatches" 0 sh -c "PSA_BASELINE='$work/bl' zsh '$repo/psa' regress 2>/dev/null | grep -q '^regression: no differences'"

  rid=$($py -I -c "import json,sys; print(json.load(open(sys.argv[1]))['run_id'])" "$run/manifest.json")
  check "reports: every report stamped with run_id" 0 test "$(rq "SELECT count(DISTINCT run_id) || '/' || min(run_id) FROM read_csv('$ana/reports/*.csv', union_by_name = true)")" = "1/$rid"
  check "reports: raw = 2 files, 9000 bytes" 0 test "$(rq "SELECT files || '/' || bytes FROM '$ana/reports/volume_by_type.csv' WHERE type_group = 'raw'")" = "2/9000"
  check "reports: by year sums to 9 files" 0 test "$(rq "SELECT sum(files) FROM '$ana/reports/volume_by_year.csv'")" = 9
  check "reports: 2014 = 2 files dated by catalog" 0 test "$(rq "SELECT files || '/' || dated_by_catalog FROM '$ana/reports/volume_by_year.csv' WHERE capture_year = 2014")" = "2/2"
  check "reports: root folder = 3 files" 0 test "$(rq "SELECT files FROM read_csv('$ana/reports/volume_by_folder.csv', all_varchar = true) WHERE top_folder = '(root)'")" = 3
  check "reports: all files in bucket <1 MB" 0 test "$(rq "SELECT bucket || '/' || files FROM '$ana/reports/size_buckets.csv'")" = "<1 MB/9"
  check "reports: not catalogued = 4 files" 0 test "$(rq "SELECT sum(files) FROM '$ana/reports/not_catalogued.csv'")" = 4
  check "reports: missing from disk = GONE.DNG" 0 test "$(rq "SELECT string_agg(regexp_extract(path, '[^/]+\$'), ',') FROM '$ana/reports/missing_from_disk.csv'")" = GONE.DNG
fi

# Scan date: client's local time with UTC offset (fixed zone without DST: +05:30)
check "scan date: collector run in another time zone" 0 env TZ=Asia/Kolkata $collect $args --out "$work/out_tz"
tzrun=("$work"/out_tz/*(/N)); tzrun="${tzrun[1]:-$work/out_tz/none}"
check "scan date: manifest has local time with offset, same moment as finished" 0 $py -I -c "
import json, sys, datetime as dt
m = json.load(open(sys.argv[1]))
loc = dt.datetime.fromisoformat(m['finished_local'])
utc = dt.datetime.strptime(m['finished'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
sys.exit(0 if m['finished_local'].endswith('+05:30') and loc == utc else 1)" "$tzrun/manifest.json"
check "scan date: analysis of that run" 0 zsh "$repo/analysis/run.sh" "$tzrun" --out "$work/ana_tz"
check "scan date: reports show local time with offset" 0 test "$(env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list -c "SELECT count(*) FILTER (WHERE NOT scan_date LIKE '% %:%:%+05:30') || '/' || count(*) FROM read_csv('$work/ana_tz/reports/*.csv', union_by_name = true, all_varchar = true)" | cut -d/ -f1)" = 0
cp -R "$tzrun" "$work/old_manifest"
$py -I -c "
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m.pop('finished_local'); json.dump(m, open(p, 'w'))" "$work/old_manifest/manifest.json"
check "scan date: older manifest analyses" 0 zsh "$repo/analysis/run.sh" "$work/old_manifest" --out "$work/ana_old"
check "scan date: older manifest falls back to UTC with +00:00" 0 test "$(env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list -c "SELECT DISTINCT scan_date FROM read_csv('$work/ana_old/reports/volume_by_type.csv', all_varchar = true)")" = "$($py -I -c "import json,sys; print(json.load(open(sys.argv[1]))['finished'].replace('T',' ').replace('Z','+00:00'))" "$work/old_manifest/manifest.json")"

# Transfer (a plain copy) and verify
mkdir -p "$work/recv" "$work/incomplete"; touch "$work/incomplete/files.csv"
cp -R "$run" "$work/recv/"
recv="$work/recv/${run:t}"
check "run.sh: refuses a folder without manifest" 1 zsh "$repo/analysis/run.sh" "$work/incomplete" --out "$work/ana_incomplete"
check "run.sh: analyses a copied run folder" 0 zsh "$repo/analysis/run.sh" "$recv" --out "$work/ana_recv"
check "verify: intact run passes" 0 $py -I "$repo/analysis/verify.py" "$recv"
print x >> "$recv/files.csv"
check "verify: modified files.csv fails" 1 $py -I "$repo/analysis/verify.py" "$recv"
check "run.sh: stops when verification fails" 1 zsh "$repo/analysis/run.sh" "$recv" --out "$work/ana_bad"
check "run.sh: no output after failed verification" 0 test ! -e "$work/ana_bad"

# Update check (./psa), against a local stand-in for GitHub
G=(git -c user.name=test -c user.email=test@example.invalid -c advice.detachedHead=false -c push.negotiate=false)
up="$work/upd"; mkdir -p "$up"
cp -R "$repo" "$up/dev"; rm -rf "$up/dev/.git"
$G -C "$up/dev" init -q -b main && $G -C "$up/dev" add -A && $G -C "$up/dev" commit -q -m base
git init -q --bare -b main "$up/origin.git"
$G -C "$up/dev" remote add origin "$up/origin.git" && $G -C "$up/dev" push -q origin main
git clone -q "$up/origin.git" "$up/client"
cl="$up/client"
st() { zsh "$cl/psa" status 2> /dev/null | sed -n 's/^status: //p'; }
publish() { print "$1" >> "$up/dev/CHANGES"; $G -C "$up/dev" add CHANGES; $G -C "$up/dev" commit -q -m "$1"; $G -C "$up/dev" push -q origin main; }
same_head() { test "$(git -C "$cl" rev-parse HEAD)" = "$(git -C "$up/dev" rev-parse HEAD)"; }

check "psa: help exits 0" 0 zsh "$cl/psa" help
check "psa: unknown command exits 1" 1 zsh "$cl/psa" nonsense
check "psa: up to date" 0 test "$(st)" = up_to_date
publish c1
check "psa: behind on clean main is updated and restarted" 0 test "$(st)" = updated
check "psa: update brings HEAD to origin/main" 0 same_head
print 'print "marker: new psa"' >> "$up/dev/psa"; $G -C "$up/dev" commit -q -am "psa change"; $G -C "$up/dev" push -q origin main
check "psa: after an update, the new psa continues the run" 0 sh -c "zsh '$cl/psa' status 2>/dev/null | grep -q 'marker: new psa'"
$py -I -c "
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('check-catalog|collect|analyse|regress|status) known=1 ;;', 'check-catalog|collect|analyse|regress|status|hello) known=1 ;;')
s = s.replace('  status)\n', '  hello) print \"hello from new psa\" ;;\n  status)\n', 1)
open(p, 'w').write(s)" "$up/dev/psa"
$G -C "$up/dev" commit -q -am "new command"; $G -C "$up/dev" push -q origin main
check "psa: new command works on first call from an older copy" 0 sh -c "zsh '$cl/psa' hello 2>/dev/null | grep -q 'hello from new psa'"
check "psa: command unknown in both versions exits 1" 1 zsh "$cl/psa" nonexistent
print change >> "$cl/README.md"; publish c2
check "psa: local changes are not updated" 0 test "$(st)" = local_changes
check "psa: local changes leave HEAD as it was" 1 same_head
git -C "$cl" checkout -q -- README.md
check "psa: clean again, behind, is updated" 0 test "$(st)" = updated
git -C "$cl" checkout -q -b feature
check "psa: another branch is not updated" 0 test "$(st)" = other_branch
git -C "$cl" checkout -q main; git -C "$cl" checkout -q --detach
check "psa: detached HEAD is not updated" 0 test "$(st)" = other_branch
git -C "$cl" checkout -q main
print local >> "$cl/LOCAL"; $G -C "$cl" add LOCAL; $G -C "$cl" commit -q -m local
check "psa: ahead of origin is not updated" 0 test "$(st)" = ahead
publish c3
check "psa: diverged is not updated" 0 test "$(st)" = diverged
git -C "$cl" reset -q --hard origin/main
git -C "$cl" remote set-url origin "$up/nowhere.git"
check "psa: no network is a warning, not a stop" 0 test "$(st)" = offline
check "psa: warning names the reason" 0 sh -c "zsh '$cl/psa' status 2>&1 | grep -q 'warning: not updated: offline'"
git -C "$cl" remote set-url origin "$up/origin.git"
cp -R "$cl" "$up/nogit"; rm -rf "$up/nogit/.git"
check "psa: not a git checkout is a warning" 0 test "$(zsh "$up/nogit/psa" status 2> /dev/null | sed -n 's/^status: //p')" = not_a_checkout

# Update check result in the manifest, and the commit warning in analyse
check "psa: collect runs" 0 zsh "$cl/psa" collect --client test --machine m1 --scan-root "$d/vol/Photos" --catalog "$d/lr/Test.lrcat" --out "$up/out"
prun=("$up"/out/*(/N)); prun="${prun[1]:-$up/out/none}"
uc() { $py -I -c "import json,sys; print(json.load(open(sys.argv[1]))['collector']['update_check']['status'])" "$1/manifest.json"; }
check "manifest: update check recorded by psa" 0 test "$(uc "$prun")" = up_to_date
check "manifest: direct call records not_run" 0 test "$(uc "$run")" = not_run
check "psa: analyse on the same commit gives no commit warning" 1 sh -c "zsh '$cl/psa' analyse '$prun' --out '$up/ana_same' 2>&1 | grep -q 'run collected with commit'"
check "run.sh: warns when the run was collected with another commit" 0 sh -c "zsh '$repo/analysis/run.sh' '$prun' --out '$up/ana_other' 2>&1 | grep -q 'run collected with commit'"

# Settings file found by psa
hm="$up/home"; mkdir -p "$hm/photo-analysis"; cp "$sd/two.env" "$hm/photo-analysis/settings.env"
check "psa: default settings file used without arguments" 0 env -u PSA_SETTINGS HOME="$hm" zsh "$cl/psa" collect --out "$up/out_set_default"
check "psa: manifest names the default settings file" 0 test "$(mq "$(onerun "$up/out_set_default")" "m['settings']['file']")" = "\"$hm/photo-analysis/settings.env\""
check "psa: PSA_SETTINGS names another file" 0 env PSA_SETTINGS="$sd/home.env" HOME="$d" zsh "$cl/psa" collect --client test --machine m1 --out "$up/out_set_env"
check "psa: manifest names the PSA_SETTINGS file" 0 test "$(mq "$(onerun "$up/out_set_env")" "m['settings']['file']")" = "\"$sd/home.env\""
check "psa: PSA_SETTINGS empty means no settings file" 1 env PSA_SETTINGS= HOME="$hm" zsh "$cl/psa" collect --out "$up/out_set_off"
cp "$work/last.out" "$up/set_off.out"
check "psa: says there is no scan root" 0 grep -q 'No scan root' "$up/set_off.out"
check "psa: PSA_SETTINGS naming a missing file stops" 1 env PSA_SETTINGS="$sd/none.env" zsh "$cl/psa" collect --out "$up/out_set_off"
check "psa: without a settings file, none is reported" 0 sh -c "env -u PSA_SETTINGS HOME='$up/nohome' zsh '$cl/psa' collect --client test --machine m1 --scan-root '$d/vol/Photos' --skip-catalog --out '$up/out_set_none' 2>&1 | grep -q 'Settings file: none'"
check "psa: check-catalog takes CATALOG from the default file" 0 sh -c "env -u PSA_SETTINGS HOME='$hm' zsh '$cl/psa' check-catalog 2>&1 | grep -qF 'CATALOG from settings file: $d/lr/Multi.lrcat'"
check "psa: stopped settings runs wrote nothing" 0 test ! -e "$up/out_set_off"

print
if (( fails )); then print "$fails check(s) failed"; exit 1; fi
print "all checks passed (sample data kept in $work)"
