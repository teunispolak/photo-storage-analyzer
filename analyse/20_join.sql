-- Join the filesystem scan and the Lightroom catalog into the photos table.
--
-- Run after 10_load.sql, from inside the output folder. Optional variables:
--   path_from, path_to   replace the prefix path_from with path_to in
--                        catalog paths, for a volume mounted under another
--                        name than the catalog expects
--
-- Creates: catalog_entries (all catalog files, with in_scope and scan_root),
--          photos (files under the scan roots only, with scan_root), join_check
-- Scope: the scan roots. Catalog entries outside all of them are counted in
-- join_check (catalog_outside_scan_root) and left out of photos. The extract
-- refuses nested roots, so a path is under one root at most.
-- Writes:  join_check.csv in the current folder

-- Catalog paths -------------------------------------------------------------

CREATE OR REPLACE TEMP TABLE lr_base AS
SELECT
    f.id AS file_id,
    r.absolute_path || fo.path_from_root || f.base_name AS stem_raw,
    f.extension,
    f.sidecar_extensions
FROM lr_file f
JOIN lr_folder fo ON fo.id = f.folder_id
JOIN lr_root r    ON r.id = fo.root_id;

-- The image record per file; virtual copies (master_id set) are left out
CREATE OR REPLACE TEMP TABLE lr_photo AS
SELECT * FROM lr_image WHERE master_id IS NULL
QUALIFY row_number() OVER (PARTITION BY file_id ORDER BY id) = 1;

-- One row per file Lightroom knows: the photo file (role 'photo'), plus each
-- file listed in sidecarExtensions (role 'attached': xmp, and the JPEG of a
-- RAW+JPEG pair)
CREATE OR REPLACE TEMP TABLE lr_entries_raw AS
SELECT b.file_id, 'photo' AS catalog_role,
       b.stem_raw || CASE WHEN b.extension <> '' THEN '.' || b.extension ELSE '' END AS path_raw
FROM lr_base b
UNION ALL
SELECT b.file_id, 'attached' AS catalog_role,
       b.stem_raw || '.' || trim(s.ext) AS path_raw
FROM lr_base b,
     unnest(string_split(b.sidecar_extensions, ',')) AS s(ext)
WHERE b.sidecar_extensions IS NOT NULL AND trim(s.ext) <> '';

CREATE OR REPLACE TEMP TABLE lr_entries AS
WITH mapped AS (
    SELECT *,
        nfc_normalize(path_raw) AS path_nfc,
        coalesce(getvariable('path_from'), '') AS pfrom,
        coalesce(getvariable('path_to'), '') AS pto
    FROM lr_entries_raw
)
SELECT
    file_id, catalog_role, path_raw,
    path_nfc <> path_raw AS nfc_changed,
    pfrom <> '' AND starts_with(path_nfc, pfrom) AS prefix_mapped,
    CASE WHEN pfrom <> '' AND starts_with(path_nfc, pfrom)
         THEN pto || substr(path_nfc, length(pfrom) + 1)
         ELSE path_nfc END AS path
FROM mapped;

-- Deduplicate on the match key; a photo wins over an attached file
CREATE OR REPLACE TABLE catalog_entries AS
SELECT
    e.*,
    lower(e.path) AS match_key,
    r.scan_root IS NOT NULL AS in_scope,
    r.scan_root,
    m.id AS lr_image_id,
    m.file_format AS lr_file_format,
    try_cast(substr(m.capture_time_raw, 1, 19) AS TIMESTAMP) AS capture_time,
    m.pick, m.rating,
    m.touch_time,
    f.mod_time AS catalog_mod_time   -- of the photo file; also used for its attached files
FROM lr_entries e
LEFT JOIN lr_photo m ON m.file_id = e.file_id
LEFT JOIN lr_file f  ON f.id = e.file_id
LEFT JOIN scan_roots r ON starts_with(lower(e.path), r.root_lc)
QUALIFY row_number() OVER (PARTITION BY lower(e.path)
                           ORDER BY (e.catalog_role = 'photo') DESC, e.file_id) = 1;

-- Join ----------------------------------------------------------------------

CREATE OR REPLACE TABLE photos AS
WITH disk AS (
    SELECT *, lower(path) AS match_key FROM scan
),
joined AS (
    SELECT
        coalesce(d.match_key, c.match_key) AS match_key,
        coalesce(d.path, c.path) AS path,
        d.rel_path, d.top_folder, d.parent,
        coalesce(d.name, regexp_extract(c.path, '[^/]+$')) AS name,
        coalesce(d.ext, lower(regexp_extract(c.path, '\.([^./]+)$', 1))) AS ext,
        d.size_bytes, d.alloc_bytes, d.mtime, d.btime,
        d.hidden, d.dataless, d.symlink,
        coalesce(d.scan_root, c.scan_root) AS scan_root,
        d.path IS NOT NULL AS on_disk,
        c.path IS NOT NULL AS in_catalog,
        c.catalog_role,
        d.path IS NOT NULL AND c.path IS NOT NULL AND d.path <> c.path AS case_only_match,
        c.nfc_changed, c.prefix_mapped,
        c.lr_image_id, c.lr_file_format, c.capture_time, c.pick, c.rating,
        c.touch_time, c.catalog_mod_time
    FROM disk d
    FULL OUTER JOIN (SELECT * FROM catalog_entries WHERE in_scope) c ON c.match_key = d.match_key
)
SELECT
    j.*,
    CASE
        WHEN j.name IN ('.DS_Store', 'Thumbs.db', 'desktop.ini', 'Icon' || chr(13))
          OR starts_with(j.name, '._') THEN 'system'
        WHEN j.name IN ('.dropbox', '.dropbox.attr')
          OR starts_with(j.rel_path, '.dropbox.cache/') THEN 'dropbox'
        ELSE coalesce(t.type_group, 'other')
    END AS type_group,
    coalesce(j.capture_time, j.mtime) AS capture_date,
    year(coalesce(j.capture_time, j.mtime)) AS capture_year,
    CASE WHEN j.capture_time IS NOT NULL THEN 'catalog'
         WHEN j.mtime IS NOT NULL THEN 'mtime'
         ELSE 'none' END AS date_source,
    -- Last modification: on disk if there, else as the catalog recorded it
    coalesce(j.mtime, j.catalog_mod_time) AS last_modified,
    -- Last edit: the later of last modification and last Lightroom edit
    CASE WHEN coalesce(j.mtime, j.catalog_mod_time) IS NULL THEN j.touch_time
         WHEN j.touch_time IS NULL THEN coalesce(j.mtime, j.catalog_mod_time)
         ELSE greatest(coalesce(j.mtime, j.catalog_mod_time), j.touch_time) END AS last_edited
FROM joined j
LEFT JOIN types t ON t.ext = j.ext;

-- Join check ------------------------------------------------------------------

CREATE OR REPLACE TABLE join_check AS
SELECT * FROM (VALUES
    ('disk_files',              (SELECT count(*) FROM scan)),
    ('disk_bytes',              (SELECT coalesce(sum(size_bytes), 0) FROM scan)),
    ('catalog_photos',          (SELECT count(*) FROM lr_entries WHERE catalog_role = 'photo')),
    ('catalog_attached',        (SELECT count(*) FROM lr_entries WHERE catalog_role = 'attached')),
    ('catalog_duplicate_keys',  (SELECT count(*) FROM lr_entries) - (SELECT count(*) FROM catalog_entries)),
    ('virtual_copies_excluded', (SELECT count(*) FROM lr_image WHERE master_id IS NOT NULL)),
    ('matched',                 (SELECT count(*) FROM photos WHERE on_disk AND in_catalog)),
    ('matched_photo',           (SELECT count(*) FROM photos WHERE on_disk AND catalog_role = 'photo')),
    ('matched_attached',        (SELECT count(*) FROM photos WHERE on_disk AND catalog_role = 'attached')),
    ('disk_only',               (SELECT count(*) FROM photos WHERE on_disk AND NOT in_catalog)),
    ('catalog_only',            (SELECT count(*) FROM photos WHERE in_catalog AND NOT on_disk)),
    ('catalog_outside_scan_root', (SELECT count(*) FROM catalog_entries WHERE NOT in_scope)),
    ('matched_case_only',       (SELECT count(*) FROM photos WHERE case_only_match)),
    ('catalog_paths_nfc_changed', (SELECT count(*) FROM lr_entries WHERE nfc_changed)),
    ('catalog_paths_prefix_mapped', (SELECT count(*) FROM lr_entries WHERE prefix_mapped)),
    ('date_source_catalog',     (SELECT count(*) FROM photos WHERE date_source = 'catalog')),
    ('date_source_mtime',       (SELECT count(*) FROM photos WHERE date_source = 'mtime')),
    ('date_source_none',        (SELECT count(*) FROM photos WHERE date_source = 'none'))
) AS m(metric, value);

COPY join_check TO 'join_check.csv' (HEADER);
