SELECT
    token_id,
    increase_count,
    is_lot_benchmark_valid,
    hodl_value_token0_current,
    initial_value_token0_at_entry,
    impermanent_loss_token0,
    pnl_vs_hodl_token0,
    pnl_vs_hodl_pct
FROM {{ ref('mart_nfpm_position_pnl_current') }}
WHERE is_lot_benchmark_valid = 0
  AND (
      hodl_value_token0_current IS NOT NULL
      OR initial_value_token0_at_entry IS NOT NULL
      OR impermanent_loss_token0 IS NOT NULL
      OR pnl_vs_hodl_token0 IS NOT NULL
      OR pnl_vs_hodl_pct IS NOT NULL
  )
