-- Load a collector run into DuckDB.
--
-- Variables, set before .read:
--   run_dir     received run folder with files.csv, catalog.lrcat, manifest.json (required)
--   types_csv   path to analysis/types.csv (required)
-- Requires a run with a catalog copy (not --skip-catalog).
--
-- Creates: run_info, scan, types, lr_root, lr_folder, lr_file, lr_image
-- The catalog is copied into local tables and detached, so later queries do
-- not need the catalog file.

-- scan_date: the client's local time with UTC offset, as text, so it reads the
-- same on any analysis machine. Older manifests have only the UTC time.
CREATE OR REPLACE TABLE run_info AS
SELECT run_id,
       coalesce(replace(finished_local, 'T', ' '),
                replace(replace(finished, 'T', ' '), 'Z', '+00:00')) AS scan_date,
       scan_root
FROM read_json(getvariable('run_dir') || '/manifest.json',
               columns = {'run_id': 'VARCHAR', 'finished': 'VARCHAR', 'finished_local': 'VARCHAR',
                          'scan_root': 'VARCHAR'});

CREATE OR REPLACE TABLE scan AS
SELECT
    -- empty CSV fields arrive as NULL; store them as ''
    nfc_normalize(path)                    AS path,
    nfc_normalize(rel_path)                AS rel_path,
    coalesce(nfc_normalize(top_folder), '') AS top_folder,
    coalesce(nfc_normalize(parent), '')    AS parent,
    nfc_normalize(name)                    AS name,
    coalesce(lower(ext), '')               AS ext,
    size_bytes,
    alloc_bytes,
    try_cast(replace(mtime, 'Z', '') AS TIMESTAMP) AS mtime,
    try_cast(replace(btime, 'Z', '') AS TIMESTAMP) AS btime,
    hidden   = 1 AS hidden,
    dataless = 1 AS dataless,
    symlink  = 1 AS symlink
FROM read_csv(getvariable('run_dir') || '/files.csv',
    header = true,
    columns = {
        'path': 'VARCHAR', 'rel_path': 'VARCHAR', 'top_folder': 'VARCHAR',
        'parent': 'VARCHAR', 'name': 'VARCHAR', 'ext': 'VARCHAR',
        'size_bytes': 'BIGINT', 'alloc_bytes': 'BIGINT',
        'mtime': 'VARCHAR', 'btime': 'VARCHAR',
        'hidden': 'INTEGER', 'dataless': 'INTEGER', 'symlink': 'INTEGER'
    });

CREATE OR REPLACE TABLE types AS
SELECT lower(ext) AS ext, type_group
FROM read_csv(getvariable('types_csv'), header = true,
              columns = {'ext': 'VARCHAR', 'type_group': 'VARCHAR'});

-- Lightroom declares many columns without a type; read everything as text
-- and cast explicitly.
SET sqlite_all_varchar = true;
ATTACH getvariable('run_dir') || '/catalog.lrcat' AS lr (TYPE sqlite, READ_ONLY);

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
