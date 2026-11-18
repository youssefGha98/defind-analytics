-- (pool, date, tick) must be unique in mart_tick_daily — one row per pool, day, and tick.
-- Returns rows that are duplicated (violation = test failure).

SELECT pool, date, tick, count() AS n
FROM {{ ref('mart_tick_daily') }}
GROUP BY pool, date, tick
HAVING n > 1
