-- Daily snapshot of active liquidity per pool.
--
-- Active liquidity = net liquidity of all positions whose range covers
-- the day's close_tick: tick_lower <= close_tick < tick_upper (V3 convention).
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : int_daily_close_dense, int_range_liquidity_daily
-- KEY DECISIONS :
--   - share_of_liquidity = position_liquidity / active_liquidity is the intended
--     downstream usage — this is the fee-earned denominator for a given position.
--   - int_range_liquidity_daily materializes the LP-event cumulative sum upstream
--     to avoid repeating it in every downstream model.
--   - int_daily_close_dense is used (not int_daily_close) so that quiet days with
--     a carried price/tick still produce active-liquidity rows when ranges remain
--     in range.
--   - close_price is passed through to avoid a redundant join downstream.

SELECT
    dc.pool,
    dc.date,
    dc.close_tick,
    dc.close_price,
    sum(toInt128(rl.net_liquidity)) AS active_liquidity
FROM {{ ref('int_daily_close_dense') }} dc
INNER JOIN {{ ref('int_range_liquidity_daily') }} rl
    ON  rl.pool       = dc.pool
    AND rl.date       = dc.date
    AND rl.tick_lower <= dc.close_tick
    AND rl.tick_upper >  dc.close_tick
GROUP BY dc.pool, dc.date, dc.close_tick, dc.close_price