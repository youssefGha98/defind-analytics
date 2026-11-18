SELECT
    token_id,
    current_liquidity_raw,
    total_increase_liquidity_raw,
    total_decrease_liquidity_raw
FROM {{ ref('int_nfpm_position_liquidity_summary') }}
WHERE current_liquidity_raw < 0
   OR total_increase_liquidity_raw < 0
   OR total_decrease_liquidity_raw < 0
