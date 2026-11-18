-- (pool_address, date) must be unique in mart_pool_screener_daily.
-- Returns offending rows (violation = test failure).

SELECT pool_address, date, count() AS n
FROM {{ ref('mart_pool_screener_daily') }}
GROUP BY pool_address, date
HAVING n > 1
