-- Reconciliation: all files known to the scan or the catalog, split level by
-- level. Each line's files add up to its parent (category path one level up).
-- Volume (bytes) only for files on disk. Virtual copies on a separate line
-- without a level: they are catalog images that share a file, not files.
COPY (
    WITH lines(sort, level, category) AS (VALUES
        ( 1, 0, 'all files'),
        ( 2, 1, 'on disk'),
        ( 3, 2, 'on disk/matched'),
        ( 4, 3, 'on disk/matched/photo'),
        ( 5, 3, 'on disk/matched/attached'),
        ( 6, 2, 'on disk/disk only'),
        ( 7, 1, 'catalog only'),
        ( 8, 2, 'catalog only/outside scan root'),
        ( 9, 3, 'catalog only/outside scan root/photo'),
        (10, 3, 'catalog only/outside scan root/attached'),
        (11, 2, 'catalog only/in scan root'),
        (12, 3, 'catalog only/in scan root/photo'),
        (13, 3, 'catalog only/in scan root/attached')
    ),
    files AS (  -- every category path each file belongs to
        SELECT size_bytes, unnest([
            'all files',
            CASE WHEN on_disk THEN 'on disk' ELSE 'catalog only' END,
            CASE WHEN on_disk THEN 'on disk/' || status
                 ELSE 'catalog only/' || location END,
            CASE WHEN status = 'matched' THEN 'on disk/matched/' || catalog_role
                 WHEN status = 'catalog only' THEN 'catalog only/' || location || '/' || catalog_role END
        ]) AS category
        FROM photos_located
    ),
    counted AS (
        SELECT category, count(*) AS files, sum(size_bytes) AS bytes
        FROM files WHERE category IS NOT NULL GROUP BY category
    ),
    body AS (
        SELECT l.sort, l.level, l.category,
               coalesce(c.files, 0) AS files,
               CASE WHEN l.category LIKE 'catalog only%' THEN NULL
                    ELSE coalesce(c.bytes, 0) END AS bytes
        FROM lines l LEFT JOIN counted c USING (category)
        UNION ALL
        SELECT 99, NULL, 'virtual copies (not files)',
               (SELECT count(*) FROM lr_image WHERE master_id IS NOT NULL), NULL
    )
    SELECT r.run_id, r.scan_date, b.level, b.category, b.files, b.bytes,
           round(b.bytes / 1e9, 2) AS gb
    FROM body b, run_info r
    ORDER BY b.sort
) TO 'reports/reconciliation.csv' (HEADER);
