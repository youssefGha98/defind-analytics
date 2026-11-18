SELECT
    s.token_id,
    s.total_contribution_amount0,
    s.total_contribution_amount1,
    ls.total_deposit_amount0,
    ls.total_deposit_amount1
FROM {{ ref('int_nfpm_position_lot_benchmark_summary') }} s
INNER JOIN {{ ref('int_nfpm_position_liquidity_summary') }} ls ON s.token_id = ls.token_id
WHERE abs(s.total_contribution_amount0 - toFloat64(ls.total_deposit_amount0)) > 1e-7
   OR abs(s.total_contribution_amount1 - toFloat64(ls.total_deposit_amount1)) > 1e-7
