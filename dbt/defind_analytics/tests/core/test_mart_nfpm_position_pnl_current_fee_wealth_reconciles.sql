SELECT
    token_id,
    current_fee_wealth_token0,
    current_collected_fee_wealth_token0,
    current_uncollected_fee_wealth_token0
FROM {{ ref('mart_nfpm_position_pnl_current') }}
WHERE abs(
    current_fee_wealth_token0
    - current_collected_fee_wealth_token0
    - current_uncollected_fee_wealth_token0
) > 1e-7
