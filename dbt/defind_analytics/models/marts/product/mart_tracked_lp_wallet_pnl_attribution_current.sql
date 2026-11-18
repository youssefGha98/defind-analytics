-- Tracked-LP wallet PnL attribution — 1 row per (wallet, component).
--
-- Decomposes a wallet's lifetime LP PnL on indexed pools into:
--   fees                                — fee wealth captured (collected + uncollected)
--   rewards                             — incentive rewards (V1 NULL — no incentives wired)
--   il_or_inventory_drift               — principal mark-to-market vs HODL (IL)
--   adverse_selection_cost_proxy        — LVR proxy (V1 NULL at wallet level — Python derives)
--   gas                                 — gas paid on LP txs (V1 NULL — needs gas indexer)
--   net_pnl                             — pnl_vs_initial aggregated across positions
--
-- All values denominated in token0. Equals USD only when token0 is a stablecoin.
--
-- GRAIN         : 1 row per (wallet, component)
-- DEPENDS ON    : dim_indexed_pools, mart_nfpm_positions_current,
--                 mart_nfpm_position_pnl_current
-- KEY DECISIONS :
--   - Components are exposed even when value is NULL (V1 stubs) so the API contract
--     is stable across phases. is_estimated marks heuristic / unavailable values.
--   - value_pct is component value / sum of |initial entry value| where benchmark
--     is valid. Falls back to NULL when wallet has no valid lot-benchmark anchor.

{{ config(materialized='table', order_by=['wallet', 'component']) }}

WITH

indexed AS (
    SELECT pool_address
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

wallet_aggregates AS (
    SELECT
        pos.current_owner                                                  AS wallet,
        sum(pnl.current_fee_wealth_token0)                                 AS fees_token0,
        sum(pnl.impermanent_loss_token0)                                   AS il_token0,
        sum(pnl.pnl_vs_initial_token0)                                     AS net_pnl_token0,
        sumIf(pnl.initial_value_token0_at_entry, pnl.is_lot_benchmark_valid = 1) AS basis_token0
    FROM {{ ref('mart_nfpm_positions_current') }} pos
    INNER JOIN {{ ref('mart_nfpm_position_pnl_current') }} pnl ON pnl.token_id = pos.token_id
    INNER JOIN indexed ip ON ip.pool_address = pos.pool
    WHERE pos.is_current_owner_burn_like = 0
    GROUP BY pos.current_owner
)

SELECT wallet, component, value_token0, value_pct, is_estimated, coverage_scope, updated_at
FROM (
    SELECT
        wallet,
        'fees'                                                             AS component,
        fees_token0                                                        AS value_token0,
        if(basis_token0 > 0, fees_token0 / basis_token0, NULL)             AS value_pct,
        toUInt8(0)                                                         AS is_estimated,
        'indexed_pools_only'                                               AS coverage_scope,
        now()                                                              AS updated_at
    FROM wallet_aggregates

    UNION ALL

    SELECT
        wallet,
        'rewards'                                                          AS component,
        CAST(NULL AS Nullable(Float64))                                    AS value_token0,
        CAST(NULL AS Nullable(Float64))                                    AS value_pct,
        toUInt8(1)                                                         AS is_estimated,
        'indexed_pools_only'                                               AS coverage_scope,
        now()                                                              AS updated_at
    FROM wallet_aggregates

    UNION ALL

    SELECT
        wallet,
        'il_or_inventory_drift'                                            AS component,
        il_token0                                                          AS value_token0,
        if(basis_token0 > 0, il_token0 / basis_token0, NULL)               AS value_pct,
        toUInt8(0)                                                         AS is_estimated,
        'indexed_pools_only'                                               AS coverage_scope,
        now()                                                              AS updated_at
    FROM wallet_aggregates

    UNION ALL

    SELECT
        wallet,
        'adverse_selection_cost_proxy'                                     AS component,
        CAST(NULL AS Nullable(Float64))                                    AS value_token0,
        CAST(NULL AS Nullable(Float64))                                    AS value_pct,
        toUInt8(1)                                                         AS is_estimated,
        'indexed_pools_only'                                               AS coverage_scope,
        now()                                                              AS updated_at
    FROM wallet_aggregates

    UNION ALL

    SELECT
        wallet,
        'gas'                                                              AS component,
        CAST(NULL AS Nullable(Float64))                                    AS value_token0,
        CAST(NULL AS Nullable(Float64))                                    AS value_pct,
        toUInt8(1)                                                         AS is_estimated,
        'indexed_pools_only'                                               AS coverage_scope,
        now()                                                              AS updated_at
    FROM wallet_aggregates

    UNION ALL

    SELECT
        wallet,
        'net_pnl'                                                          AS component,
        net_pnl_token0                                                     AS value_token0,
        if(basis_token0 > 0, net_pnl_token0 / basis_token0, NULL)          AS value_pct,
        toUInt8(0)                                                         AS is_estimated,
        'indexed_pools_only'                                               AS coverage_scope,
        now()                                                              AS updated_at
    FROM wallet_aggregates
)
