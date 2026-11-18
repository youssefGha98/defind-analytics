-- (pool, date) must be unique in int_lp_macro_daily — one macro row per pool per day.

SELECT pool, date, count(*) AS n
FROM {{ ref('int_lp_macro_daily') }}
GROUP BY pool, date
HAVING count(*) > 1
