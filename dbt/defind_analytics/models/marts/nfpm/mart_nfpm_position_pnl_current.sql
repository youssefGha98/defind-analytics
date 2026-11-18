{{ config(materialized='table', order_by=['token_id']) }}

-- Current mark-to-market PnL summary per mapped NFPM tokenId.
--
-- GRAIN         : 1 row per token_id
-- DEPENDS ON    : mart_nfpm_positions_current, int_nfpm_position_entry_state,
--                 int_nfpm_position_lot_benchmark_summary
-- KEY DECISIONS :
--   - Principal and fees are separated explicitly. Principal wealth includes
--     current deployed liquidity plus previously collected principal, both marked
--     to the current pool price.
--   - PnL vs initial cost basis and HODL benchmarks are lot-based: every
--     IncreaseLiquidity contributes its own entry-time cost basis and current
--     hold value, then tokenId-level percentages are recomputed from aggregate values.
--   - Fees are split between collected fees (from collect decomposition) and
--     uncollected fees (generated minus collected) so total fee wealth reconciles.
--   - Impermanent loss remains principal-only by design; fees are handled as a
--     separate performance component.

WITH base AS (
    SELECT
        c.token_id                                                            AS token_id,
        c.pool                                                                AS pool,
        c.tick_lower                                                          AS tick_lower,
        c.tick_upper                                                          AS tick_upper,
        c.range_width_ticks                                                   AS range_width_ticks,
        c.initial_owner                                                       AS initial_owner,
        c.current_owner                                                       AS current_owner,
        c.mint_tx_hash                                                        AS mint_tx_hash,
        c.mint_block_number                                                   AS mint_block_number,
        c.mint_block_time                                                     AS mint_block_time,
        c.pool_mint_log_index                                                 AS pool_mint_log_index,
        c.initial_amount0                                                     AS initial_amount0,
        c.initial_amount1                                                     AS initial_amount1,
        c.token0_symbol                                                       AS token0_symbol,
        c.token1_symbol                                                       AS token1_symbol,
        c.token0_decimals                                                     AS token0_decimals,
        c.token1_decimals                                                     AS token1_decimals,
        c.fee_bps                                                             AS fee_bps,
        c.is_open                                                             AS is_open,
        c.is_active                                                           AS is_active,
        c.is_nft_burned                                                       AS is_nft_burned,
        c.is_current_owner_burn_like                                          AS is_current_owner_burn_like,
        c.current_liquidity_raw                                               AS current_liquidity_raw,
        c.current_liquidity_share_of_initial                                  AS current_liquidity_share_of_initial,
        c.current_tick                                                        AS current_tick,
        c.price_token1_in_token0                                              AS current_price_token1_in_token0,
        c.current_position_amount0                                            AS current_position_amount0,
        c.current_position_amount1                                            AS current_position_amount1,
        c.current_position_token0                                             AS current_position_token0,
        c.total_withdraw_amount0                                              AS total_withdraw_amount0,
        c.total_withdraw_amount1                                              AS total_withdraw_amount1,
        c.total_principal_collected_amount0                                   AS total_principal_collected_amount0,
        c.total_principal_collected_amount1                                   AS total_principal_collected_amount1,
        c.total_fees_collected_amount0                                        AS total_fees_collected_amount0,
        c.total_fees_collected_amount1                                        AS total_fees_collected_amount1,
        c.collect_count                                                       AS collect_count,
        c.transfer_count                                                      AS transfer_count,
        c.increase_count                                                      AS increase_count,
        c.decrease_count                                                      AS decrease_count,
        c.last_position_activity_time                                         AS last_position_activity_time,
        e.entry_state_missing                                                 AS entry_state_missing,
        e.entry_snapshot_block_number                                         AS entry_snapshot_block_number,
        e.entry_snapshot_log_index                                            AS entry_snapshot_log_index,
        e.entry_snapshot_block_time                                           AS entry_snapshot_block_time,
        e.entry_tick                                                          AS entry_tick,
        e.entry_price_token1_in_token0                                        AS entry_price_token1_in_token0,
        coalesce(fs.active_swap_count, 0)                                     AS fee_active_swap_count,
        coalesce(fs.total_fees_accrued_amount0, 0.0)                          AS total_fees_accrued_amount0,
        coalesce(fs.total_fees_accrued_amount1, 0.0)                          AS total_fees_accrued_amount1,
        coalesce(fs.total_fees_accrued_token0_equiv_generated, 0.0)           AS total_fees_accrued_token0_equiv_generated,
        coalesce(tr.observed_time_in_range_seconds, 0)                        AS observed_time_in_range_seconds,
        coalesce(tr.observed_window_seconds, 0)                               AS observed_window_seconds,
        coalesce(tr.observed_out_of_range_seconds, 0)                         AS observed_out_of_range_seconds,
        tr.observed_time_in_range_pct                                         AS observed_time_in_range_pct,
        tr.observed_out_of_range_pct                                          AS observed_out_of_range_pct,
        lbs.lot_count                                                         AS lot_count,
        lbs.valid_lot_benchmark_count                                         AS valid_lot_benchmark_count,
        lbs.missing_lot_benchmark_count                                       AS missing_lot_benchmark_count,
        lbs.is_lot_benchmark_valid                                            AS is_lot_benchmark_valid,
        lbs.total_contribution_amount0                                        AS total_contribution_amount0,
        lbs.total_contribution_amount1                                        AS total_contribution_amount1,
        lbs.total_contribution_value_token0_at_entry                          AS total_contribution_value_token0_at_entry,
        lbs.total_hodl_value_token0_current                                   AS total_hodl_value_token0_current
    FROM {{ ref('mart_nfpm_positions_current') }} c
    LEFT JOIN {{ ref('int_nfpm_position_entry_state') }} e ON c.token_id = e.token_id
    LEFT JOIN {{ ref('int_nfpm_position_lot_benchmark_summary') }} lbs ON c.token_id = lbs.token_id
    LEFT JOIN {{ ref('int_nfpm_position_fee_summary') }} fs ON c.token_id = fs.token_id
    LEFT JOIN {{ ref('int_nfpm_position_time_in_range_summary') }} tr ON c.token_id = tr.token_id
),

normalized AS (
    SELECT
        *,
        increase_count = 1                                                    AS is_mint_anchored_benchmark_valid,
        toFloat64(initial_amount0)                                            AS initial_amount0_f64,
        toFloat64(initial_amount1)                                            AS initial_amount1_f64,
        toFloat64(current_price_token1_in_token0)                              AS current_price_f64,
        toFloat64(current_position_token0)                                     AS current_position_token0_f64,
        toFloat64(total_withdraw_amount0)                                      AS total_withdraw_amount0_f64,
        toFloat64(total_withdraw_amount1)                                      AS total_withdraw_amount1_f64,
        toFloat64(total_principal_collected_amount0)                           AS principal_collected_amount0_f64,
        toFloat64(total_principal_collected_amount1)                           AS principal_collected_amount1_f64,
        toFloat64(total_fees_collected_amount0)                                AS fees_collected_amount0_f64,
        toFloat64(total_fees_collected_amount1)                                AS fees_collected_amount1_f64,
        if(entry_state_missing, NULL, toFloat64(entry_price_token1_in_token0)) AS entry_price_f64
    FROM base
),

valued AS (
    SELECT
        *,
        greatest(
            total_withdraw_amount0_f64 - principal_collected_amount0_f64,
            0.0
        )                                                                      AS principal_owed_amount0_f64,
        greatest(
            total_withdraw_amount1_f64 - principal_collected_amount1_f64,
            0.0
        )                                                                      AS principal_owed_amount1_f64,
        total_fees_accrued_amount0 - fees_collected_amount0_f64                AS current_uncollected_fees_amount0,
        total_fees_accrued_amount1 - fees_collected_amount1_f64                AS current_uncollected_fees_amount1,
        principal_collected_amount0_f64
            + principal_collected_amount1_f64 * current_price_f64              AS principal_collected_token0_equiv_current,
        greatest(
            total_withdraw_amount0_f64 - principal_collected_amount0_f64,
            0.0
        )
            + greatest(
                total_withdraw_amount1_f64 - principal_collected_amount1_f64,
                0.0
            ) * current_price_f64                                              AS principal_owed_token0_equiv_current,
        fees_collected_amount0_f64
            + fees_collected_amount1_f64 * current_price_f64                   AS fees_collected_token0_equiv_current,
        (total_fees_accrued_amount0 - fees_collected_amount0_f64)
            + (total_fees_accrued_amount1 - fees_collected_amount1_f64) * current_price_f64 AS current_uncollected_fee_wealth_token0,
        if(
            is_lot_benchmark_valid,
            total_hodl_value_token0_current,
            NULL
        )                                                                      AS hodl_value_token0_current,
        if(
            NOT is_lot_benchmark_valid,
            NULL,
            total_contribution_value_token0_at_entry
        )                                                                      AS initial_value_token0_at_entry
    FROM normalized
),

wealth_components AS (
    SELECT
        *,
        fees_collected_token0_equiv_current + current_uncollected_fee_wealth_token0 AS current_fee_wealth_token0,
        current_position_token0_f64
            + principal_owed_token0_equiv_current
            + principal_collected_token0_equiv_current                            AS current_principal_wealth_token0
    FROM valued
),

benchmarked AS (
    SELECT
        *,
        current_principal_wealth_token0 + current_fee_wealth_token0               AS current_total_wealth_token0,
        if(
            hodl_value_token0_current IS NULL,
            NULL,
            current_principal_wealth_token0 - hodl_value_token0_current
        )                                                                         AS impermanent_loss_token0,
        if(
            hodl_value_token0_current > 0,
            (current_principal_wealth_token0 - hodl_value_token0_current) / hodl_value_token0_current,
            NULL
        )                                                                         AS impermanent_loss_pct,
        if(
            initial_value_token0_at_entry IS NULL OR initial_value_token0_at_entry <= 0,
            NULL,
            current_principal_wealth_token0 - initial_value_token0_at_entry
        )                                                                         AS principal_pnl_vs_initial_token0,
        if(
            initial_value_token0_at_entry IS NULL OR initial_value_token0_at_entry <= 0,
            NULL,
            (current_principal_wealth_token0 - initial_value_token0_at_entry) / initial_value_token0_at_entry
        )                                                                         AS principal_pnl_vs_initial_pct,
        if(
            initial_value_token0_at_entry IS NULL OR initial_value_token0_at_entry <= 0,
            NULL,
            (current_principal_wealth_token0 + current_fee_wealth_token0) - initial_value_token0_at_entry
        )                                                                         AS pnl_vs_initial_token0,
        if(
            initial_value_token0_at_entry IS NULL OR initial_value_token0_at_entry <= 0,
            NULL,
            ((current_principal_wealth_token0 + current_fee_wealth_token0) - initial_value_token0_at_entry) / initial_value_token0_at_entry
        )                                                                         AS pnl_vs_initial_pct,
        (current_principal_wealth_token0 + current_fee_wealth_token0) - hodl_value_token0_current AS pnl_vs_hodl_token0,
        if(
            hodl_value_token0_current > 0,
            ((current_principal_wealth_token0 + current_fee_wealth_token0) - hodl_value_token0_current) / hodl_value_token0_current,
            NULL
        )                                                                         AS pnl_vs_hodl_pct,
        if(
            hodl_value_token0_current IS NOT NULL
            AND (current_principal_wealth_token0 - hodl_value_token0_current) < 0,
            (fees_collected_token0_equiv_current + current_uncollected_fee_wealth_token0) / abs(current_principal_wealth_token0 - hodl_value_token0_current),
            NULL
        )                                                                         AS fee_to_il_ratio
    FROM wealth_components
)

SELECT
    token_id,
    pool,
    tick_lower,
    tick_upper,
    range_width_ticks,
    initial_owner,
    current_owner,
    mint_tx_hash,
    mint_block_number,
    mint_block_time,
    pool_mint_log_index,
    token0_symbol,
    token1_symbol,
    token0_decimals,
    token1_decimals,
    fee_bps,
    is_open,
    is_active,
    is_nft_burned,
    is_current_owner_burn_like,
    current_liquidity_raw,
    current_liquidity_share_of_initial,
    collect_count,
    fee_active_swap_count,
    transfer_count,
    increase_count,
    decrease_count,
    last_position_activity_time,
    lot_count,
    valid_lot_benchmark_count,
    missing_lot_benchmark_count,
    is_lot_benchmark_valid,
    total_contribution_amount0,
    total_contribution_amount1,
    is_mint_anchored_benchmark_valid,
    entry_state_missing,
    entry_snapshot_block_number,
    entry_snapshot_log_index,
    entry_snapshot_block_time,
    entry_tick,
    entry_price_token1_in_token0,
    current_tick,
    current_price_token1_in_token0,
    initial_amount0,
    initial_amount1,
    current_position_amount0,
    current_position_amount1,
    current_position_token0                                                  AS current_deployed_principal_token0,
    principal_owed_amount0_f64                                               AS current_principal_owed_amount0,
    principal_owed_amount1_f64                                               AS current_principal_owed_amount1,
    total_fees_accrued_amount0,
    total_fees_accrued_amount1,
    total_fees_accrued_token0_equiv_generated,
    total_principal_collected_amount0,
    total_principal_collected_amount1,
    total_fees_collected_amount0,
    total_fees_collected_amount1,
    initial_value_token0_at_entry,
    hodl_value_token0_current,
    principal_owed_token0_equiv_current,
    principal_collected_token0_equiv_current,
    fees_collected_amount0_f64                                               AS total_fees_collected_amount0_f64,
    fees_collected_amount1_f64                                               AS total_fees_collected_amount1_f64,
    current_uncollected_fees_amount0,
    current_uncollected_fees_amount1,
    fees_collected_token0_equiv_current                                      AS current_collected_fee_wealth_token0,
    current_uncollected_fee_wealth_token0,
    current_fee_wealth_token0,
    current_principal_wealth_token0,
    current_total_wealth_token0,
    impermanent_loss_token0,
    impermanent_loss_pct,
    principal_pnl_vs_initial_token0,
    principal_pnl_vs_initial_pct,
    pnl_vs_initial_token0,
    pnl_vs_initial_pct,
    pnl_vs_hodl_token0,
    pnl_vs_hodl_pct,
    fee_to_il_ratio,
    observed_time_in_range_seconds,
    observed_window_seconds,
    observed_out_of_range_seconds,
    observed_time_in_range_pct,
    observed_out_of_range_pct
FROM benchmarked
