-- Volume by capture year, files on disk, with running total.
-- dated_by_catalog / dated_by_mtime show how each year's date was found.
COPY (
    SELECT r.extract_id, r.scan_date, p.capture_year,
           count(*) AS files,
           sum(p.size_bytes) AS bytes,
           round(sum(p.size_bytes) / 1e9, 2) AS gb,
           round(sum(sum(p.size_bytes)) OVER (ORDER BY p.capture_year) / 1e9, 2) AS cumulative_gb,
           count(*) FILTER (WHERE p.date_source = 'catalog') AS dated_by_catalog,
           count(*) FILTER (WHERE p.date_source = 'mtime') AS dated_by_mtime
    FROM photos p, extract_info r
    WHERE p.on_disk
    GROUP BY r.extract_id, r.scan_date, p.capture_year
    ORDER BY p.capture_year
) TO 'reports/volume_by_year.csv' (HEADER);
