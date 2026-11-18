SELECT
    token_id,
    is_open,
    current_liquidity_raw
FROM {{ ref('mart_nfpm_open_positions_current') }}
WHERE NOT is_open
   OR current_liquidity_raw <= 0
