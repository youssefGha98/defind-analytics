SELECT
    pool,
    date,
    tick,
    count(*) AS n
FROM analytics.int_daily_tick_liquidity_net
GROUP BY pool, date, tick
HAVING count(*) > 1
