SELECT
    pool,
    hour,
    tick_lower,
    count(*) AS n
FROM analytics.mart_tvl_distribution_hourly_centered
GROUP BY pool, hour, tick_lower
HAVING count(*) > 1
