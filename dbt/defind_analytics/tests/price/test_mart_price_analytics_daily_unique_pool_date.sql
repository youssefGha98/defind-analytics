-- (pool, date) must be unique in mart_price_analytics_daily — one price analytics row per pool per day.
-- Returns rows that are duplicated (violation = test failure).

SELECT pool, date, count() AS n
FROM {{ ref('mart_price_analytics_daily') }}
GROUP BY pool, date
HAVING n > 1
