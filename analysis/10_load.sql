-- Load a collector run into DuckDB.
--
-- Variables, set before .read:
--   run_dir     received run folder with files.csv, catalog.lrcat, manifest.json (required)
--   catalog     catalog file to read (optional; default run_dir/catalog.lrcat). run.sh
--               passes a working copy: Lightroom catalogs use WAL mode, and opening one
--               makes SQLite create -shm and -wal files next to it
--   types_csv   path to analysis/types.csv (required)
-- Requires a run with a catalog copy (not --skip-catalog).
--
-- Creates: run_info, scan_roots, scan, types, lr_root, lr_folder, lr_file, lr_image
-- Runs collected before multiple scan roots (manifest scan_root, files.csv
-- without a scan_root column) load the same way, with their single root.
-- The catalog is copied into local tables and detached, so later queries do
-- not need the catalog file.

-- scan_date: the client's local time with UTC offset, as text, so it reads the
-- same on any analysis machine. Older manifests have only the UTC time.
CREATE OR REPLACE TEMP TABLE manifest AS
SELECT *
FROM read_json(getvariable('run_dir') || '/manifest.json',
               columns = {'run_id': 'VARCHAR', 'finished': 'VARCHAR', 'finished_local': 'VARCHAR',
                          'scan_root': 'VARCHAR', 'scan_roots': 'VARCHAR[]'});

CREATE OR REPLACE TABLE run_info AS
SELECT run_id,
       coalesce(replace(finished_local, 'T', ' '),
                replace(replace(finished, 'T', ' '), 'Z', '+00:00')) AS scan_date
FROM manifest;

-- One row per scan root; root_lc is the lower-case prefix used for matching
CREATE OR REPLACE TABLE scan_roots AS
SELECT nfc_normalize(rtrim(r, '/')) AS scan_root,
       lower(nfc_normalize(rtrim(r, '/'))) || '/' AS root_lc
FROM manifest, unnest(coalesce(scan_roots, [scan_root])) AS t(r);

-- All columns as text; an older files.csv has no scan_root column, which
-- UNION ALL BY NAME adds as NULL
CREATE OR REPLACE TEMP TABLE files_raw AS
SELECT * FROM read_csv(getvariable('run_dir') || '/files.csv', header = true, all_varchar = true)
UNION ALL BY NAME
SELECT NULL::VARCHAR AS scan_root WHERE false;

CREATE OR REPLACE TABLE scan AS
SELECT
    -- empty CSV fields arrive as NULL; store them as ''
    nfc_normalize(path)                    AS path,
    nfc_normalize(rel_path)                AS rel_path,
    coalesce(nfc_normalize(top_folder), '') AS top_folder,
    coalesce(nfc_normalize(parent), '')    AS parent,
    nfc_normalize(name)                    AS name,
    coalesce(lower(ext), '')               AS ext,
    cast(size_bytes AS BIGINT)             AS size_bytes,
    cast(alloc_bytes AS BIGINT)            AS alloc_bytes,
    try_cast(replace(mtime, 'Z', '') AS TIMESTAMP) AS mtime,
    try_cast(replace(btime, 'Z', '') AS TIMESTAMP) AS btime,
    hidden   = '1' AS hidden,
    dataless = '1' AS dataless,
    symlink  = '1' AS symlink,
    nfc_normalize(rtrim(coalesce(scan_root, (SELECT min(scan_root) FROM scan_roots)), '/')) AS scan_root
FROM files_raw;

CREATE OR REPLACE TABLE types AS
SELECT lower(ext) AS ext, type_group
FROM read_csv(getvariable('types_csv'), header = true,
              columns = {'ext': 'VARCHAR', 'type_group': 'VARCHAR'});

-- Lightroom declares many columns without a type; read everything as text
-- and cast explicitly.
SET sqlite_all_varchar = true;
ATTACH coalesce(getvariable('catalog'), getvariable('run_dir') || '/catalog.lrcat') AS lr (TYPE sqlite, READ_ONLY);

CREATE OR REPLACE TABLE lr_root AS
SELECT cast(id_local AS BIGINT) AS id, absolutePath AS absolute_path
FROM lr.AgLibraryRootFolder;

CREATE OR REPLACE TABLE lr_folder AS
SELECT cast(id_local AS BIGINT) AS id,
       cast(rootFolder AS BIGINT) AS root_id,
       coalesce(pathFromRoot, '') AS path_from_root
FROM lr.AgLibraryFolder;

CREATE OR REPLACE TABLE lr_file AS
SELECT cast(id_local AS BIGINT) AS id,
       cast(folder AS BIGINT) AS folder_id,
       baseName AS base_name,
       coalesce(extension, '') AS extension,
       nullif(sidecarExtensions, '') AS sidecar_extensions
FROM lr.AgLibraryFile;

CREATE OR REPLACE TABLE lr_image AS
SELECT cast(id_local AS BIGINT) AS id,
       cast(rootFile AS BIGINT) AS file_id,
       try_cast(masterImage AS BIGINT) AS master_id,
       nullif(captureTime, '') AS capture_time_raw,
       fileFormat AS file_format,
       try_cast(pick AS DOUBLE) AS pick,
       try_cast(rating AS DOUBLE) AS rating
FROM lr.Adobe_images;

DETACH lr;
