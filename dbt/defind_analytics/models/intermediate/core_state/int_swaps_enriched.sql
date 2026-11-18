-- Swap path helper with lagged state, next-swap interval, and generated fees.
--
-- GRAIN         : 1 row per swap event (pool, block_number, log_index)
-- DEPENDS ON    : stg_swaps, stg_pools
-- KEY DECISIONS :
--   - tick_before / price_before describe the pool state immediately before the swap.
--   - tick_after / price_after come directly from the swap event itself.
--   - fees are generated on the input token and token1 fees are converted to token0
--     at the swap's own mark price, matching mart_volume_daily semantics.

WITH swaps_with_fee AS (
    SELECT
        s.pool,
        s.block_number,
        s.log_index,
        s.block_time,
        s.tick                                                              AS tick_after,
        toFloat64(s.price_token1_in_token0)                                 AS price_after,
        toFloat64(s.liquidity)                                              AS active_liquidity_at_swap,
        abs(toFloat64(s.amount0))                                           AS volume_token0,
        abs(toFloat64(s.amount1))                                           AS volume_token1,
        greatest(toFloat64(s.amount0), 0.0)                                 AS token0_in,
        greatest(toFloat64(s.amount1), 0.0)                                 AS token1_in,
        p.fee_bps
    FROM {{ ref('stg_swaps') }} s
    INNER JOIN {{ ref('stg_pools') }} p ON s.pool = p.pool
)

SELECT
    pool,
    block_number,
    log_index,
    block_time,
    lagInFrame(toNullable(tick_after), 1, CAST(NULL AS Nullable(Int32))) OVER (
        PARTITION BY pool
        ORDER BY block_number, log_index
    )                                                                       AS tick_before,
    lagInFrame(toNullable(price_after), 1, CAST(NULL AS Nullable(Float64))) OVER (
        PARTITION BY pool
        ORDER BY block_number, log_index
    )                                                                       AS price_before,
    tick_after,
    price_after,
    LEAD(toNullable(block_time), 1, CAST(NULL AS Nullable(DateTime))) OVER (
        PARTITION BY pool
        ORDER BY block_number, log_index
    )                                                                       AS next_block_time,
    active_liquidity_at_swap,
    volume_token0,
    volume_token1,
    token0_in + token1_in * price_after                                     AS volume_token0_equiv,
    token0_in,
    token1_in,
    token0_in * fee_bps / 100.0                                             AS fees_generated_token0,
    token1_in * fee_bps / 100.0                                             AS fees_generated_token1,
    token0_in * fee_bps / 100.0
        + token1_in * fee_bps / 100.0 * price_after                         AS fees_generated_token0_equiv
FROM swaps_with_fee
