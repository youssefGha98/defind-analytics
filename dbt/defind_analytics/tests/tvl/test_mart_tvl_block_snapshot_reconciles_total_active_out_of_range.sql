SELECT
    pool,
    target_block,
    total_tvl_token0,
    active_tvl_token0,
    out_of_range_tvl_token0,
    tvl_reconciliation_gap
FROM analytics.mart_tvl_block_snapshot
WHERE abs(tvl_reconciliation_gap) > 1e-6
