-- Summary mart for simulated LP position backtests.
--
-- GRAIN         : 1 row per scenario_id
-- DEPENDS ON    : int_position_backtest_entry_liquidity, int_position_backtest_exit_state,
--                 int_position_backtest_swap_path, int_position_backtest_time_in_range
-- KEY DECISIONS :
--   - Principal-only and fees-including values are exposed separately.
--   - Impermanent loss is measured on principal only, relative to the HODL benchmark.
--   - Observed time metrics are labeled explicitly because exact block timestamps
--     for quiet blocks are not yet modeled in the warehouse.

WITH fee_totals AS (
    SELECT
        scenario_id,
        count()                                                             AS swap_count_in_window,
        countIf(is_active_before_swap = 1)                                  AS swap_count_while_active,
        sum(fees_accrued_token0)                                            AS fees_accrued_token0,
        sum(fees_accrued_token1)                                            AS fees_accrued_token1,
        sum(fees_accrued_token0_equiv_generated)                            AS fees_accrued_token0_equiv_generated
    FROM {{ ref('int_position_backtest_swap_path') }}
    GROUP BY scenario_id
)

SELECT
    e.scenario_id                                                        AS scenario_id,
    e.pool                                                               AS pool,
    e.start_block                                                        AS start_block,
    e.end_block                                                          AS end_block,
    e.tick_lower                                                         AS tick_lower,
    e.tick_upper                                                         AS tick_upper,
    e.capital_committed_token0                                           AS capital_committed_token0,
    e.rebalance_policy                                                   AS rebalance_policy,
    e.start_snapshot_block_number                                        AS start_snapshot_block_number,
    e.start_snapshot_log_index                                           AS start_snapshot_log_index,
    e.start_snapshot_block_time                                          AS start_snapshot_block_time,
    e.start_tick                                                         AS start_tick,
    e.start_price                                                        AS start_price,
    e.start_position_status                                              AS start_position_status,
    e.initial_liquidity                                                  AS initial_liquidity,
    e.initial_amount0                                                    AS initial_amount0,
    e.initial_amount1                                                    AS initial_amount1,
    e.initial_principal_value_token0                                     AS initial_principal_value_token0,
    x.end_snapshot_block_number                                          AS end_snapshot_block_number,
    x.end_snapshot_log_index                                             AS end_snapshot_log_index,
    x.end_snapshot_block_time                                            AS end_snapshot_block_time,
    x.end_tick                                                           AS end_tick,
    x.end_price                                                          AS end_price,
    x.end_position_status                                                AS end_position_status,
    x.end_amount0                                                        AS end_amount0,
    x.end_amount1                                                        AS end_amount1,
    x.end_principal_value_token0                                         AS end_principal_value_token0,
    coalesce(f.swap_count_in_window, 0)                                     AS swap_count_in_window,
    coalesce(f.swap_count_while_active, 0)                                  AS swap_count_while_active,
    coalesce(f.fees_accrued_token0, 0.0)                                    AS fees_accrued_token0,
    coalesce(f.fees_accrued_token1, 0.0)                                    AS fees_accrued_token1,
    coalesce(f.fees_accrued_token0_equiv_generated, 0.0)                    AS fees_accrued_token0_equiv_generated,
    t.resolved_start_time                                                AS resolved_start_time,
    t.resolved_end_time                                                  AS resolved_end_time,
    coalesce(t.observed_time_in_range_seconds, 0)                           AS observed_time_in_range_seconds,
    coalesce(t.observed_window_seconds, 0)                                  AS observed_window_seconds,
    coalesce(t.observed_out_of_range_seconds, 0)                            AS observed_out_of_range_seconds,
    t.observed_time_in_range_pct,
    t.observed_out_of_range_pct,
    if(
        x.end_price > 0,
        e.initial_amount0 + e.initial_amount1 * x.end_price,
        NULL
    )                                                                       AS hodl_end_value_token0,
    if(
        x.end_principal_value_token0 IS NOT NULL,
        x.end_principal_value_token0 + coalesce(f.fees_accrued_token0_equiv_generated, 0.0),
        NULL
    )                                                                       AS lp_end_value_including_fees_token0,
    if(
        x.end_principal_value_token0 IS NOT NULL AND x.end_price > 0,
        x.end_principal_value_token0 - (e.initial_amount0 + e.initial_amount1 * x.end_price),
        NULL
    )                                                                       AS impermanent_loss_token0,
    if(
        x.end_principal_value_token0 IS NOT NULL
        AND x.end_price > 0
        AND (e.initial_amount0 + e.initial_amount1 * x.end_price) > 0,
        (
            x.end_principal_value_token0 - (e.initial_amount0 + e.initial_amount1 * x.end_price)
        ) / (e.initial_amount0 + e.initial_amount1 * x.end_price),
        NULL
    )                                                                       AS impermanent_loss_pct,
    if(
        x.end_principal_value_token0 IS NOT NULL,
        x.end_principal_value_token0 + coalesce(f.fees_accrued_token0_equiv_generated, 0.0) - e.capital_committed_token0,
        NULL
    )                                                                       AS pnl_vs_initial_token0,
    if(
        x.end_principal_value_token0 IS NOT NULL AND e.capital_committed_token0 > 0,
        (
            x.end_principal_value_token0 + coalesce(f.fees_accrued_token0_equiv_generated, 0.0) - e.capital_committed_token0
        ) / e.capital_committed_token0,
        NULL
    )                                                                       AS pnl_vs_initial_pct,
    if(
        x.end_principal_value_token0 IS NOT NULL AND x.end_price > 0,
        (
            x.end_principal_value_token0 + coalesce(f.fees_accrued_token0_equiv_generated, 0.0)
        ) - (e.initial_amount0 + e.initial_amount1 * x.end_price),
        NULL
    )                                                                       AS pnl_vs_hodl_token0,
    if(
        x.end_principal_value_token0 IS NOT NULL
        AND x.end_price > 0
        AND (e.initial_amount0 + e.initial_amount1 * x.end_price) > 0,
        (
            (
                x.end_principal_value_token0 + coalesce(f.fees_accrued_token0_equiv_generated, 0.0)
            ) - (e.initial_amount0 + e.initial_amount1 * x.end_price)
        ) / (e.initial_amount0 + e.initial_amount1 * x.end_price),
        NULL
    )                                                                       AS pnl_vs_hodl_pct,
    if(
        x.end_principal_value_token0 IS NOT NULL
        AND x.end_price > 0
        AND x.end_principal_value_token0 - (e.initial_amount0 + e.initial_amount1 * x.end_price) < 0,
        coalesce(f.fees_accrued_token0_equiv_generated, 0.0)
            / abs(x.end_principal_value_token0 - (e.initial_amount0 + e.initial_amount1 * x.end_price)),
        NULL
    )                                                                       AS fee_to_il_ratio
FROM {{ ref('int_position_backtest_entry_liquidity') }} e
LEFT JOIN {{ ref('int_position_backtest_exit_state') }} x USING (scenario_id)
LEFT JOIN fee_totals f USING (scenario_id)
LEFT JOIN {{ ref('int_position_backtest_time_in_range') }} t USING (scenario_id)
