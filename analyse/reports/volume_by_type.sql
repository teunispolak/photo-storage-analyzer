-- Volume by type group, files on disk.
COPY (
    SELECT r.extract_id, r.scan_date, p.type_group,
           count(*) AS files,
           sum(p.size_bytes) AS bytes,
           round(sum(p.size_bytes) / 1e9, 2) AS gb,
           round(100 * sum(p.size_bytes) / sum(sum(p.size_bytes)) OVER (), 1) AS pct_bytes
    FROM photos p, extract_info r
    WHERE p.on_disk
    GROUP BY ALL
    ORDER BY bytes DESC
) TO 'reports/volume_by_type.csv' (HEADER);
