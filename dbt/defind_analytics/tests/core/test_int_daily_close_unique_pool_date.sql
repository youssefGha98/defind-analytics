-- (pool, date) must be unique in int_daily_close — one close price per pool per day.
-- Returns rows that are duplicated (violation = test failure).

SELECT pool, date, count() AS n
FROM {{ ref('int_daily_close') }}
GROUP BY pool, date
HAVING n > 1
