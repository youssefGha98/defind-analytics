SELECT
    pool,
    count(*) AS n
FROM analytics.mart_tvl_block_snapshot
GROUP BY pool
HAVING count(*) > 1
