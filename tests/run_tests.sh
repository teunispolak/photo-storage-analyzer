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
collect=($py -I "$repo/collector/collect.py")
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

# Catalog structure check
chk=($py -I "$repo/collector/check_catalog.py")
check "check_catalog: test catalog has the required structure" 0 $chk "$d/lr/Test.lrcat"
check "check_catalog: counts the virtual copy" 0 sh -c "$py -I '$repo/collector/check_catalog.py' '$d/lr/Test.lrcat' | grep -q 'virtual copies: 1'"
check "check_catalog: --show-roots prints the root folder" 0 sh -c "$py -I '$repo/collector/check_catalog.py' '$d/lr/Test.lrcat' --show-roots | grep -qF '$d/vol/Photos/'"
check "check_catalog: no root paths without --show-roots" 1 sh -c "$py -I '$repo/collector/check_catalog.py' '$d/lr/Test.lrcat' | grep -qF '$d/vol/Photos/'"
$py -I -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE AgLibraryRootFolder (id_local, absolutePath)'); c.commit()" "$work/broken.lrcat"
check "check_catalog: fails on a catalog missing tables" 1 $chk "$work/broken.lrcat"

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
check "files.csv has 9 rows" 0 test "$(( $(wc -l < "$run/files.csv") - 1 ))" -eq 9
check "failed preflight wrote nothing" 0 test ! -e "$d/vol/Photos/out" -a ! -e "$d/vol/x"
check "file names are NFC" 0 $py -I -c "
import sys, unicodedata
t = open(sys.argv[1], encoding='utf-8').read()
sys.exit(0 if t == unicodedata.normalize('NFC', t) and 'Café.JPG' in t else 1)" "$run/files.csv"

# Scan root through a symlink: paths differ from the catalog's, collector must warn
ln -s "$d/vol" "$work/vol_link"
check "collector: warns when scan root does not match catalog root" 0 sh -c \
  "$py -I '$repo/collector/collect.py' --scan-root '$work/vol_link/Photos' --catalog '$d/lr/Test.lrcat' --out '$work/out_link' 2>&1 | grep -q 'does not overlap'"
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
  check "run.sh: refuses existing output without --replace" 1 $runsh "$run" --out "$ana"
  check "run.sh: --replace overwrites" 0 $runsh "$run" --out "$ana" --replace
  check "run.sh: refuses output inside the run folder" 1 $runsh "$run" --out "$run/x"
  check "run.sh: refuses output inside the repository" 1 $runsh "$run" --out "$repo/x"
  check "run.sh: --path-from needs --path-to" 1 $runsh "$run" --out "$work/ana_x" --path-from /a
  check "run.sh: join_check.csv written" 0 test -f "$ana/join_check.csv"
  check "run.sh: second run gives identical reports" 0 sh -c "zsh '$repo/analysis/run.sh' '$run' --out '$work/ana2' > /dev/null 2>&1 && diff -r '$ana/reports' '$work/ana2/reports' && diff '$ana/join_check.csv' '$work/ana2/join_check.csv'"

  expected=(
    disk_files 9  catalog_masters 4  catalog_sidecars 2  catalog_duplicate_keys 0
    virtual_copies_excluded 1  matched 5  matched_master 3  matched_sidecar 2
    disk_only 4  catalog_only 1  matched_case_only 1  catalog_paths_nfc_changed 1
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
  check "join: JPEG of RAW+JPEG pair is a catalogued sidecar" 0 test "$(q "SELECT catalog_role FROM photos WHERE name = 'IMG_0100.JPG'")" = sidecar
  check "join: raw capture year from catalog" 0 test "$(q "SELECT capture_year || '/' || date_source FROM photos WHERE name = 'IMG_0001.CR2'")" = "2014/catalog"
  check "join: type groups" 0 test "$(q "SELECT string_agg(name || ':' || type_group, ' ' ORDER BY name) FROM photos WHERE name IN ('.DS_Store','IMG_0001.xmp','IMG_0100.NEF','root.txt')")" = ".DS_Store:system IMG_0001.xmp:sidecar IMG_0100.NEF:raw root.txt:other"

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
  check "catalog columns: minimal catalog loads" 0 load_with "$variants/minimal.lrcat" "$variants/minimal"
  check "catalog columns: minimal catalog gives the same join" 0 diff "$ana/join_check.csv" "$variants/minimal/join_check.csv"
  check "catalog columns: one variant per required column" 0 test ${#cols} -eq 17
  for c in $cols; do
    check "catalog columns: load fails ${c%.lrcat}" 1 load_with "$variants/$c" "$variants/${c%.lrcat}"
  done

  for r in "$repo"/analysis/reports/*.sql; do
    check "reports: ${r:t:r}.csv written" 0 test -f "$ana/reports/${r:t:r}.csv"
  done
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
  check "pivot: status values" 0 test "$(dq "$ana/analysis.duckdb" -c "SELECT string_agg(status || '=' || n, ' ' ORDER BY status) FROM (SELECT status, count(*) AS n FROM photos_pivot GROUP BY 1)")" = "catalog only=1 disk only=4 matched=5"
  check "pivot: catalog files outside the scan root" 0 test "$(dq "$work/ana_mapped/analysis.duckdb" -c "SELECT count(*) FILTER (WHERE top_folder = '(outside scan root)' AND folder IS NULL) || '/' || count(*) FILTER (WHERE status = 'catalog only') FROM photos_pivot")" = "6/6"

  # Hints, with planted cases on a copy of the database
  mkdir -p "$work/hints" && cp "$ana/analysis.duckdb" "$work/hints/"
  check "pivot: hints computed on planted cases" 0 sh -c "cd '$work/hints' && env -u AI_AGENT -u CLAUDECODE duckdb -bail analysis.duckdb -c \"
    INSERT INTO photos (path, parent, name, ext, size_bytes, on_disk, in_catalog, type_group, catalog_role) VALUES
      ('$d/vol/Photos/2019/IMG_9.CR2', '2019', 'IMG_9.CR2', 'cr2', 25000000, true, false, 'raw', NULL),
      ('$d/vol/Photos/2018/IMG_9.CR2', NULL, 'IMG_9.CR2', 'cr2', NULL, false, true, 'raw', 'master'),
      ('$d/vol/Photos/2015/IMG_8.CR2', '2015', 'IMG_8.CR2', 'cr2', 24000000, true, false, 'raw', NULL),
      ('$d/vol/Photos/2015/IMG_8.dng', '2015', 'IMG_8.dng', 'dng', 26000000, true, true, 'raw', 'master')\" -c '.read $repo/analysis/30_pivot.sql' > /dev/null"
  check "pivot: moved file gets moved? and the catalog folder" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT hint || '|' || (catalog_folder = '$d/vol/Photos/2018') FROM photos_pivot WHERE name = 'IMG_9.CR2' AND status = 'disk only'")" = "moved?|true"
  check "pivot: raw next to its DNG gets dng original?" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT hint FROM photos_pivot WHERE name = 'IMG_8.CR2'")" = "dng original?"
  check "pivot: files without a cause get no hint" 0 test "$(dq "$work/hints/analysis.duckdb" -c "SELECT count(*) FROM photos_pivot WHERE hint IS NOT NULL")" = 2

  # latest copy: only with the default output location
  check "pivot: default output copies to latest" 0 sh -c "PSA_ANALYSIS_DIR='$work/base' zsh '$repo/analysis/run.sh' '$run' > /dev/null 2>&1 && test -f '$work/base/${run:t}/photos_pivot.xlsx' && cmp -s '$work/base/${run:t}/photos_pivot.xlsx' '$work/base/latest/photos_pivot.xlsx'"
  check "pivot: --out leaves latest alone" 0 sh -c "PSA_ANALYSIS_DIR='$work/base2' zsh '$repo/analysis/run.sh' '$run' --out '$work/ana_noLatest' > /dev/null 2>&1 && test -f '$work/ana_noLatest/photos_pivot.xlsx' && test ! -e '$work/base2/latest'"

  rq() { env -u AI_AGENT -u CLAUDECODE duckdb -noheader -list -c "$1"; }
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
check "psa: collect runs" 0 zsh "$cl/psa" collect --scan-root "$d/vol/Photos" --catalog "$d/lr/Test.lrcat" --out "$up/out"
prun=("$up"/out/*(/N)); prun="${prun[1]:-$up/out/none}"
uc() { $py -I -c "import json,sys; print(json.load(open(sys.argv[1]))['collector']['update_check']['status'])" "$1/manifest.json"; }
check "manifest: update check recorded by psa" 0 test "$(uc "$prun")" = up_to_date
check "manifest: direct call records not_run" 0 test "$(uc "$run")" = not_run
check "psa: analyse on the same commit gives no commit warning" 1 sh -c "zsh '$cl/psa' analyse '$prun' --out '$up/ana_same' 2>&1 | grep -q 'run collected with commit'"
check "run.sh: warns when the run was collected with another commit" 0 sh -c "zsh '$repo/analysis/run.sh' '$prun' --out '$up/ana_other' 2>&1 | grep -q 'run collected with commit'"

print
if (( fails )); then print "$fails check(s) failed"; exit 1; fi
print "all checks passed (sample data kept in $work)"
