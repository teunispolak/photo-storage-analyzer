#!/bin/zsh
# Run extract, verify and analyse against generated sample data.
# Usage: tests/run_tests.sh      (from the repository root)
#   PYTHON=/usr/bin/python3 tests/run_tests.sh   to test a specific interpreter
# Exit 0 if all checks pass.

set -uo pipefail

repo="${0:A:h:h}"
work="${TEST_WORK:-${TMPDIR:-/tmp}/photo-storage-analyzer-tests}"  # outside the repository
work="${work:a}"  # absolute, no // (macOS TMPDIR ends in /); symlinks kept
py="${PYTHON:-python3}"
extract_raw=($py -I "$repo/extract/extract.py")
extract=($extract_raw --client test --machine m1)  # labels are required; tests of labels use extract_raw
# psa reads ~/photo-analysis/settings.env; tests use no settings file unless they set one
export PSA_SETTINGS=""
unset PSA_EXTRACTS_DIR PSA_CLIENTS_DIR  # set per test where used
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
mkdir -p "$work/real"
# Work through a symlink on every machine, as macOS does ($TMPDIR is under
# /var -> /private/var), so a test that compares an unresolved path with a
# resolved one fails here too, not only on macOS CI
ln -s real "$work/link"; base="$work"; work="$work/link"
check "setup: work folder is reached through a symlink" 0 test "${work:A}" != "$work"
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
chk=($py -I "$repo/extract/check_catalog.py")
check "check_catalog: test catalog has the required structure" 0 $chk "$d/lr/Test.lrcat"
check "check_catalog: counts the virtual copy" 0 sh -c "$py -I '$repo/extract/check_catalog.py' '$d/lr/Test.lrcat' | grep -q 'virtual copies: 1'"
check "check_catalog: --show-roots prints the root folder" 0 sh -c "$py -I '$repo/extract/check_catalog.py' '$d/lr/Test.lrcat' --show-roots | grep -qF '$d/vol/Photos/'"
check "check_catalog: no root paths without --show-roots" 1 sh -c "$py -I '$repo/extract/check_catalog.py' '$d/lr/Test.lrcat' | grep -qF '$d/vol/Photos/'"
$py -I -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE AgLibraryRootFolder (id_local, absolutePath)'); c.commit()" "$work/broken.lrcat"
check "check_catalog: fails on a catalog missing tables" 1 $chk "$work/broken.lrcat"

# Settings file (extract/settings.py), passed with --settings
sd="$work/settings"; mkdir -p "$sd"
# value of a manifest field, as JSON: mq <extract> <python expression on m>
mq() { $py -I -c "import json,sys; m=json.load(open(sys.argv[1]+'/manifest.json')); print(json.dumps(eval(sys.argv[2])))" "$1" "$2"; }
oneext() { local r=("$1"/*(/N)); print -- "${r[1]:-$1/none}"; }
printf '# client settings\n\nCLIENT="acme"\nMACHINE="anna"\nCATALOG="%s"\nSCAN_ROOT="%s"\n  SCAN_ROOT="%s"  \n' "$d/lr/Multi.lrcat" "$d/vol/Photos" "$d/vol/Extra" > "$sd/two.env"
check "settings: run with labels, catalog and two roots from the file" 0 $extract_raw --settings "$sd/two.env" --out "$work/out_set"
sext=$(oneext "$work/out_set")
check "settings: scan roots taken from the file" 0 test "$(mq "$sext" "m['scan_roots']")" = "[\"$d/vol/Photos\", \"$d/vol/Extra\"]"
check "settings: manifest records file, values and checksum" 0 test "$(mq "$sext" "[m['settings']['file'], m['settings']['used'], m['settings']['replaced_by_command_line'], len(m['settings']['sha256']), len(m['tool']['settings_module_sha256'])]")" = "[\"$sd/two.env\", {\"SCAN_ROOT\": [\"$d/vol/Photos\", \"$d/vol/Extra\"], \"CLIENT\": \"acme\", \"MACHINE\": \"anna\", \"CATALOG\": \"$d/lr/Multi.lrcat\"}, [], 64, 64]"
check "labels: from the settings file into manifest and extract folder name" 0 test "$(mq "$sext" "[m['client'], m['machine'], m['extract_id'].rsplit('_', 1)[0]]")/${sext:t}" = "[\"acme\", \"anna\", \"acme_anna\"]/$(mq "$sext" "m['extract_id']" | tr -d '\"')"
check "settings: extract.log names the file and values" 0 grep -q "SCAN_ROOT from settings file: $d/vol/Extra" "$sext/extract.log"
check "settings: --scan-root replaces all SCAN_ROOT lines" 0 $extract_raw --settings "$sd/two.env" --scan-root "$d/vol/Photos" --machine bob --out "$work/out_set_arg"
sext=$(oneext "$work/out_set_arg")
check "settings: only the command-line root is scanned" 0 test "$(mq "$sext" "[m['scan_roots'], list(m['settings']['used']), m['settings']['replaced_by_command_line']]")" = "[[\"$d/vol/Photos\"], [\"CLIENT\", \"CATALOG\"], [\"SCAN_ROOT\", \"MACHINE\"]]"
check "labels: --machine replaces MACHINE" 0 test "$(mq "$sext" "[m['client'], m['machine']]")" = "[\"acme\", \"bob\"]"
# The settings file and a README travel with the extract
sext2=$(oneext "$work/out_set")
check "extract: settings.env is an exact copy of the settings file" 0 cmp -s "$sd/two.env" "$sext2/settings.env"
check "extract: manifest names the copy" 0 test "$(mq "$sext2" "m['settings']['copy']")" = '"settings.env"'
check "extract: README.txt names the extract, settings.env and no photos" 0 sh -c "grep -q '^Extract ${sext2:t}\$' '$sext2/README.txt' && grep -q 'settings.env    the settings' '$sext2/README.txt' && grep -q 'contains no photos' '$sext2/README.txt'"
check "extract: README names values given on the command line" 0 grep -q 'command line instead: SCAN_ROOT, MACHINE' "$(oneext "$work/out_set_arg")/README.txt"
check "verify: extract with settings.env" 0 $py -I "$repo/analyse/verify.py" "$sext2"
check "verify: lists the settings copy" 0 sh -c "$py -I '$repo/analyse/verify.py' '$sext2' | grep -q '^ok   settings: settings.env'"
cp -R "$sext2" "$work/set_changed"; print 'MACHINE="other"' >> "$work/set_changed/settings.env"
check "verify: changed settings.env refused" 1 $py -I "$repo/analyse/verify.py" "$work/set_changed"
cp -R "$sext2" "$work/set_missing"; mv "$work/set_missing/settings.env" "$work/set_missing.env"
check "verify: missing settings.env refused" 1 $py -I "$repo/analyse/verify.py" "$work/set_missing"
print -r -- 'CATALOG="$HOME/lr/Test.lrcat"' > "$sd/home.env"; print -r -- 'SCAN_ROOT="~/vol/Photos"' >> "$sd/home.env"
check "settings: \$HOME and ~ expanded" 0 env HOME="$d" $extract --settings "$sd/home.env" --out "$work/out_set_home"
check "settings: expanded values in the manifest" 0 test "$(mq "$(oneext "$work/out_set_home")" "m['settings']['used']")" = "{\"SCAN_ROOT\": [\"$d/vol/Photos\"], \"CATALOG\": \"$d/lr/Test.lrcat\"}"
print -r -- "SCAN_ROOT=\"$d/\$USER/Photos\"" > "$sd/var.env"
check "settings: other variables are not expanded" 1 $extract --settings "$sd/var.env" --skip-catalog --out "$work/out_set_var"
cp "$work/last.out" "$sd/var.out"
check "settings: path kept as written" 0 grep -qF "$d/\$USER/Photos" "$sd/var.out"
print -r -- "CATALOG=\"$d/lr/Test.lrcat\"" > "$sd/noroot.env"
check "settings: no scan root anywhere stops the run" 1 $extract --settings "$sd/noroot.env" --out "$work/out_set_bad"
for name content in \
    unquoted "SCAN_ROOT=$d/vol/Photos" \
    unknown_key "SCANROOT=\"$d/vol/Photos\"" \
    catalog_twice "CATALOG=\"$d/lr/Test.lrcat\"\nCATALOG=\"$d/lr/Multi.lrcat\"" \
    empty_value "SCAN_ROOT=\"\"" \
    shell_line "export SCAN_ROOT=\"$d/vol/Photos\""; do
  printf "SCAN_ROOT=\"$d/vol/Photos\"\n$content\n" > "$sd/$name.env"
  check "settings: $name stops the run" 1 $extract --settings "$sd/$name.env" --out "$work/out_set_bad"
  cp "$work/last.out" "$sd/$name.out"
  check "settings: $name is reported with its line number" 0 grep -q 'line [0-9]' "$sd/$name.out"
done
# Labels: required, valid
check "labels: no client stops the run" 1 $extract_raw $args --machine m1 --out "$work/out_set_bad"
cp "$work/last.out" "$sd/noclient.out"
check "labels: says the client is missing" 0 grep -q 'No client' "$sd/noclient.out"
check "labels: no machine stops the run" 1 $extract_raw $args --client test --out "$work/out_set_bad"
for bad in Acme 'a b' -acme 'acme/x' "$(printf 'a%.0s' {1..41})"; do
  check "labels: invalid client '$bad' stops the run" 1 $extract_raw $args --client="$bad" --machine m1 --out "$work/out_set_bad"
done
printf 'CLIENT="Acme Photo"\n' > "$sd/badlabel.env"
check "labels: invalid CLIENT in the settings file stops the run" 1 $extract $args --settings "$sd/badlabel.env" --out "$work/out_set_bad"
cp "$work/last.out" "$sd/badlabel.out"
check "labels: settings file label error gives the line" 0 grep -q 'line 1: CLIENT' "$sd/badlabel.out"
check "settings: missing file stops the run" 1 $extract --settings "$sd/none.env" --out "$work/out_set_bad"
check "settings: stopped runs wrote nothing" 0 test ! -e "$work/out_set_bad"
check "check_catalog: CATALOG from the settings file" 0 sh -c "$py -I '$repo/extract/check_catalog.py' --settings '$sd/two.env' | grep -qF 'CATALOG from settings file: $d/lr/Multi.lrcat'"
check "check_catalog: argument replaces CATALOG" 0 sh -c "$py -I '$repo/extract/check_catalog.py' '$d/lr/Test.lrcat' --settings '$sd/two.env' | grep -q 'CATALOG from the command line'"
check "check_catalog: bad settings file fails" 1 $chk --settings "$sd/unknown_key.env"

# Preflight failures
check "preflight: output inside scan root" 1 $extract $args --out "$d/vol/Photos/out"
check "preflight: output inside Dropbox folder" 1 $extract $args --out "$d/vol/x" --dropbox-root "$d/vol"
touch "$d/lr/Test.lrcat.lock"
check "preflight: lock file present" 1 $extract $args --out "$d/out"
mv "$d/lr/Test.lrcat.lock" "$d/lr/Test.lrcat-wal"
check "preflight: -wal file present" 1 $extract $args --out "$d/out"
mv "$d/lr/Test.lrcat-wal" "$work/removed-wal"
check "preflight: missing catalog" 1 $extract --scan-root "$d/vol/Photos" --catalog "$d/lr/None.lrcat" --out "$d/out"

# Complete extract
check "extract: complete extract" 0 $extract $args --out "$d/out"
ext=("$d"/out/*(/N))
if (( ${#ext} != 1 )); then
  print "FAIL expected one extract, found ${#ext}"; exit 1
fi
ext="${ext[1]}"
check "settings: extract without a file says so" 0 grep -q 'Settings file: none' "$ext/extract.log"
check "manifest: schema 2, extract_id is the folder name, tool block" 0 test "$(mq "$ext" "[m['schema'], m['extract_id'] == '${ext:t}', sorted(m['tool'])[:3], 'run_id' in m, 'collector' in m]")" = '[2, true, ["git_commit", "script_sha256", "settings_module_sha256"], false, false]'
check "extract: default output in ~/photo-analysis/extracts" 0 env HOME="$work/home_ext" $extract $args
check "extract: one extract there" 0 test "$(ls "$work/home_ext/photo-analysis/extracts" | grep -c '^test_m1_')" = 1
check "manifest: settings null without a file" 0 test "$(mq "$ext" "m['settings']")" = null
check "extract: no settings.env without a settings file" 0 test ! -e "$ext/settings.env"
check "extract: README says so" 0 grep -q 'made without a settings file' "$ext/README.txt"
for f in catalog.lrcat files.csv manifest.json extract.log; do
  check "extract has $f" 0 test -f "$ext/$f"
done
check "files.csv has 9 rows" 0 test "$(( $(wc -l < "$ext/files.csv") - 1 ))" -eq 9
check "failed preflight wrote nothing" 0 test ! -e "$d/vol/Photos/out" -a ! -e "$d/vol/x"
check "file names are NFC" 0 $py -I -c "
import sys, unicodedata
t = open(sys.argv[1], encoding='utf-8').read()
sys.exit(0 if t == unicodedata.normalize('NFC', t) and 'Café.JPG' in t else 1)" "$ext/files.csv"

# Scan root through a symlink: paths differ from the catalog's, the extract must warn
ln -s "$d/vol" "$work/vol_link"
check "extract: warns when scan root does not match catalog root" 0 sh -c \
  "$py -I '$repo/extract/extract.py' --client test --machine m1 --scan-root '$work/vol_link/Photos' --catalog '$d/lr/Test.lrcat' --out '$work/out_link' 2>&1 | grep -q 'does not overlap'"
check "extract: no warning when scan root matches" 1 grep -q 'does not overlap' "$ext/extract.log"

# macOS only: creation date and hidden flag
if [[ "$(uname)" == Darwin ]]; then
  check "macOS: btime filled for every row" 0 $py -I -c "
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding='utf-8')))
sys.exit(0 if rows and all(r['btime'] for r in rows) else 1)" "$ext/files.csv"
  check "macOS: hidden flag detected" 0 $py -I -c "
import csv, sys
rows = {r['name']: r for r in csv.DictReader(open(sys.argv[1], encoding='utf-8'))}
sys.exit(0 if rows['flagged.jpg']['hidden'] == '1' and rows['root.txt']['hidden'] == '0' else 1)" "$ext/files.csv"
fi

# Analysis (analyse.sh: verify, load, join, reports), output outside the extract
if ! command -v duckdb > /dev/null; then
  print "FAIL duckdb not found"; (( fails++ ))
else
  anash=(zsh "$repo/analyse/analyse.sh")
  ana="$work/ana"
  before=$(cd "$ext" && ls -lR)
  check "analyse: complete extract" 0 $anash "$ext" --out "$ana"
  check "analyse: extract left unchanged" 0 test "$(cd "$ext" && ls -lR)" = "$before"
  check "analyse: no SQLite side files in the extract" 0 test -z "$(ls "$ext" | grep -E 'lrcat-(wal|shm)')"
  mkdir -p "$work/tmp_normal" "$work/tmp_pipe"
  check "analyse: working copy removed after a normal analysis" 0 sh -c "TMPDIR='$work/tmp_normal' zsh '$repo/analyse/analyse.sh' '$ext' --out '$work/ana_tmpcheck' > /dev/null 2>&1 && test -z \"\$(ls '$work/tmp_normal')\""
  TMPDIR="$work/tmp_pipe" zsh "$repo/analyse/analyse.sh" "$ext" --out "$work/ana_pipe" 2>&1 | grep -q 'loading and joining'
  sleep 1
  check "analyse: working copy removed when output is cut off (broken pipe)" 0 test -z "$(ls "$work/tmp_pipe")"
  check "analyse: refuses existing output without --replace" 1 $anash "$ext" --out "$ana"
  check "analyse: --replace overwrites" 0 $anash "$ext" --out "$ana" --replace
  check "analyse: refuses output inside the extract" 1 $anash "$ext" --out "$ext/x"
  check "analyse: refuses output inside the repository" 1 $anash "$ext" --out "$repo/x"
  check "analyse: --path-from needs --path-to" 1 $anash "$ext" --out "$work/ana_x" --path-from /a
  check "analyse: join_check.csv written" 0 test -f "$ana/join_check.csv"
  check "analyse: second analysis gives identical reports" 0 sh -c "zsh '$repo/analyse/analyse.sh' '$ext' --out '$work/ana2' > /dev/null 2>&1 && diff -r '$ana/reports' '$work/ana2/reports' && diff '$ana/join_check.csv' '$work/ana2/join_check.csv'"

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

  check "join: prefix mapping analysis" 0 $anash "$ext" --out "$work/ana_mapped" --path-from "$d/vol/Photos/" --path-to /elsewhere/
  check "join: prefix mapping applied to all catalog paths" 0 metric_is "$work/ana_mapped/join_check.csv" catalog_paths_prefix_mapped 6
  check "join: prefix mapping leaves nothing matched" 0 metric_is "$work/ana_mapped/join_check.csv" matched 0
  check "join: double slash in --path-from is collapsed" 0 $anash "$ext" --out "$work/ana_slash" --path-from "${d%/*}//${d:t}/vol//Photos/" --path-to /elsewhere/
  check "join: double slash mapping applied to all catalog paths" 0 metric_is "$work/ana_slash/join_check.csv" catalog_paths_prefix_mapped 6

  # Required catalog columns (check_catalog.py) are exactly what the load needs
  variants="$work/variants"
  cols=("${(@f)$($py -I "$repo/tests/catalog_variants.py" "$d/lr/Test.lrcat" "$repo/extract/check_catalog.py" "$variants")}")
  load_with() {  # load_with <catalog> <out_dir>: load and join an extract copy that uses <catalog>
    local rc="$2/extract"; mkdir -p "$rc"
    cp "$ext/files.csv" "$ext/manifest.json" "$rc/"; cp "$1" "$rc/catalog.lrcat"
    (cd "$2" && env -u AI_AGENT -u CLAUDECODE duckdb -bail analysis.duckdb \
      -c "SET VARIABLE extract_dir = '$rc'" -c "SET VARIABLE types_csv = '$repo/analyse/types.csv'" \
      -c ".read $repo/analyse/10_load.sql" -c ".read $repo/analyse/20_join.sql") > /dev/null 2>&1
  }
  check "catalog columns: sample catalog still has no SQLite side files" 0 test -z "$(ls "$d/lr" | grep -E 'lrcat-(wal|shm)')"
  check "catalog columns: minimal catalog loads" 0 load_with "$variants/minimal.lrcat" "$variants/minimal"
  check "catalog columns: minimal catalog gives the same join" 0 diff "$ana/join_check.csv" "$variants/minimal/join_check.csv"
  nreq=$($py -I -c "import importlib.util as u, sys; s = u.spec_from_file_location('c', sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m); print(sum(len(c) for c in m.REQUIRED.values()))" "$repo/extract/check_catalog.py")
  check "catalog columns: one variant per required column ($nreq)" 0 test ${#cols} -eq $nreq -a $nreq -ge 19
  for c in $cols; do
    check "catalog columns: load fails ${c%.lrcat}" 1 load_with "$variants/$c" "$variants/${c%.lrcat}"
  done

  # A failed analysis leaves the output folder as it was: an extract whose catalog lacks a column
  cp -R "$ext" "$work/badcat"; cp "$variants/without-AgLibraryFile.baseName.lrcat" "$work/badcat/catalog.lrcat"
  $py -I -c "
import hashlib, json, sys
d = sys.argv[1]; p = d + '/manifest.json'; m = json.load(open(p))
m['catalog']['sha256'] = hashlib.sha256(open(d + '/catalog.lrcat', 'rb').read()).hexdigest()
json.dump(m, open(p, 'w'), indent=2)" "$work/badcat"
  check "failed analysis: stops" 1 $anash "$work/badcat" --out "$work/ana_fail"
  check "failed analysis: no output folder" 0 test ! -e "$work/ana_fail"
  check "failed analysis: no build folder left" 0 test -z "$(print -l "$work"/ana_fail.part.*(N))"
  cp -R "$ana" "$work/ana_prev"; prevsum=$(cd "$work/ana_prev" && ls -lR | cksum)
  check "failed analysis with --replace: stops" 1 $anash "$work/badcat" --out "$work/ana_prev" --replace
  check "failed analysis with --replace: previous analysis unchanged" 0 test "$(cd "$work/ana_prev" && ls -lR | cksum)" = "$prevsum"
  check "failed analysis with --replace: no build folder left" 0 test -z "$(print -l "$work"/ana_prev.part.*(N))"
  print -n junk > "$work/ana_prev/analysis.duckdb.wal"
  check "replace: a stale write-ahead log is removed, analysis succeeds" 0 $anash "$ext" --out "$work/ana_prev" --replace
  check "replace: no write-ahead log left" 0 test ! -e "$work/ana_prev/analysis.duckdb.wal"
  check "replace: database readable" 0 test "$(env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list "$work/ana_prev/analysis.duckdb" -c "SELECT count(*) > 0 FROM photos")" = true

  for r in "$repo"/analyse/reports/*.sql; do
    check "reports: ${r:t:r}.csv written" 0 test -f "$ana/reports/${r:t:r}.csv"
  done
  # Reconciliation report
  check "reconciliation: levels add up and match join_check" 0 $py -I "$repo/tests/check_reconciliation.py" "$ana"
  check "reconciliation: all catalog files outside the scan root (prefix mapping)" 0 $py -I "$repo/tests/check_reconciliation.py" "$work/ana_mapped"
  check "reconciliation: mapped analysis counts 6 catalog entries outside the scan root" 0 test "$(grep ',catalog entries outside the scan root (not analysed),' "$work/ana_mapped/reports/reconciliation.csv" | cut -d, -f5)" = 6
  check "scope: mapped analysis has no catalog files in scope" 0 metric_is "$work/ana_mapped/join_check.csv" catalog_only 0
  check "scope: mapped analysis counts them outside the scan root" 0 metric_is "$work/ana_mapped/join_check.csv" catalog_outside_scan_root 6

  # Pivot file (photos_pivot.xlsx)
  dq() { env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list "$@"; }
  check "pivot: photos_pivot.xlsx written" 0 test -f "$ana/photos_pivot.xlsx"
  contract_cols=$($py -I -c "import csv,sys; print(','.join(r['column'] for r in csv.DictReader(open(sys.argv[1]))))" "$repo/analyse/pivot_columns.csv")
  contract_types=$($py -I -c "import csv,sys; print(','.join(r['type'] for r in csv.DictReader(open(sys.argv[1]))))" "$repo/analyse/pivot_columns.csv")
  check "pivot: xlsx columns and order match the contract" 0 test "$(dq -c "LOAD excel; SELECT string_agg(column_name, ',') FROM (DESCRIBE SELECT * FROM read_xlsx('$ana/photos_pivot.xlsx', sheet = 'photos', all_varchar = true))")" = "$contract_cols"
  check "pivot: column types match the contract" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT string_agg(column_type, ',') FROM (DESCRIBE photos_pivot)")" = "$contract_types"
  check "pivot: one row per file" 0 test "$(dq -c "LOAD excel; SELECT count(*) FROM read_xlsx('$ana/photos_pivot.xlsx', sheet = 'photos', all_varchar = true)")" = 10
  check "pivot: files in the scan root are (root)" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT top_folder || '|' || folder FROM photos_pivot WHERE name = 'root.txt'")" = "(root)|(root)"
  check "pivot: folder is relative, folder_path is full" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT top_folder || '|' || folder || '|' || (folder_path = '$d/vol/Photos/2014/Trip') FROM photos_pivot WHERE name = 'IMG_0001.CR2'")" = "2014|2014/Trip|true"
  check "pivot: source values" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT string_agg(source || '=' || n, ' ' ORDER BY source) FROM (SELECT source, count(*) AS n FROM photos_pivot GROUP BY 1)")" = "catalog only=1 filesystem and catalog=5 filesystem only=4"
  check "scope: mapped analysis has only scanned files as rows" 0 test "$(dq "$work/ana_mapped/analysis.duckdb" -c "SELECT count(*) || '/' || count(*) FILTER (WHERE source = 'catalog only') FROM photos_pivot")" = "9/0"
  check "pivot: scan_root column" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT string_agg(DISTINCT scan_root, ',') FROM photos_pivot")" = "$d/vol/Photos"
  check "pivot: every row has the scan root" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT count(*) FROM photos_pivot WHERE scan_root IS NULL")" = 0
  check "pivot: subfolder is the folder below top_folder" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT top_folder || '|' || subfolder FROM photos_pivot WHERE name = 'IMG_0001.CR2'")" = "2014|Trip"
  check "pivot: subfolder empty directly in a top folder and in the scan root" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT count(*) FROM photos_pivot WHERE subfolder IS NOT NULL AND (folder = '(root)' OR folder NOT LIKE '%/%')")" = 0
  check "pivot: test data has files in the scan root and directly in a top folder" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT (count(*) FILTER (WHERE folder = '(root)') > 0) AND (count(*) FILTER (WHERE folder <> '(root)' AND folder NOT LIKE '%/%') > 0) FROM photos_pivot")" = true

  # Years for archive candidates: last modified (disk, else catalog), last Lightroom edit, the later of the two
  yy=$(date +%Y)
  ay() { dq "$ana/analysis.duckdb" -c "SELECT concat_ws('|', coalesce(last_modified_year::VARCHAR, '-'), coalesce(last_touched_year::VARCHAR, '-'), coalesce(last_edited_year::VARCHAR, '-')) FROM photos_pivot WHERE name = '$1'"; }
  check "archive: catalog seconds converted exactly" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT strftime(last_modified, '%Y-%m-%d %H:%M:%S') || '/' || (SELECT strftime(touch_time, '%Y-%m-%d %H:%M:%S.%g') FROM lr_image WHERE id = 1000) FROM photos WHERE name = 'GONE.DNG'")" = "2016-06-01 00:00:00/2022-03-04 12:00:00.500"
  check "archive: develop step after import counts, later than the touch: 2023" 0 test "$(ay IMG_0001.CR2)" = "2012|2023|2023"
  check "archive: sidecar on disk carries the photo's Lightroom edit year" 0 test "$(ay IMG_0001.xmp)" = "$yy|2023|$yy"
  check "archive: touched only at import: no Lightroom edit year" 0 test "$(ay IMG_0100.NEF)" = "$yy|-|$yy"
  check "archive: import moment is the first step, Dutch name, after the session in UTC" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT string_agg(image_id || '=' || strftime(import_time, '%Y-%m-%d %H:%M'), ' ' ORDER BY image_id) FROM lr_import")" = "1000=2021-01-01 09:05 1002=2021-01-01 09:06 1003=2021-01-01 09:00 1004=2021-01-01 09:00"
  check "archive: touch within 10 minutes of the import is not an edit" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT count(*) FROM lr_edit WHERE image_id = 1002 AND edit_time IS NULL")" = 1
  check "archive: touch 2022 kept as an edit (after import), develop step 2023 wins" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT strftime(edit_time, '%Y-%m-%d') FROM lr_edit WHERE image_id = 1000")" = 2023-06-01
  check "archive: catalog only: catalog's modification year, never touched" 0 test "$(ay GONE.DNG)" = "2016|-|2016"
  check "archive: not catalogued: modification year only" 0 test "$(ay flagged.jpg)" = "$yy|-|$yy"
  check "archive: every row has a last edited year" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT count(*) FROM photos_pivot WHERE last_edited_year IS NULL")" = 0

  rq() { env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list -c "$1"; }

  # Folder tree: branch totals; root equals the whole scan; catalog-only entries left out
  ft() { rq "SELECT $1 FROM read_csv('$2/reports/folder_tree.csv', all_varchar = true) ${3:-}"; }
  check "folder tree: written as xlsx and report" 0 test -f "$ana/folder_tree.xlsx" -a -f "$ana/reports/folder_tree.csv"
  check "folder tree: root row is the whole scan (disk files and bytes)" 0 test "$(ft "files || '/' || bytes" "$ana" "WHERE depth = '0'")" = "$(rq "SELECT max(value) FILTER (WHERE metric = 'disk_files') || '/' || max(value) FILTER (WHERE metric = 'disk_bytes') FROM read_csv('$ana/join_check.csv', all_varchar = true)")"
  check "folder tree: branch = direct + children, for every folder" 0 test "$(rq "
    WITH t AS (SELECT folder, depth::INT d, bytes::BIGINT b, direct_bytes::BIGINT db FROM read_csv('$ana/reports/folder_tree.csv', all_varchar = true))
    SELECT count(*) FROM t p WHERE p.b <> p.db + coalesce((SELECT sum(c.b) FROM t c WHERE c.d = p.d + 1
      AND (p.d = 0 OR starts_with(c.folder, p.folder || '/'))), 0)")" = 0
  # A tree of its own: old files plus a system file rewritten today
  tr="$d/vol/Tree"
  $py -I -c "
import os, sys
t = sys.argv[1]
for rel, size, mtime in (('old/a.jpg', 1000, 1420113600), ('old/.DS_Store', 10, None),  # 2015-01-01, today
                         ('old/sub/b.jpg', 2000, 1451649600), ('new/c.jpg', 500, None)):  # 2016-01-01, today
    p = os.path.join(t, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(b'x' * size)
    if mtime: os.utime(p, (mtime, mtime))" "$tr"
  check "folder tree: extract of its own tree" 0 $extract --scan-root "$tr" --catalog "$d/lr/Test.lrcat" --out "$work/out_tree"
  check "folder tree: its analysis" 0 $anash "$(oneext "$work/out_tree")" --out "$work/ana_tree"
  check "folder tree: rows, sizes and years; .DS_Store counted in size, not in years" 0 test "$(ft "string_agg(folder || ':' || depth || ':' || files || ':' || bytes || ':' || direct_bytes || ':' || coalesce(max_last_edited_year, '-'), ' ' ORDER BY folder)" "$work/ana_tree")" = "(root):0:4:3510:0:$yy new:1:1:500:500:$yy old:1:3:3010:1010:2016 old/sub:2:1:2000:2000:2016"
  check "folder tree: parent's later year per row" 0 test "$(ft "string_agg(folder || ':' || coalesce(parent_max_year, '-'), ' ' ORDER BY folder)" "$work/ana_tree")" = "(root):- new:$yy old:$yy old/sub:2016"
  check "folder tree: own years up to 2016 and parent's after it: only the outermost branch" 0 test "$(ft "string_agg(folder, ' ')" "$work/ana_tree" "WHERE max_last_edited_year::INT <= 2016 AND max_capture_year::INT <= 2016 AND parent_max_year::INT > 2016")" = old

  # Names that need quoting in files.csv: carriage return (Icon\r), newline, comma, quote
  oddnames="['Icon\r', 'a,b.jpg', 'say \"cheese\".jpg', 'two\nlines.jpg', 'end\r\n.jpg']"
  check "odd names: extract" 0 $extract --scan-root "$d/vol/Odd" --catalog "$d/lr/Test.lrcat" --out "$work/out_odd"
  oext=$(oneext "$work/out_odd")
  check "odd names: files.csv has CRLF line endings" 0 $py -I -c "import sys; b = open(sys.argv[1], 'rb').read(); sys.exit(0 if b.count(b'\r\n') >= 6 and b.endswith(b'\r\n') else 1)" "$oext/files.csv"
  check "odd names: files.csv reads back with the names unchanged" 0 $py -I -c "
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], newline='', encoding='utf-8')))
sys.exit(0 if sorted(r['name'] for r in rows) == sorted($oddnames) and all(len(r) == 14 for r in rows) else 1)" "$oext/files.csv"
  check "odd names: verify" 0 $py -I "$repo/analyse/verify.py" "$oext"
  check "odd names: analysis" 0 $anash "$oext" --out "$work/ana_odd"
  check "odd names: all five in the pivot, unchanged" 0 test "$(dq "$work/ana_odd/analysis.duckdb" -c "SELECT count(*) FROM photos_pivot WHERE name IN ('Icon' || chr(13), 'a,b.jpg', 'say \"cheese\".jpg', 'two' || chr(10) || 'lines.jpg', 'end' || chr(13) || chr(10) || '.jpg')")" = 5
  check "odd names: Icon\\r is a system file" 0 test "$(dq "$work/ana_odd/analysis.duckdb" -c "SELECT type_group FROM photos_pivot WHERE name = 'Icon' || chr(13)")" = system
  # An extract written the way Python 3.9 did: Icon\r unquoted, \n line endings
  cp -R "$oext" "$work/odd_split"
  $py -I -c "
import csv, hashlib, io, json, sys
d = sys.argv[1]
rows = list(csv.reader(open(d + '/files.csv', newline='', encoding='utf-8')))
b = io.StringIO(); csv.writer(b, lineterminator='\n').writerows(rows)
t = b.getvalue().replace('\"Icon\r\"', 'Icon\r')
open(d + '/files.csv', 'w', encoding='utf-8', newline='').write(t)
m = json.load(open(d + '/manifest.json')); m['files']['sha256'] = hashlib.sha256(t.encode()).hexdigest()
json.dump(m, open(d + '/manifest.json', 'w'), indent=2)" "$work/odd_split"
  check "odd names: verify refuses a split files.csv" 1 $py -I "$repo/analyse/verify.py" "$work/odd_split"
  cp "$work/last.out" "$work/odd_split.out"
  check "odd names: says it does not read back" 0 grep -q 'does not read back' "$work/odd_split.out"
  check "odd names: the extract's own read-back check refuses it" 0 $py -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import extract
p = extract.csv_problem(__import__('pathlib').Path(sys.argv[2]), extract.CSV_COLUMNS, 5)
sys.exit(0 if p and 'fields' in p else 1)" "$repo/extract" "$work/odd_split/files.csv"
  check "odd names: and accepts the correct one" 0 $py -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import extract
sys.exit(0 if extract.csv_problem(__import__('pathlib').Path(sys.argv[2]), extract.CSV_COLUMNS, 5) is None else 1)" "$repo/extract" "$oext/files.csv"

  # Multiple scan roots: a second tree, Extra, with its own catalog root (Multi.lrcat, from make_fixture.py)
  check "multi: nested scan roots refused" 1 $extract --scan-root "$d/vol/Photos" --scan-root "$d/vol/Photos/2014" --catalog "$d/lr/Multi.lrcat" --out "$work/out_nested"
  cp "$work/last.out" "$work/nested.out"
  check "multi: says the roots are nested" 0 grep -q 'Scan roots are nested' "$work/nested.out"
  check "multi: same scan root twice refused" 1 $extract --scan-root "$d/vol/Photos" --scan-root "$d/vol/Photos/" --catalog "$d/lr/Multi.lrcat" --out "$work/out_twice"
  cp "$work/last.out" "$work/twice.out"
  check "multi: says the root is given twice" 0 grep -q 'Scan root given twice' "$work/twice.out"
  check "multi: refused runs wrote nothing" 0 test ! -e "$work/out_nested" -a ! -e "$work/out_twice"
  check "multi: extract with two roots" 0 $extract --scan-root "$d/vol/Photos" --scan-root "$d/vol/Extra" --catalog "$d/lr/Multi.lrcat" --out "$work/out_multi"
  mext=("$work"/out_multi/*(/N)); mext="${mext[1]:-$work/out_multi/none}"
  check "multi: manifest lists both roots with per-root counts" 0 $py -I -c "
import json, sys
m = json.load(open(sys.argv[1])); d = sys.argv[2]
roots = [d + '/vol/Photos', d + '/vol/Extra']
pr = m['files']['per_root']
sys.exit(0 if m['scan_roots'] == roots and [pr[r]['rows'] for r in roots] == [9, 2]
         and pr[roots[1]]['size_bytes'] == 5 and 'scan_root' not in m else 1)" "$mext/manifest.json" "$d"
  check "multi: files.csv rel_path relative to its own root" 0 $py -I -c "
import csv, sys
r = {x['name']: x for x in csv.DictReader(open(sys.argv[1], encoding='utf-8'))}['X1.CR2']
sys.exit(0 if (r['rel_path'], r['top_folder'], r['scan_root']) == ('2020/X1.CR2', '2020', sys.argv[2]) else 1)" "$mext/files.csv" "$d/vol/Extra"
  check "multi: no overlap warning when every root is a catalog root" 1 grep -q 'does not overlap' "$mext/extract.log"
  check "multi: analysis" 0 $anash "$mext" --out "$work/ana_multi"
  for metric value in disk_files 11 matched 6 disk_only 5 catalog_only 1 catalog_outside_scan_root 0; do
    check "multi: join $metric = $value" 0 metric_is "$work/ana_multi/join_check.csv" $metric $value
  done
  check "multi: reconciliation adds up" 0 $py -I "$repo/tests/check_reconciliation.py" "$work/ana_multi"
  check "multi: pivot rows per scan root" 0 test "$(dq "$work/ana_multi/analysis.duckdb" -c "SELECT string_agg(scan_root || '=' || n, ' ' ORDER BY scan_root) FROM (SELECT scan_root, count(*) AS n FROM photos_pivot GROUP BY 1)")" = "$d/vol/Extra=2 $d/vol/Photos=10"
  check "multi: folder relative to its own scan root" 0 test "$(dq "$work/ana_multi/analysis.duckdb" -c "SELECT top_folder || '|' || folder || '|' || source || '|' || capture_year FROM photos_pivot WHERE name = 'X1.CR2'")" = "2020|2020|filesystem and catalog|2020"
  check "multi: volume_by_scan_root per root and source" 0 test "$(rq "SELECT string_agg(regexp_extract(scan_root, '[^/]+\$') || ':' || source || '=' || files || '/' || bytes, ' ' ORDER BY scan_root, source) FROM read_csv('$work/ana_multi/reports/volume_by_scan_root.csv', all_varchar = true)")" = "Extra:filesystem and catalog=1/2 Extra:filesystem only=1/3 Photos:catalog only=1/0 Photos:filesystem and catalog=5/11137 Photos:filesystem only=4/16"
  check "multi: volume_by_folder split by scan root" 0 test "$(rq "SELECT count(DISTINCT scan_root) FROM read_csv('$work/ana_multi/reports/volume_by_folder.csv', all_varchar = true)")" = 2


  # Hints, with planted cases on a copy of the database
  mkdir -p "$work/hints" && cp "$ana/analysis.duckdb" "$work/hints/"
  check "pivot: hints computed on planted cases" 0 sh -c "cd '$work/hints' && env -u AI_AGENT -u CLAUDECODE duckdb -bail analysis.duckdb -c \"
    INSERT INTO photos (path, parent, name, ext, size_bytes, on_disk, in_catalog, type_group, catalog_role) VALUES
      ('$d/vol/Photos/2019/IMG_9.CR2', '2019', 'IMG_9.CR2', 'cr2', 25000000, true, false, 'raw', NULL),
      ('$d/vol/Photos/2015/IMG_8.CR2', '2015', 'IMG_8.CR2', 'cr2', 24000000, true, false, 'raw', NULL),
      ('$d/vol/Photos/2015/IMG_8.dng', '2015', 'IMG_8.dng', 'dng', 26000000, true, true, 'raw', 'photo');
    INSERT INTO catalog_entries (file_id, catalog_role, path, match_key, in_scope) VALUES
      (900, 'photo', '/old tree/2018/IMG_9.CR2', '/old tree/2018/img_9.cr2', false)\" -c '.read $repo/analyse/30_pivot.sql' > /dev/null"
  check "pivot: moved? also when the name is only outside the scan root" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT hint || '|' || catalog_folder FROM photos_pivot WHERE name = 'IMG_9.CR2' AND source = 'filesystem only'")" = "moved?|/old tree/2018"
  check "pivot: raw next to its DNG gets dng original?" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT hint FROM photos_pivot WHERE name = 'IMG_8.CR2'")" = "dng original?"
  check "pivot: files without a cause get no hint" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT count(*) FROM photos_pivot WHERE hint IS NOT NULL")" = 2

  # Default output: filed by client and machine, latest per machine
  cl_dir="$work/clients"; anash_c=(env PSA_CLIENTS_DIR="$cl_dir" zsh "$repo/analyse/analyse.sh")
  (cd "$ext" && ls -lR | cksum) > "$work/ext_before_filing.sum"
  check "clients: default output for test/m1" 0 $anash_c "$ext"
  cp "$work/last.out" "$work/clients_m1.out"
  check "clients: analysis filed under client/machine/analysis/extract" 0 test -f "$cl_dir/test/m1/analysis/${ext:t}/photos_pivot.xlsx"
  check "clients: latest per machine holds the folder tree too" 0 test -f "$cl_dir/test/m1/latest/folder_tree.xlsx"
  check "clients: latest per machine holds this extract's pivot file" 0 cmp -s "$cl_dir/test/m1/analysis/${ext:t}/photos_pivot.xlsx" "$cl_dir/test/m1/latest/photos_pivot.xlsx"
  check "clients: summary names client and machine" 0 grep -q 'client: test, machine: m1' "$work/clients_m1.out"
  cp "$cl_dir/test/m1/latest/photos_pivot.xlsx" "$work/latest_m1.xlsx"
  check "clients: second machine of another client" 0 $anash_c "$(oneext "$work/out_set")"
  check "clients: its own latest" 0 test -f "$cl_dir/acme/anna/latest/photos_pivot.xlsx"
  check "clients: latest holds the extract's settings.env, to send back" 0 cmp -s "$sd/two.env" "$cl_dir/acme/anna/latest/settings.env"
  check "clients: no settings.env in latest for an extract without one" 0 test ! -e "$cl_dir/test/m1/latest/settings.env"
  check "clients: other machine's latest unchanged" 0 cmp -s "$work/latest_m1.xlsx" "$cl_dir/test/m1/latest/photos_pivot.xlsx"
  # Filing: the first default analysis copied the extract into its client and machine folder.
  # analyse.sh prints resolved paths (${x:A}); compare with those
  fext="$cl_dir/test/m1/extracts/${ext:t}"
  check "filing: copy filed under client/machine/extracts" 0 test -f "$fext/manifest.json"
  check "filing: copy verifies" 0 $py -I "$repo/analyse/verify.py" "$fext"
  check "filing: copy is complete, no partial copy left" 0 test "$(ls "$cl_dir/test/m1/extracts")" = "${ext:t}"
  check "filing: original unchanged" 0 test "$(cd "$ext" && ls -lR | cksum)" = "$(cat "$work/ext_before_filing.sum")"
  check "filing: output says the original can be removed" 0 grep -qF "the original ${ext:A} can be removed" "$work/clients_m1.out"
  check "filing: analysis reads the filed copy" 0 grep -qF "analysing the filed copy ${fext:A}" "$work/clients_m1.out"
  check "filing: same extract again stops" 1 $anash_c "$ext" --replace
  cp "$work/last.out" "$work/filing_again.out"
  check "filing: names the filed copy" 0 grep -qF "already filed at ${fext:A}" "$work/filing_again.out"
  check "filing: filed extract analyses in place" 0 $anash_c "$fext" --replace
  cp "$work/last.out" "$work/filing_inplace.out"
  check "filing: in place, nothing copied" 1 grep -q 'filing a copy' "$work/filing_inplace.out"
  mkdir -p "$cl_dir/test/other"; cp -R "$fext" "$cl_dir/test/other/${ext:t}"
  check "filing: extract in a wrong place under clients stops" 1 $anash_c "$cl_dir/test/other/${ext:t}"
  cp "$work/last.out" "$work/filing_wrong.out"
  check "filing: says it is not at its own place" 0 grep -q 'not at its own place' "$work/filing_wrong.out"
  check "filing: --out files nothing" 0 sh -c "PSA_CLIENTS_DIR='$work/clients3' zsh '$repo/analyse/analyse.sh' '$ext' --out '$work/ana_nofile' > /dev/null 2>&1 && test ! -e '$work/clients3'"
  # Inbox: an extract written there by ./psa extract is moved out by filing
  inbox="$work/inbox"
  check "inbox: extract writes to PSA_EXTRACTS_DIR" 0 env PSA_EXTRACTS_DIR="$inbox" $extract $args
  iext=("$inbox"/*(/N)); iext="${iext[1]:-$inbox/none}"
  check "inbox: one extract in the inbox" 0 test -f "$iext/manifest.json"
  check "inbox: analysis of the inbox extract" 0 env PSA_EXTRACTS_DIR="$inbox" PSA_CLIENTS_DIR="$work/clients5" zsh "$repo/analyse/analyse.sh" "$iext"
  cp "$work/last.out" "$work/inbox.out"
  check "inbox: filed under client/machine/extracts" 0 $py -I "$repo/analyse/verify.py" "$work/clients5/test/m1/extracts/${iext:t}"
  check "inbox: removed from the inbox after filing" 0 test ! -e "$iext"
  check "inbox: output says so" 0 grep -q 'removed from the inbox' "$work/inbox.out"
  check "inbox: analysis made from the filed copy" 0 test -f "$work/clients5/test/m1/analysis/${iext:t}/photos_pivot.xlsx"
  mkdir -p "$inbox/sub"; cp -R "$ext" "$inbox/sub/"
  check "inbox: extract deeper in the inbox is copied, not removed" 0 sh -c "PSA_EXTRACTS_DIR='$inbox' PSA_CLIENTS_DIR='$work/clients6' zsh '$repo/analyse/analyse.sh' '$inbox/sub/${ext:t}' > /dev/null 2>&1 && test -f '$inbox/sub/${ext:t}/manifest.json'"
  if (( EUID != 0 )); then  # root reads unreadable files, so this runs on CI, not as root
    cp -R "$ext" "$work/unreadable"; print x > "$work/unreadable/zz_extra"; chmod 000 "$work/unreadable/zz_extra"
    check "filing: failed copy stops" 1 env PSA_CLIENTS_DIR="$work/clients4" zsh "$repo/analyse/analyse.sh" "$work/unreadable"
    check "filing: failed copy leaves no partial extract" 0 test -z "$(ls -A "$work/clients4/test/m1/extracts" 2>/dev/null)"
    mv "$work/unreadable" "$inbox/"
    check "inbox: failed copy stops" 1 env PSA_EXTRACTS_DIR="$inbox" PSA_CLIENTS_DIR="$work/clients7" zsh "$repo/analyse/analyse.sh" "$inbox/unreadable"
    check "inbox: failed copy keeps the extract in the inbox" 0 test -f "$inbox/unreadable/manifest.json"
    chmod 644 "$inbox/unreadable/zz_extra"
  fi
  check "clients: --out leaves latest alone" 0 sh -c "PSA_CLIENTS_DIR='$work/clients2' zsh '$repo/analyse/analyse.sh' '$ext' --out '$work/ana_noLatest' > /dev/null 2>&1 && test -f '$work/ana_noLatest/photos_pivot.xlsx' && test ! -e '$work/clients2'"
  # Extracts made by another version are refused, not converted
  cp -R "$ext" "$work/oldschema"
  $py -I -c "
import json, sys
p = sys.argv[1] + '/manifest.json'; m = json.load(open(p))
m['schema'] = 1; json.dump(m, open(p, 'w'), indent=2)" "$work/oldschema"
  check "schema: older extract refused" 1 $anash "$work/oldschema" --out "$work/ana_oldschema"
  cp "$work/last.out" "$work/oldschema.out"
  check "schema: says to extract again" 0 grep -q 'extract again with the current version' "$work/oldschema.out"
  check "schema: refused extract wrote nothing" 0 test ! -e "$work/ana_oldschema"
  check "options: --client is not an analyse option" 1 $anash "$ext" --client test --out "$work/ana_noclient"

  # Usage text: one copy, in the header; every option analyse.sh accepts is in it
  check "usage: no extract given stops" 1 zsh "$repo/analyse/analyse.sh"
  cp "$work/last.out" "$work/usage.out"
  check "usage: says the extract is missing" 0 grep -q 'no extract given' "$work/usage.out"
  opts=(${(f)"$(grep -oE '^ +(-[a-z]\|)?--[a-z-]+\)' "$repo/analyse/analyse.sh" | grep -oE -- '--[a-z-]+')"})
  check "usage: analyse.sh accepts options" 0 test ${#opts} -ge 5
  for o in $opts; do
    check "usage: lists $o" 0 grep -q -- "$o" "$work/usage.out"
  done
  check "usage: --help exits 0 with the usage" 0 sh -c "zsh '$repo/analyse/analyse.sh' --help | grep -q '^Usage:'"
  check "usage: unknown option shows the usage" 0 sh -c "zsh '$repo/analyse/analyse.sh' --nonsense 2>&1 | grep -q '\-\-path-from / \-\-path-to'"

  # Regression check (./psa regress), against a baseline made from the test extract
  rg() {  # rg <baseline> [args...]: run regress, keep output in $work/rg.out
    local b="$1"; shift
    PSA_BASELINE="$b" zsh "$repo/analyse/regress.sh" "$@" > "$work/rg.out" 2>&1
  }
  verdict() { grep '^regression:' "$work/rg.out"; }
  mkbase() { rm -rf "$1"; mkdir -p "$1"; cp -R "$ext" "$1/extract"; cp -R "$ana" "$1/analysis"; }
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
  check "regress: --full prints the full diff" 1 sh -c "PSA_BASELINE='$work/bl' zsh '$repo/analyse/regress.sh' --full > '$work/rg.out' 2>&1"
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
  check "regress: --refresh repairs it" 1 sh -c "printf 'y\\n' | PSA_BASELINE='$work/bl' zsh '$repo/analyse/regress.sh' --refresh > '$work/rg.out' 2>&1"
  check "regress: no differences after the repair" 0 rg "$work/bl"

  mkbase "$work/bl"; rm "$work/bl/analysis/photos_pivot.xlsx"
  check "regress: baseline without pivot file still runs" 0 rg "$work/bl"
  check "regress: says pivot not compared" 0 grep -q "baseline has no photos_pivot.xlsx; not compared" "$work/rg.out"

  check "regress: missing baseline gives exit 2" 2 rg "$work/nobaseline"
  check "regress: says why it could not run" 0 grep -q "^regression: could not run: baseline extract missing" "$work/rg.out"

  mkbase "$work/bl"; sed -i.bak 's/^matched,5$/matched,6/' "$work/bl/analysis/join_check.csv"; rm -f "$work/bl/analysis/join_check.csv.bak"
  extsum=$(cd "$work/bl/extract" && ls -lR | cksum)
  check "regress: --refresh answered n keeps the baseline" 1 sh -c "printf 'n\\n' | PSA_BASELINE='$work/bl' zsh '$repo/analyse/regress.sh' --refresh > '$work/rg.out' 2>&1"
  check "regress: baseline unchanged after n" 0 grep -q '^matched,6$' "$work/bl/analysis/join_check.csv"
  check "regress: --refresh answered y replaces the analysis" 1 sh -c "printf 'y\\n' | PSA_BASELINE='$work/bl' zsh '$repo/analyse/regress.sh' --refresh > '$work/rg.out' 2>&1"
  check "regress: baseline analysis is the new one" 0 grep -q '^matched,5$' "$work/bl/analysis/join_check.csv"
  check "regress: previous analysis kept" 0 sh -c "ls -d '$work/bl'/analysis.* > /dev/null 2>&1 && grep -q '^matched,6$' '$work/bl'/analysis.*/join_check.csv"
  check "regress: baseline extract untouched" 0 test "$(cd "$work/bl/extract" && ls -lR | cksum)" = "$extsum"
  check "regress: after refresh, no differences" 0 rg "$work/bl"
  check "psa: regress command dispatches" 0 sh -c "PSA_BASELINE='$work/bl' zsh '$repo/psa' regress 2>/dev/null | grep -q '^regression: no differences'"

  rid=$($py -I -c "import json,sys; print(json.load(open(sys.argv[1]))['extract_id'])" "$ext/manifest.json")
  check "reports: every report stamped with extract_id" 0 test "$(rq "SELECT count(DISTINCT extract_id) || '/' || min(extract_id) FROM read_csv('$ana/reports/*.csv', union_by_name = true)")" = "1/$rid"
  check "reports: raw = 2 files, 9000 bytes" 0 test "$(rq "SELECT files || '/' || bytes FROM '$ana/reports/volume_by_type.csv' WHERE type_group = 'raw'")" = "2/9000"
  check "reports: by year sums to 9 files" 0 test "$(rq "SELECT sum(files) FROM '$ana/reports/volume_by_year.csv'")" = 9
  check "reports: 2014 = 2 files dated by catalog" 0 test "$(rq "SELECT files || '/' || dated_by_catalog FROM '$ana/reports/volume_by_year.csv' WHERE capture_year = 2014")" = "2/2"
  check "reports: root folder = 3 files" 0 test "$(rq "SELECT files FROM read_csv('$ana/reports/volume_by_folder.csv', all_varchar = true) WHERE top_folder = '(root)'")" = 3
  check "reports: all files in bucket <1 MB" 0 test "$(rq "SELECT bucket || '/' || files FROM '$ana/reports/size_buckets.csv'")" = "<1 MB/9"
  check "reports: not catalogued = 4 files" 0 test "$(rq "SELECT sum(files) FROM '$ana/reports/not_catalogued.csv'")" = 4
  check "reports: missing from disk = GONE.DNG" 0 test "$(rq "SELECT string_agg(regexp_extract(path, '[^/]+\$'), ',') FROM '$ana/reports/missing_from_disk.csv'")" = GONE.DNG
fi

# Scan date: client's local time with UTC offset (fixed zone without DST: +05:30)
check "scan date: extract in another time zone" 0 env TZ=Asia/Kolkata $extract $args --out "$work/out_tz"
tzext=("$work"/out_tz/*(/N)); tzext="${tzext[1]:-$work/out_tz/none}"
check "scan date: manifest has local time with offset, same moment as finished" 0 $py -I -c "
import json, sys, datetime as dt
m = json.load(open(sys.argv[1]))
loc = dt.datetime.fromisoformat(m['finished_local'])
utc = dt.datetime.strptime(m['finished'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
sys.exit(0 if m['finished_local'].endswith('+05:30') and loc == utc else 1)" "$tzext/manifest.json"
check "scan date: analysis of that extract" 0 zsh "$repo/analyse/analyse.sh" "$tzext" --out "$work/ana_tz"
check "scan date: reports show local time with offset" 0 test "$(env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list -c "SELECT count(*) FILTER (WHERE NOT scan_date LIKE '% %:%:%+05:30') || '/' || count(*) FROM read_csv('$work/ana_tz/reports/*.csv', union_by_name = true, all_varchar = true)" | cut -d/ -f1)" = 0

# Transfer (a plain copy) and verify
mkdir -p "$work/recv" "$work/incomplete"; touch "$work/incomplete/files.csv"
cp -R "$ext" "$work/recv/"
recv="$work/recv/${ext:t}"
check "analyse: refuses a folder without manifest" 1 zsh "$repo/analyse/analyse.sh" "$work/incomplete" --out "$work/ana_incomplete"
check "analyse: analyses a copied extract" 0 zsh "$repo/analyse/analyse.sh" "$recv" --out "$work/ana_recv"
check "verify: intact extract passes" 0 $py -I "$repo/analyse/verify.py" "$recv"
print x >> "$recv/files.csv"
check "verify: modified files.csv fails" 1 $py -I "$repo/analyse/verify.py" "$recv"
check "analyse: stops when verification fails" 1 zsh "$repo/analyse/analyse.sh" "$recv" --out "$work/ana_bad"
check "analyse: no output after failed verification" 0 test ! -e "$work/ana_bad"

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
s = s.replace('check-catalog|extract|analyse|regress|status) known=1 ;;', 'check-catalog|extract|analyse|regress|status|hello) known=1 ;;')
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
check "psa: extract runs" 0 zsh "$cl/psa" extract --client test --machine m1 --scan-root "$d/vol/Photos" --catalog "$d/lr/Test.lrcat" --out "$up/out"
pext=("$up"/out/*(/N)); pext="${pext[1]:-$up/out/none}"
uc() { $py -I -c "import json,sys; print(json.load(open(sys.argv[1]))['tool']['update_check']['status'])" "$1/manifest.json"; }
check "manifest: update check recorded by psa" 0 test "$(uc "$pext")" = up_to_date
check "manifest: direct call records not_run" 0 test "$(uc "$ext")" = not_run
check "psa: analyse on the same commit gives no commit warning" 1 sh -c "zsh '$cl/psa' analyse '$pext' --out '$up/ana_same' 2>&1 | grep -q 'extract made with commit'"
check "analyse: warns when the extract was made with another commit" 0 sh -c "zsh '$repo/analyse/analyse.sh' '$pext' --out '$up/ana_other' 2>&1 | grep -q 'extract made with commit'"

# Settings file found by psa
hm="$up/home"; mkdir -p "$hm/photo-analysis"; cp "$sd/two.env" "$hm/photo-analysis/settings.env"
check "psa: default settings file used without arguments" 0 env -u PSA_SETTINGS HOME="$hm" zsh "$cl/psa" extract --out "$up/out_set_default"
check "psa: manifest names the default settings file" 0 test "$(mq "$(oneext "$up/out_set_default")" "m['settings']['file']")" = "\"$hm/photo-analysis/settings.env\""
check "psa: PSA_SETTINGS names another file" 0 env PSA_SETTINGS="$sd/home.env" HOME="$d" zsh "$cl/psa" extract --client test --machine m1 --out "$up/out_set_env"
check "psa: manifest names the PSA_SETTINGS file" 0 test "$(mq "$(oneext "$up/out_set_env")" "m['settings']['file']")" = "\"$sd/home.env\""
check "psa: PSA_SETTINGS empty means no settings file" 1 env PSA_SETTINGS= HOME="$hm" zsh "$cl/psa" extract --out "$up/out_set_off"
cp "$work/last.out" "$up/set_off.out"
check "psa: says there is no scan root" 0 grep -q 'No scan root' "$up/set_off.out"
check "psa: PSA_SETTINGS naming a missing file stops" 1 env PSA_SETTINGS="$sd/none.env" zsh "$cl/psa" extract --out "$up/out_set_off"
check "psa: without a settings file, none is reported" 0 sh -c "env -u PSA_SETTINGS HOME='$up/nohome' zsh '$cl/psa' extract --client test --machine m1 --scan-root '$d/vol/Photos' --skip-catalog --out '$up/out_set_none' 2>&1 | grep -q 'Settings file: none'"
check "psa: check-catalog takes CATALOG from the default file" 0 sh -c "env -u PSA_SETTINGS HOME='$hm' zsh '$cl/psa' check-catalog 2>&1 | grep -qF 'CATALOG from settings file: $d/lr/Multi.lrcat'"
check "psa: stopped settings runs wrote nothing" 0 test ! -e "$up/out_set_off"

print
if (( fails )); then print "$fails check(s) failed"; exit 1; fi
print "all checks passed (sample data kept in $base)"
