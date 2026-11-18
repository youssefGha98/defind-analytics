SELECT
    pool,
    date,
    tick_lower,
    count(*) AS n
FROM analytics.mart_tvl_distribution_daily_centered
GROUP BY pool, date, tick_lower
HAVING count(*) > 1
