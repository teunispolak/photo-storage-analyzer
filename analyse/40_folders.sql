-- Folder tree with branch totals, for archive candidates.
--
-- One row per folder at every depth, per scan root, including the scan root
-- itself ('(root)', depth 0). Sizes and counts are for the whole branch;
-- direct_bytes and direct_size_mb are for the files directly in the folder.
--
-- parent_max_year is the later of the parent folder's two year maxima (empty
-- for the scan root): own years up to a cut-off and parent_max_year after it
-- select the outermost branches, which do not overlap.
--
-- Files on disk only: catalog-only entries take no space. The year maxima
-- leave out system files (.DS_Store, ._*, Icon\r), which Finder and Dropbox
-- rewrite when a folder is opened or synced; counts and sizes include them.
--
-- Requires: photos_located (30_pivot.sql), extract_info.
-- Creates: folder_tree; writes folder_tree.xlsx and reports/folder_tree.csv.

INSTALL excel;
LOAD excel;

CREATE OR REPLACE TABLE folder_tree AS
WITH tree AS (
WITH f AS (
    SELECT scan_root,
           CASE WHEN coalesce(rel_folder, '') = '' THEN [] ELSE string_split(rel_folder, '/') END AS parts,
           size_bytes,
           type_group <> 'system' AS counts_for_years,
           capture_year,
           year(last_edited) AS last_edited_year
    FROM photos_located
    WHERE on_disk
),
-- each file once per ancestor: depth 0 is the scan root, depth k the first k parts
anc AS (
    SELECT f.*, k AS depth, k = len(parts) AS direct
    FROM f, unnest(range(0, len(parts) + 1)) AS t(k)
)
SELECT
    scan_root,
    CASE WHEN depth = 0 THEN '(root)' ELSE array_to_string(parts[1:depth], '/') END AS folder,
    depth,
    count(*) AS files,
    sum(size_bytes) AS bytes,
    coalesce(sum(size_bytes) FILTER (WHERE direct), 0) AS direct_bytes,
    round(sum(size_bytes) / 1e6, 1) AS size_mb,
    round(coalesce(sum(size_bytes) FILTER (WHERE direct), 0) / 1e6, 1) AS direct_size_mb,
    max(capture_year) FILTER (WHERE counts_for_years) AS max_capture_year,
    max(last_edited_year) FILTER (WHERE counts_for_years) AS max_last_edited_year
FROM anc
GROUP BY scan_root, depth, folder
)
-- The parent's year maxima: a branch with its own years up to a cut-off and its
-- parent's after it is the outermost branch to move, so rows can be added up
SELECT t.*,
       -- the later of the parent's two years; one column, so one filter
       CASE WHEN p.max_capture_year IS NULL THEN p.max_last_edited_year
            WHEN p.max_last_edited_year IS NULL THEN p.max_capture_year
            ELSE greatest(p.max_capture_year, p.max_last_edited_year) END AS parent_max_year
FROM tree t
LEFT JOIN tree p
  ON p.scan_root = t.scan_root AND p.depth = t.depth - 1
 AND p.folder = CASE WHEN t.depth = 1 THEN '(root)'
                     ELSE regexp_replace(t.folder, '/[^/]+$', '') END;

COPY (
    SELECT r.extract_id, r.scan_date, t.*
    FROM folder_tree t, extract_info r
    ORDER BY t.scan_root, t.folder
) TO 'folder_tree.xlsx' (FORMAT xlsx, HEADER true, SHEET 'folders');

COPY (
    SELECT r.extract_id, r.scan_date, t.*
    FROM folder_tree t, extract_info r
    ORDER BY t.scan_root, t.folder
) TO 'reports/folder_tree.csv' (HEADER);
