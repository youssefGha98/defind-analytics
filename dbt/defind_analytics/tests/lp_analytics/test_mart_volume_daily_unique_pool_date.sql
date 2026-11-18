-- (pool, date) must be unique in mart_volume_daily — one volume row per pool per day.
-- Returns rows that are duplicated (violation = test failure).

SELECT pool, date, count() AS n
FROM {{ ref('mart_volume_daily') }}
GROUP BY pool, date
HAVING n > 1
