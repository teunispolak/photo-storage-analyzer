-- Files the catalog knows that are not on disk, one row per file.
COPY (
    SELECT r.run_id, r.scan_date, p.path, p.catalog_role, p.lr_file_format,
           p.capture_year, p.type_group
    FROM photos p, run_info r
    WHERE p.in_catalog AND NOT p.on_disk
    ORDER BY p.path
) TO 'reports/missing_from_disk.csv' (HEADER);
