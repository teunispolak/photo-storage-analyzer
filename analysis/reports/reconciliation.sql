-- Reconciliation: all files in scope (under the scan root), split level by
-- level. Each line's files add up to its parent (category path one level up).
-- Volume (bytes) only for files found in the filesystem.
-- Two lines without a level, outside the tree: catalog entries outside the
-- scan root (not analysed), and virtual copies (catalog images sharing a file).
COPY (
    WITH lines(sort, level, category) AS (VALUES
        ( 1, 0, 'all files'),
        ( 2, 1, 'filesystem'),
        ( 3, 2, 'filesystem/filesystem and catalog'),
        ( 4, 3, 'filesystem/filesystem and catalog/photo'),
        ( 5, 3, 'filesystem/filesystem and catalog/attached'),
        ( 6, 2, 'filesystem/filesystem only'),
        ( 7, 1, 'catalog only'),
        ( 8, 2, 'catalog only/photo'),
        ( 9, 2, 'catalog only/attached')
    ),
    files AS (  -- every category path each file belongs to
        SELECT size_bytes, unnest([
            'all files',
            CASE WHEN on_disk THEN 'filesystem' ELSE 'catalog only' END,
            CASE WHEN on_disk THEN 'filesystem/' || source
                 ELSE 'catalog only/' || catalog_role END,
            CASE WHEN source = 'filesystem and catalog'
                 THEN 'filesystem/filesystem and catalog/' || catalog_role END
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
        SELECT 98, NULL, 'catalog entries outside the scan root (not analysed)',
               (SELECT count(*) FROM catalog_entries WHERE NOT in_scope), NULL
        UNION ALL
        SELECT 99, NULL, 'virtual copies (not files)',
               (SELECT count(*) FROM lr_image WHERE master_id IS NOT NULL), NULL
    )
    SELECT r.run_id, r.scan_date, b.level, b.category, b.files, b.bytes,
           round(b.bytes / 1e9, 2) AS gb
    FROM body b, run_info r
    ORDER BY b.sort
) TO 'reports/reconciliation.csv' (HEADER);
