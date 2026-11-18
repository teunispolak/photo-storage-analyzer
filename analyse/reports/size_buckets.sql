-- File count and volume by file size bucket, files on disk.
-- Decimal units (1 MB = 1,000,000 bytes), as storage providers price.
COPY (
    WITH b AS (
        SELECT *,
            CASE WHEN size_bytes < 1e6   THEN 1
                 WHEN size_bytes < 1e7   THEN 2
                 WHEN size_bytes < 5e7   THEN 3
                 WHEN size_bytes < 1e8   THEN 4
                 WHEN size_bytes < 1e9   THEN 5
                 ELSE 6 END AS bucket_order
        FROM photos WHERE on_disk
    )
    SELECT r.extract_id, r.scan_date, b.bucket_order,
           ['<1 MB', '1-10 MB', '10-50 MB', '50-100 MB', '100 MB-1 GB', '>1 GB'][b.bucket_order] AS bucket,
           count(*) AS files,
           sum(b.size_bytes) AS bytes,
           round(sum(b.size_bytes) / 1e9, 2) AS gb
    FROM b, extract_info r
    GROUP BY ALL
    ORDER BY b.bucket_order
) TO 'reports/size_buckets.csv' (HEADER);
