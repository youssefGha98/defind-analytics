{{ config(
    order_by=['pool', 'active_tick', 'block_number', 'log_index'],
    partition_by="toYYYYMM(coalesce(block_time, toDateTime('1970-01-01 00:00:00')))"
) }}

-- Swap-level volume attributed to the active tick immediately before the swap.
--
-- This is the canonical bridge between swap flow and tick-level liquidity studies:
-- each swap is assigned to the tick that was active just before execution.
-- For the first observed swap in a pool, tick_before is unavailable, so we fall
-- back to tick_after and flag the assignment method explicitly.
--
-- GRAIN         : 1 row per swap event (pool, block_number, log_index)
-- DEPENDS ON    : int_swaps_enriched
-- KEY DECISIONS :
--   - active_tick uses tick_before when available because it best represents the
--     pool state at the moment the swap starts consuming liquidity.
--   - The first observed swap per pool is retained with fallback_after_swap=1 so
--     downstream studies can keep or exclude it explicitly.
--   - Volumes and fees pass through unchanged from int_swaps_enriched.

WITH attributed_swaps AS (
    SELECT
        pool,
        block_number,
        log_index,
        block_time,
        coalesce(tick_before, tick_after)                                      AS active_tick,
        if(tick_before IS NULL, toUInt8(1), toUInt8(0))                        AS fallback_after_swap,
        tick_before,
        tick_after,
        coalesce(price_before, price_after)                                    AS active_price_token1_in_token0,
        price_before,
        price_after,
        active_liquidity_at_swap,
        volume_token0,
        volume_token1,
        volume_token0_equiv,
        token0_in,
        token1_in,
        fees_generated_token0,
        fees_generated_token1,
        fees_generated_token0_equiv
    FROM {{ ref('int_swaps_enriched') }}
)

SELECT
    assumeNotNull(pool)                                                        AS pool,
    toUInt64(assumeNotNull(block_number))                                      AS block_number,
    toUInt64(assumeNotNull(log_index))                                         AS log_index,
    toDateTime(assumeNotNull(block_time))                                      AS block_time,
    toInt32(assumeNotNull(active_tick))                                        AS active_tick,
    toUInt8(assumeNotNull(fallback_after_swap))                                AS fallback_after_swap,
    tick_before,
    tick_after,
    toFloat64(assumeNotNull(active_price_token1_in_token0))                    AS active_price_token1_in_token0,
    price_before,
    price_after,
    toFloat64(assumeNotNull(active_liquidity_at_swap))                         AS active_liquidity_at_swap,
    toFloat64(assumeNotNull(volume_token0))                                    AS volume_token0,
    toFloat64(assumeNotNull(volume_token1))                                    AS volume_token1,
    toFloat64(assumeNotNull(volume_token0_equiv))                              AS volume_token0_equiv,
    toFloat64(assumeNotNull(token0_in))                                        AS token0_in,
    toFloat64(assumeNotNull(token1_in))                                        AS token1_in,
    toFloat64(assumeNotNull(fees_generated_token0))                            AS fees_generated_token0,
    toFloat64(assumeNotNull(fees_generated_token1))                            AS fees_generated_token1,
    toFloat64(assumeNotNull(fees_generated_token0_equiv))                      AS fees_generated_token0_equiv
FROM attributed_swaps
