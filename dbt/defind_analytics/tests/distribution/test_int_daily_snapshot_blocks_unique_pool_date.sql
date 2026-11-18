SELECT
    pool,
    date,
    count(*) AS n
FROM analytics.int_daily_snapshot_blocks
GROUP BY pool, date
HAVING count(*) > 1
