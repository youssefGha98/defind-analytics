SELECT
    t.pool,
    t.block_number,
    t.log_index,
    t.active_tick,
    t.fallback_after_swap,
    t.active_price_token1_in_token0,
    t.volume_token0,
    t.volume_token1,
    t.volume_token0_equiv,
    t.fees_generated_token0_equiv
FROM {{ ref('int_swaps_tick_volume') }} t
INNER JOIN {{ ref('int_swaps_enriched') }} e
    ON  t.pool = e.pool
    AND t.block_number = e.block_number
    AND t.log_index = e.log_index
WHERE t.active_tick != coalesce(e.tick_before, e.tick_after)
   OR t.fallback_after_swap != if(e.tick_before IS NULL, toUInt8(1), toUInt8(0))
   OR abs(t.active_price_token1_in_token0 - coalesce(e.price_before, e.price_after)) > 1e-12
   OR abs(t.active_liquidity_at_swap - e.active_liquidity_at_swap) > 1e-9
   OR abs(t.volume_token0 - e.volume_token0) > 1e-9
   OR abs(t.volume_token1 - e.volume_token1) > 1e-12
   OR abs(t.volume_token0_equiv - e.volume_token0_equiv) > 1e-6
   OR abs(t.fees_generated_token0 - e.fees_generated_token0) > 1e-9
   OR abs(t.fees_generated_token1 - e.fees_generated_token1) > 1e-12
   OR abs(t.fees_generated_token0_equiv - e.fees_generated_token0_equiv) > 1e-6
