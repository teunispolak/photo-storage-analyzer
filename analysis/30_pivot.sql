-- Pivot-ready flat file: one row per file, written to photos_pivot.xlsx.
--
-- Run after 20_join.sql, from inside the output folder.
-- Creates: view photos_located (photos with status, location and folder columns,
--          used by photos_pivot and reports/reconciliation.sql)
--          view photos_pivot (columns as in analysis/pivot_columns.csv)
-- Writes:  photos_pivot.xlsx, sheet "photos"
-- Needs DuckDB's excel extension; installed on first use.

INSTALL excel;
LOAD excel;

CREATE OR REPLACE VIEW photos_located AS
WITH r AS (
    SELECT rtrim(scan_root, '/') || '/' AS root FROM run_info
),
p AS (
    SELECT ph.*,
        regexp_replace(ph.path, '/[^/]+$', '') AS folder_path,
        regexp_replace(lower(ph.name), '\.[^.]+$', '') AS stem,
        CASE WHEN starts_with(lower(ph.path), lower(r.root))
             THEN substr(ph.path, length(r.root) + 1) END AS rel_path_any
    FROM photos ph, r
),
q AS (
    -- folder relative to the scan root: NULL outside it, '' for the root itself
    SELECT *,
        CASE WHEN rel_path_any IS NULL THEN NULL
             WHEN NOT contains(rel_path_any, '/') THEN ''
             ELSE regexp_replace(rel_path_any, '/[^/]+$', '') END AS rel_folder
    FROM p
)
SELECT *,
    CASE WHEN on_disk AND in_catalog THEN 'matched'
         WHEN on_disk THEN 'disk only' ELSE 'catalog only' END AS status,
    CASE WHEN rel_folder IS NULL THEN 'outside scan root' ELSE 'in scan root' END AS location
FROM q;

CREATE OR REPLACE VIEW photos_pivot AS
WITH q AS (SELECT * FROM photos_located),
moved AS (  -- same name in the catalog, not on disk there
    SELECT lower(name) AS lname, min(folder_path) AS catalog_folder
    FROM q WHERE in_catalog AND NOT on_disk GROUP BY 1
),
dng AS (    -- same base name catalogued as a photo in the same folder
    SELECT DISTINCT folder_path, stem, ext FROM q
    WHERE on_disk AND in_catalog AND catalog_role = 'photo'
)
SELECT
    q.status,
    q.type_group,
    q.ext,
    q.capture_year,
    q.date_source,
    CASE WHEN q.rel_folder IS NULL THEN '(outside scan root)'
         WHEN q.rel_folder = '' THEN '(root)'
         ELSE split_part(q.rel_folder, '/', 1) END AS top_folder,
    CASE WHEN q.rel_folder = '' THEN '(root)' ELSE q.rel_folder END AS folder,
    q.folder_path,
    q.name,
    round(q.size_bytes / 1e6, 1) AS size_mb,
    q.catalog_role,
    q.lr_file_format,
    q.pick,
    q.rating,
    CASE WHEN q.on_disk AND NOT q.in_catalog AND m.lname IS NOT NULL THEN 'moved?'
         WHEN q.on_disk AND NOT q.in_catalog AND EXISTS (
             SELECT 1 FROM dng d
             WHERE d.folder_path = q.folder_path AND d.stem = q.stem AND d.ext <> q.ext)
         THEN 'dng original?' END AS hint,
    CASE WHEN q.on_disk AND NOT q.in_catalog THEN m.catalog_folder END AS catalog_folder,
    q.location
FROM q LEFT JOIN moved m ON m.lname = lower(q.name);

COPY (SELECT * FROM photos_pivot ORDER BY folder_path, name)
TO 'photos_pivot.xlsx' (FORMAT xlsx, HEADER true, SHEET 'photos');
