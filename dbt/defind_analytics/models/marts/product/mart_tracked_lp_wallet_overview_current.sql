-- Tracked-LP wallet overview — 1 row per wallet that currently owns at least one
-- NFPM position on an indexed pool.
--
-- IMPORTANT V1 LIMITATION: this is NOT a full wallet tracker. We only see the
-- wallet's LP positions on indexed pools. We do NOT see ERC20 balances, non-LP
-- assets, or LP positions on pools outside dim_indexed_pools. Coverage metadata
-- is included on every row for the API to surface to the user.
--
-- Auto-discovery: any address that is the current_owner of an NFPM tokenId
-- mapped to an indexed pool is included. No user onboarding required in V1.
--
-- GRAIN         : 1 row per wallet (current_owner)
-- DEPENDS ON    : dim_indexed_pools, mart_nfpm_positions_current,
--                 mart_nfpm_position_pnl_current
-- KEY DECISIONS :
--   - Aggregates by current_owner (NFT holder right now). Historical owners are
--     not credited — if a position was transferred, only the current holder sees it.
--   - Burn-like owners (0x0, dead-burn addresses) are excluded.
--   - Open vs closed counts use mart_nfpm_positions_current.is_open.
--   - In/out-of-range counts use is_active (open & in-range) vs (open & not active).
--   - tracked_lp_value_token0 sums current_total_wealth_token0 — closed positions
--     contribute their residual collected fees but no principal.
--   - Coverage metadata is hardcoded V1 (single chain, single DEX, indexed-pools-only).

{{ config(materialized='table', order_by=['wallet']) }}

WITH

indexed AS (
    SELECT pool_address
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

base AS (
    SELECT
        pos.current_owner                                                  AS wallet,
        pos.pool                                                           AS pool_address,
        pos.token_id                                                       AS token_id,
        pos.is_open                                                        AS is_open,
        pos.is_active                                                      AS is_active,
        pos.is_current_owner_burn_like                                     AS is_current_owner_burn_like,
        pos.last_position_activity_time                                    AS last_position_activity_time,
        pnl.current_total_wealth_token0                                    AS current_total_wealth_token0,
        pnl.current_principal_wealth_token0                                AS current_principal_wealth_token0,
        pnl.current_fee_wealth_token0                                      AS current_fee_wealth_token0,
        pnl.current_collected_fee_wealth_token0                            AS current_collected_fee_wealth_token0,
        pnl.current_uncollected_fee_wealth_token0                          AS current_uncollected_fee_wealth_token0,
        pnl.pnl_vs_initial_token0                                          AS pnl_vs_initial_token0,
        pnl.initial_value_token0_at_entry                                  AS initial_value_token0_at_entry,
        pnl.is_lot_benchmark_valid                                         AS is_lot_benchmark_valid
    FROM {{ ref('mart_nfpm_positions_current') }} pos
    INNER JOIN {{ ref('mart_nfpm_position_pnl_current') }} pnl ON pnl.token_id = pos.token_id
    INNER JOIN indexed ip ON ip.pool_address = pos.pool
    WHERE pos.is_current_owner_burn_like = 0
)

SELECT
    wallet,

    -- ─── Wealth aggregates (token0 numeraire) ───────────────────────────────
    sumIf(current_total_wealth_token0, is_open = 1)                        AS tracked_lp_value_token0,
    sum(pnl_vs_initial_token0)                                             AS tracked_lp_pnl_token0,
    if(
        sumIf(initial_value_token0_at_entry, is_lot_benchmark_valid = 1) > 0,
        sum(pnl_vs_initial_token0)
            / sumIf(initial_value_token0_at_entry, is_lot_benchmark_valid = 1),
        NULL
    )                                                                      AS tracked_lp_pnl_pct,
    sum(current_collected_fee_wealth_token0)                               AS tracked_lp_fees_collected_token0,
    sum(current_uncollected_fee_wealth_token0)                             AS tracked_lp_uncollected_fees_token0,

    -- ─── Position counts ────────────────────────────────────────────────────
    countIf(is_open = 1)                                                   AS tracked_open_positions_count,
    count()                                                                AS tracked_total_positions_count,
    countIf(is_active = 1)                                                 AS tracked_in_range_positions_count,
    countIf(is_open = 1 AND is_active = 0)                                 AS tracked_out_of_range_positions_count,

    -- ─── Capital decomposition (open positions only) ────────────────────────
    sumIf(current_principal_wealth_token0, is_active = 1)                  AS tracked_active_capital_token0,
    sumIf(current_principal_wealth_token0, is_open = 1 AND is_active = 0)  AS tracked_out_of_range_capital_token0,
    if(
        sumIf(current_principal_wealth_token0, is_open = 1) > 0,
        sumIf(current_principal_wealth_token0, is_active = 1)
            / sumIf(current_principal_wealth_token0, is_open = 1),
        NULL
    )                                                                      AS tracked_capital_utilization,

    -- ─── Universe ───────────────────────────────────────────────────────────
    countDistinct(pool_address)                                            AS indexed_pools_count,
    max(last_position_activity_time)                                       AS last_activity_time,

    -- ─── Coverage metadata (V1 hardcoded) ───────────────────────────────────
    'indexed_pools_only'                                                   AS coverage_scope,
    'Coverage: indexed pools only'                                         AS coverage_label,
    'DeFind currently tracks LP positions, fees, PnL, and exposure only for pools included in the indexed universe.' AS coverage_tooltip,

    now()                                                                  AS updated_at
FROM base
GROUP BY wallet
