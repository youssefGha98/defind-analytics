-- Exact active TVL per pool per day — exact V3 formula per position.
--
-- Active TVL = sum of token0 values of all positions whose range covers
-- the day's close_tick: tick_lower <= close_tick < tick_upper.
--
-- V3 formula for an in-range position (sp_low <= sp <= sp_high):
--
--   sp_low  = sqrt(1.0001^tick_lower) = pow(1.0001, tick_lower / 2.0)
--   sp_high = sqrt(1.0001^tick_upper) = pow(1.0001, tick_upper / 2.0)
--   sp      = sqrt(10^(token1_decimals - token0_decimals) / close_price)
--
--   amount0 = L * (sp_high - sp) / (sp * sp_high) / 10^token0_decimals
--   amount1 = L * (sp - sp_low)  / 10^token1_decimals
--   tvl_token0 = amount0 + amount1 * close_price
--
-- No approximation: clamping sp is unnecessary because
-- tick_lower <= close_tick < tick_upper guarantees sp_low <= sp <= sp_high.
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : int_daily_close_dense, stg_pools, int_range_liquidity_daily
-- KEY DECISIONS :
--   - Result is denominated in token0, not USD. Converting to USD requires an
--     external price feed (oracle/coingecko) for token0, which is not available here.
--     Rename to active_tvl_usd downstream only when token0 is a known stablecoin.
--   - close_sqrt_price is recomputed from close_price here (not taken from
--     int_daily_close_dense) so that unit tests only need to provide close_price
--     and get identical float64 results.
--   - Pre-join pattern: stg_pools joined before the range-state join to keep
--     the range join narrow.

WITH

-- Pre-join dense daily close with pool metadata before the range-state join.
close_with_meta AS (
    SELECT
        idc.pool,
        idc.date,
        idc.close_tick,
        idc.close_price,
        p.token0_decimals,
        p.token1_decimals,
        {{ sqrt_price_from_price('idc.close_price', 'p.token0_decimals', 'p.token1_decimals') }} AS close_sqrt_price
    FROM {{ ref('int_daily_close_dense') }} AS idc
    INNER JOIN {{ ref('stg_pools') }} AS p ON idc.pool = p.pool
),

active_positions AS (
    SELECT
        cm.pool,
        cm.date,
        cm.close_sqrt_price,
        cm.close_price,
        cm.token0_decimals,
        cm.token1_decimals,
        rl.tick_lower,
        rl.tick_upper,
        rl.net_liquidity
    FROM close_with_meta cm
    INNER JOIN {{ ref('int_range_liquidity_daily') }} rl
        ON  rl.pool       = cm.pool
        AND rl.date       = cm.date
        AND rl.tick_lower <= cm.close_tick
        AND rl.tick_upper >  cm.close_tick
),

valued_positions AS (
    SELECT
        pool,
        date,
        close_price,
        net_liquidity,
        token0_decimals,
        token1_decimals,
        {{ sqrt_price_at_tick('tick_lower') }} AS sp_low,
        {{ sqrt_price_at_tick('tick_upper') }} AS sp_high,
        close_sqrt_price                       AS sp
    FROM active_positions
)

SELECT
    pool,
    date,
    count()                                                              AS active_range_count,
    -- Result in token0 units: amount0 + amount1 converted via close_price.
    -- Equals USD only when token0 is a stablecoin (e.g. USDC).
    sum(
        {{ amount0_from_liquidity('net_liquidity', 'sp', 'sp_high', 'token0_decimals') }}
        + {{ amount1_from_liquidity('net_liquidity', 'sp', 'sp_low', 'token1_decimals') }}
            * toFloat64(close_price)
    )                                                                    AS active_tvl_token0
FROM valued_positions
GROUP BY pool, date