-- Daily close state per pool: last tick and price of each day.
-- Centralizes the daily_close pattern duplicated across:
--   int_active_liquidity_daily, int_active_tvl_daily, mart_tvl_daily, mart_tvl_distribution.
--
-- close_sqrt_price = sqrt(10^(token1_decimals - token0_decimals) / close_price)
-- Normalized V3 square root price used in TVL formulas downstream.
--
-- KEY DECISIONS :
--   - Two separate argMax calls instead of a single tuple-based argMax.
--     Tuple approach (tupleElement) was fragile: field access by position breaks
--     silently if the tuple definition changes.
--   - stg_pools joined to provide token decimals for the generic sqrt_price_from_price macro.

WITH close_state AS (
    SELECT
        s.pool,
        toDate(s.block_time)                                                         AS date,
        argMax(s.tick,                    tuple(s.block_number, s.log_index))        AS close_tick,
        argMax(s.price_token1_in_token0,  tuple(s.block_number, s.log_index))       AS close_price,
        any(p.token0_decimals)                                                       AS token0_decimals,
        any(p.token1_decimals)                                                       AS token1_decimals
    FROM {{ ref('stg_swaps') }} s
    INNER JOIN {{ ref('stg_pools') }} p ON s.pool = p.pool
    GROUP BY s.pool, toDate(s.block_time)
)

SELECT
    pool,
    date,
    close_tick,
    close_price,
    {{ sqrt_price_from_price('close_price', 'token0_decimals', 'token1_decimals') }} AS close_sqrt_price
FROM close_state