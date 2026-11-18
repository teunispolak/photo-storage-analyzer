-- Volume by scan root and source: files on disk, and catalog entries under
-- the root that are not on disk (no size).
COPY (
    SELECT r.extract_id, r.scan_date, p.scan_root,
           CASE WHEN p.on_disk AND p.in_catalog THEN 'filesystem and catalog'
                WHEN p.on_disk THEN 'filesystem only' ELSE 'catalog only' END AS source,
           count(*) AS files,
           coalesce(sum(p.size_bytes), 0) AS bytes,
           round(coalesce(sum(p.size_bytes), 0) / 1e9, 2) AS gb
    FROM photos p, extract_info r
    GROUP BY ALL
    ORDER BY p.scan_root, source
) TO 'reports/volume_by_scan_root.csv' (HEADER);
