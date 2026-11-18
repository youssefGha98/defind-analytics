SELECT
    pool,
    date,
    count(*) AS n
FROM analytics.mart_tvl_distribution_daily_metrics
GROUP BY pool, date
HAVING count(*) > 1
