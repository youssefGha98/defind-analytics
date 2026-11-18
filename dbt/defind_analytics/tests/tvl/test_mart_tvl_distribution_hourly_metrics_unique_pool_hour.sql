SELECT
    pool,
    hour,
    count(*) AS n
FROM analytics.mart_tvl_distribution_hourly_metrics
GROUP BY pool, hour
HAVING count(*) > 1
