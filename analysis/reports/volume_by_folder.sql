-- Volume by top-level folder under the scan root, files on disk.
COPY (
    SELECT r.run_id, r.scan_date,
           CASE WHEN p.top_folder = '' THEN '(root)' ELSE p.top_folder END AS top_folder,
           count(*) AS files,
           sum(p.size_bytes) AS bytes,
           round(sum(p.size_bytes) / 1e9, 2) AS gb,
           round(100 * sum(p.size_bytes) / sum(sum(p.size_bytes)) OVER (), 1) AS pct_bytes
    FROM photos p, run_info r
    WHERE p.on_disk
    GROUP BY ALL
    ORDER BY bytes DESC
) TO 'reports/volume_by_folder.csv' (HEADER);
