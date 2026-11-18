SELECT
    e.pool,
    e.block_number,
    e.log_index,
    e.volume_token0,
    e.volume_token1,
    e.volume_token0_equiv,
    e.token0_in,
    e.token1_in,
    e.fees_generated_token0,
    e.fees_generated_token1,
    e.fees_generated_token0_equiv
FROM {{ ref('int_swaps_enriched') }} e
INNER JOIN {{ ref('stg_swaps') }} s
    ON  e.pool = s.pool
    AND e.block_number = s.block_number
    AND e.log_index = s.log_index
INNER JOIN {{ ref('stg_pools') }} p
    ON e.pool = p.pool
WHERE abs(e.volume_token0 - abs(toFloat64(s.amount0))) > 1e-9
   OR abs(e.volume_token1 - abs(toFloat64(s.amount1))) > 1e-12
   OR abs(e.token0_in - greatest(toFloat64(s.amount0), 0.0)) > 1e-9
   OR abs(e.token1_in - greatest(toFloat64(s.amount1), 0.0)) > 1e-12
   OR abs(
        e.volume_token0_equiv
        - (
            greatest(toFloat64(s.amount0), 0.0)
            + greatest(toFloat64(s.amount1), 0.0) * toFloat64(s.price_token1_in_token0)
        )
      ) > 1e-6
   OR abs(
        e.fees_generated_token0
        - greatest(toFloat64(s.amount0), 0.0) * p.fee_bps / 100.0
      ) > 1e-9
   OR abs(
        e.fees_generated_token1
        - greatest(toFloat64(s.amount1), 0.0) * p.fee_bps / 100.0
      ) > 1e-12
   OR abs(
        e.fees_generated_token0_equiv
        - (
            greatest(toFloat64(s.amount0), 0.0) * p.fee_bps / 100.0
            + greatest(toFloat64(s.amount1), 0.0) * p.fee_bps / 100.0 * toFloat64(s.price_token1_in_token0)
        )
      ) > 1e-6
