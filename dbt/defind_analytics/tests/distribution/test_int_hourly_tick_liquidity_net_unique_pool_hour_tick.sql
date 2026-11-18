SELECT
    pool,
    hour,
    tick,
    count(*) AS n
FROM analytics.int_hourly_tick_liquidity_net
GROUP BY pool, hour, tick
HAVING count(*) > 1
