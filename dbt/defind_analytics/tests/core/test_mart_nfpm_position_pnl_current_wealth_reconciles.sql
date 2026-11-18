SELECT
    token_id,
    current_total_wealth_token0,
    current_principal_wealth_token0,
    current_fee_wealth_token0
FROM {{ ref('mart_nfpm_position_pnl_current') }}
WHERE abs(
    current_total_wealth_token0
    - current_principal_wealth_token0
    - current_fee_wealth_token0
) > 1e-7
