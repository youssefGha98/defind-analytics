SELECT
    token_id,
    is_open,
    is_active,
    current_liquidity_raw,
    current_tick,
    tick_lower,
    tick_upper
FROM {{ ref('mart_nfpm_positions_current') }}
WHERE (NOT is_open AND is_active)
   OR (is_open AND current_liquidity_raw <= 0)
   OR (
        is_active
        AND (
            current_tick < tick_lower
            OR current_tick >= tick_upper
        )
      )
