-- Load an extract into DuckDB.
--
-- Variables, set before .read:
--   extract_dir received extract folder with files.csv, catalog.lrcat, manifest.json (required)
--   catalog     catalog file to read (optional; default extract_dir/catalog.lrcat). analyse.sh
--               passes a working copy: Lightroom catalogs use WAL mode, and opening one
--               makes SQLite create -shm and -wal files next to it
--   types_csv   path to analyse/types.csv (required)
-- Requires an extract with a catalog copy (not --skip-catalog), of the manifest
-- schema verify.py checks.
--
-- Creates: extract_info, scan_roots, scan, types, lr_root, lr_folder, lr_file, lr_image
-- The catalog is copied into local tables and detached, so later queries do
-- not need the catalog file.

-- scan_date: the client's local time with UTC offset, as text, so it reads the
-- same on any analysis machine.
CREATE OR REPLACE TEMP TABLE manifest AS
SELECT *
FROM read_json(getvariable('extract_dir') || '/manifest.json',
               columns = {'extract_id': 'VARCHAR', 'finished_local': 'VARCHAR',
                          'scan_roots': 'VARCHAR[]'});

CREATE OR REPLACE TABLE extract_info AS
SELECT extract_id, replace(finished_local, 'T', ' ') AS scan_date
FROM manifest;

-- One row per scan root; root_lc is the lower-case prefix used for matching
CREATE OR REPLACE TABLE scan_roots AS
SELECT nfc_normalize(rtrim(r, '/')) AS scan_root,
       lower(nfc_normalize(rtrim(r, '/'))) || '/' AS root_lc
FROM manifest, unnest(scan_roots) AS t(r);

-- All columns as text, cast below
CREATE OR REPLACE TEMP TABLE files_raw AS
SELECT * FROM read_csv(getvariable('extract_dir') || '/files.csv', header = true, all_varchar = true);

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
    nfc_normalize(rtrim(scan_root, '/'))  AS scan_root
FROM files_raw;

CREATE OR REPLACE TABLE types AS
SELECT lower(ext) AS ext, type_group
FROM read_csv(getvariable('types_csv'), header = true,
              columns = {'ext': 'VARCHAR', 'type_group': 'VARCHAR'});

-- Lightroom declares many columns without a type; read everything as text
-- and cast explicitly.
SET sqlite_all_varchar = true;
ATTACH coalesce(getvariable('catalog'), getvariable('extract_dir') || '/catalog.lrcat') AS lr (TYPE sqlite, READ_ONLY);

CREATE OR REPLACE TABLE lr_root AS
SELECT cast(id_local AS BIGINT) AS id, absolutePath AS absolute_path
FROM lr.AgLibraryRootFolder;

CREATE OR REPLACE TABLE lr_folder AS
SELECT cast(id_local AS BIGINT) AS id,
       cast(rootFolder AS BIGINT) AS root_id,
       coalesce(pathFromRoot, '') AS path_from_root
FROM lr.AgLibraryFolder;

-- Lightroom stores modTime and touchTime as seconds since 2001-01-01 (UTC);
-- 0 or empty means not set
CREATE OR REPLACE MACRO lr_time(s) AS
    CASE WHEN try_cast(s AS DOUBLE) > 0
         THEN TIMESTAMP '2001-01-01 00:00:00'
              + to_microseconds(cast(round(try_cast(s AS DOUBLE) * 1e6) AS BIGINT)) END;

CREATE OR REPLACE TABLE lr_file AS
SELECT cast(id_local AS BIGINT) AS id,
       cast(folder AS BIGINT) AS folder_id,
       baseName AS base_name,
       coalesce(extension, '') AS extension,
       nullif(sidecarExtensions, '') AS sidecar_extensions,
       lr_time(modTime) AS mod_time   -- file modification date as Lightroom recorded it
FROM lr.AgLibraryFile;

CREATE OR REPLACE TABLE lr_image AS
SELECT cast(id_local AS BIGINT) AS id,
       cast(rootFile AS BIGINT) AS file_id,
       try_cast(masterImage AS BIGINT) AS master_id,
       nullif(captureTime, '') AS capture_time_raw,
       fileFormat AS file_format,
       try_cast(pick AS DOUBLE) AS pick,
       try_cast(rating AS DOUBLE) AS rating,
       lr_time(touchTime) AS touch_time  -- last edit in Lightroom, metadata included
FROM lr.Adobe_images;

DETACH lr;
