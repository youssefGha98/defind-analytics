-- (pool, date) must be unique in int_daily_close_dense — one dense close row per pool per day.

SELECT pool, date, count(*) AS n
FROM {{ ref('int_daily_close_dense') }}
GROUP BY pool, date
HAVING count(*) > 1
