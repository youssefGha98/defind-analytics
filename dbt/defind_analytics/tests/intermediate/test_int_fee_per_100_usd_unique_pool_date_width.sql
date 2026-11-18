-- (pool, date, range_width_ticks) must be unique in int_fee_per_100_usd.

SELECT pool, date, range_width_ticks, count(*) AS n
FROM {{ ref('int_fee_per_100_usd') }}
GROUP BY pool, date, range_width_ticks
HAVING count(*) > 1
