WITH daily_rollup AS (
    SELECT
        token_id,
        any(pool)                                      AS expected_pool,
        sum(active_swap_count)                         AS expected_active_swap_count,
        sum(total_fees_accrued_amount0)                AS expected_fees_amount0,
        sum(total_fees_accrued_amount1)                AS expected_fees_amount1,
        sum(total_fees_accrued_token0_equiv_generated) AS expected_fees_token0_equiv
    FROM {{ ref('int_nfpm_position_fee_daily') }}
    GROUP BY token_id
)

SELECT
    s.token_id,
    s.pool,
    d.expected_pool,
    s.active_swap_count,
    d.expected_active_swap_count,
    s.total_fees_accrued_amount0,
    d.expected_fees_amount0,
    s.total_fees_accrued_amount1,
    d.expected_fees_amount1,
    s.total_fees_accrued_token0_equiv_generated,
    d.expected_fees_token0_equiv
FROM {{ ref('int_nfpm_position_fee_summary') }} s
INNER JOIN daily_rollup d ON s.token_id = d.token_id
WHERE s.pool != d.expected_pool
   OR s.active_swap_count != d.expected_active_swap_count
   OR abs(s.total_fees_accrued_amount0 - d.expected_fees_amount0) > 1e-9
   OR abs(s.total_fees_accrued_amount1 - d.expected_fees_amount1) > 1e-9
   OR abs(s.total_fees_accrued_token0_equiv_generated - d.expected_fees_token0_equiv) > 1e-9
