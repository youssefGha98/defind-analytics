SELECT
    pool,
    hour,
    count(*) AS n
FROM analytics.int_hourly_snapshot_blocks
GROUP BY pool, hour
HAVING count(*) > 1
