-- Pivot-ready flat file: one row per file, written to photos_pivot.xlsx.
--
-- Run after 20_join.sql, from inside the output folder.
-- Creates: view photos_located (photos with source and folder columns relative
--          to each file's scan root,
--          used by photos_pivot and reports/reconciliation.sql)
--          view photos_pivot (columns as in analyse/pivot_columns.csv)
-- Writes:  photos_pivot.xlsx, sheet "photos"
-- Needs DuckDB's excel extension; installed on first use.

INSTALL excel;
LOAD excel;

CREATE OR REPLACE VIEW photos_located AS
WITH p AS (
    -- paths relative to each file's own scan root
    SELECT ph.*,
        regexp_replace(ph.path, '/[^/]+$', '') AS folder_path,
        CASE WHEN ph.scan_root IS NOT NULL
              AND starts_with(lower(ph.path), lower(ph.scan_root) || '/')
             THEN substr(ph.path, length(ph.scan_root) + 2) END AS rel_path_any
    FROM photos ph
),
q AS (
    -- folder relative to the scan root: NULL outside it, '' for the root itself
    SELECT *,
        CASE WHEN rel_path_any IS NULL THEN NULL
             WHEN NOT contains(rel_path_any, '/') THEN ''
             ELSE regexp_replace(rel_path_any, '/[^/]+$', '') END AS rel_folder
    FROM p
)
SELECT q.*,
    CASE WHEN on_disk AND in_catalog THEN 'filesystem and catalog'
         WHEN on_disk THEN 'filesystem only' ELSE 'catalog only' END AS source
FROM q;

CREATE OR REPLACE VIEW photos_pivot AS
WITH q AS (SELECT * FROM photos_located),
moved AS (  -- same name in the whole catalog (also outside the scan root), not on disk there
    SELECT lower(regexp_extract(c.path, '[^/]+$')) AS lname,
           min(regexp_replace(c.path, '/[^/]+$', '')) AS catalog_folder
    FROM catalog_entries c
    WHERE NOT EXISTS (SELECT 1 FROM scan s WHERE lower(s.path) = c.match_key)
    GROUP BY 1
)
SELECT
    q.source,
    q.type_group,
    q.ext,
    q.capture_year,
    q.date_source,
    CASE WHEN q.rel_folder IS NULL THEN '(outside scan root)'
         WHEN q.rel_folder = '' THEN '(root)'
         ELSE split_part(q.rel_folder, '/', 1) END AS top_folder,
    CASE WHEN q.rel_folder = '' THEN '(root)' ELSE q.rel_folder END AS folder,
    -- the folder directly below top_folder; empty directly in a top folder or the scan root
    nullif(split_part(q.rel_folder, '/', 2), '') AS subfolder,
    q.folder_path,
    q.name,
    round(q.size_bytes / 1e6, 1) AS size_mb,
    q.catalog_role,
    q.lr_file_format,
    q.pick,
    q.rating,
    CASE WHEN q.on_disk AND NOT q.in_catalog AND m.lname IS NOT NULL THEN 'moved?' END AS hint,
    CASE WHEN q.on_disk AND NOT q.in_catalog THEN m.catalog_folder END AS catalog_folder,
    q.scan_root,
    year(q.last_modified) AS last_modified_year,
    year(q.touch_time) AS last_touched_year,
    year(q.last_edited) AS last_edited_year
FROM q LEFT JOIN moved m ON m.lname = lower(q.name);

COPY (SELECT * FROM photos_pivot ORDER BY folder_path, name)
TO 'photos_pivot.xlsx' (FORMAT xlsx, HEADER true, SHEET 'photos');
