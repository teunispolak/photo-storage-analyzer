-- Files on disk that are not in the catalog (as photo or attached file),
-- by type group and year.
COPY (
    SELECT r.extract_id, r.scan_date, p.type_group, p.capture_year,
           count(*) AS files,
           sum(p.size_bytes) AS bytes,
           round(sum(p.size_bytes) / 1e9, 2) AS gb
    FROM photos p, extract_info r
    WHERE p.on_disk AND NOT p.in_catalog
    GROUP BY ALL
    ORDER BY bytes DESC
) TO 'reports/not_catalogued.csv' (HEADER);
