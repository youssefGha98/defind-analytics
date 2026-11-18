-- (pool, hour) must be unique in mart_price_intraday — one hourly OHLCV row per pool per hour.
-- Returns rows that are duplicated (violation = test failure).

SELECT pool, hour, count() AS n
FROM {{ ref('mart_price_intraday') }}
GROUP BY pool, hour
HAVING n > 1
