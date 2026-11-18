SELECT
    pool,
    count(*) AS n
FROM analytics.mart_tvl_current
GROUP BY pool
HAVING count(*) > 1
