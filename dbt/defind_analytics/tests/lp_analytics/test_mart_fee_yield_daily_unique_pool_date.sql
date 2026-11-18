-- (pool, date) must be unique in mart_fee_yield_daily — one APR row per pool per day.
-- Returns rows that are duplicated (violation = test failure).

SELECT pool, date, count() AS n
FROM {{ ref('mart_fee_yield_daily') }}
GROUP BY pool, date
HAVING n > 1
