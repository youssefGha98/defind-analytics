-- Position scoring features — 1 row per OPEN NFPM token_id on indexed pools.
--
-- Pure feature inputs for the Python position scoring engine. No label, no
-- recommendation, no risk text. Values are denominated in token0; equal USD only
-- when token0 is a stablecoin.
--
-- GRAIN         : 1 row per token_id (open NFPM positions only)
-- DEPENDS ON    : mart_position_cards_current, mart_pool_screener_daily,
--                 mart_nfpm_position_pnl_current, dim_indexed_pools
-- KEY DECISIONS :
--   - Distances normalized by range width (tick-based). For an in-range position,
--     distance_to_lower_pct + distance_to_upper_pct = 1 by construction.
--   - position_width_pct uses ln(price) so it equals the natural log-percentage
--     width: pow(1.0001, width_ticks) - 1.
--   - price_return_since_entry is NULL when entry state is missing.
--   - Pool features (realized_vol_7d/30d, AS proxy) are joined from the latest
--     row of mart_pool_screener_daily — the pool's current regime.
--   - V1 punts: pool_paid_volatility_active_band and volatility_spread (Phase 2),
--     fees_lost_out_of_range_token0 (would need range-overlay simulation),
--     per-position AS cost (Python derivation).

{{ config(materialized='view') }}

WITH

-- Latest screener row per pool. Same (pool, max_date) IN ... pattern as
-- mart_pool_analytics_snapshot to avoid CH 26.x analyzer leaking
-- internal column suffixes through SELECT * + row_number().
pool_latest_dates AS (
    SELECT pool_address, max(date) AS max_date
    FROM {{ ref('mart_pool_screener_daily') }}
    GROUP BY pool_address
),

pool_features AS (
    SELECT s.*
    FROM {{ ref('mart_pool_screener_daily') }} s
    INNER JOIN pool_latest_dates ld
        ON  s.pool_address = ld.pool_address
        AND s.date         = ld.max_date
),

cards AS (
    SELECT
        token_id                                                           AS token_id,
        wallet                                                             AS wallet,
        pool_address                                                       AS pool_address,
        tick_lower                                                         AS tick_lower,
        tick_upper                                                         AS tick_upper,
        range_width_ticks                                                  AS range_width_ticks,
        current_tick                                                       AS current_tick,
        current_price                                                      AS current_price,
        price_lower                                                        AS price_lower,
        price_upper                                                        AS price_upper,
        status_in_range                                                    AS status_in_range,
        time_in_range_pct_observed                                         AS time_in_range_pct_observed,
        observed_time_in_range_seconds                                     AS observed_time_in_range_seconds,
        observed_window_seconds                                            AS observed_window_seconds,
        position_age_days                                                  AS position_age_days,
        entry_price_token1_in_token0                                       AS entry_price_token1_in_token0,
        entry_state_missing                                                AS entry_state_missing,
        is_lot_benchmark_valid                                             AS is_lot_benchmark_valid,
        current_total_wealth_token0                                        AS current_total_wealth_token0,
        fees_collected_token0                                              AS fees_collected_token0,
        uncollected_fees_token0                                            AS uncollected_fees_token0,
        total_fees_token0                                                  AS total_fees_token0,
        il_pct                                                             AS il_pct,
        pnl_pct                                                            AS pnl_pct
    FROM {{ ref('mart_position_cards_current') }}
)

SELECT
    c.token_id,
    c.wallet,
    c.pool_address,

    -- ─── Range geometry / position relative to range ────────────────────────
    -- Tick-distance share of range. Negative if outside the range.
    if(c.range_width_ticks > 0,
       toFloat64(c.current_tick - c.tick_lower) / c.range_width_ticks,
       NULL)                                                               AS distance_to_lower_pct,
    if(c.range_width_ticks > 0,
       toFloat64(c.tick_upper - c.current_tick) / c.range_width_ticks,
       NULL)                                                               AS distance_to_upper_pct,
    -- Width as a price percentage: pow(1.0001, width) - 1.
    pow(1.0001, c.range_width_ticks) - 1.0                                 AS position_width_pct,
    -- Centered position (-0.5 = at lower, 0 = at mid, 0.5 = at upper).
    if(c.range_width_ticks > 0,
       toFloat64(c.current_tick - (c.tick_lower + c.tick_upper) / 2)
           / c.range_width_ticks,
       NULL)                                                               AS current_price_relative_to_range_mid,

    -- ─── Performance ────────────────────────────────────────────────────────
    if(c.entry_state_missing = 0 AND c.entry_price_token1_in_token0 > 0,
       c.current_price / c.entry_price_token1_in_token0 - 1.0,
       NULL)                                                               AS price_return_since_entry,
    c.pnl_pct,
    c.il_pct                                                               AS il_pct,

    -- ─── Time-in-range / capital utilization ────────────────────────────────
    c.time_in_range_pct_observed,
    -- Instantaneous: 1 if currently in range, 0 otherwise.
    if(c.status_in_range = 'in_range', 1.0, 0.0)                           AS capital_utilization_current,
    -- Historical: equals observed time-in-range share.
    c.time_in_range_pct_observed                                           AS capital_utilization_observed,

    -- ─── Fees ───────────────────────────────────────────────────────────────
    c.fees_collected_token0,
    c.uncollected_fees_token0,
    c.total_fees_token0                                                    AS fees_earned_in_range_token0,
    -- Counterfactual fees lost from being out of range — V1 punt.
    CAST(NULL AS Nullable(Float64))                                        AS fees_lost_out_of_range_token0,

    -- ─── Pool-level regime context (latest screener row) ────────────────────
    pf.realized_vol_7d,
    pf.realized_vol_30d,
    pf.adverse_selection_cost_apr_proxy                                    AS pool_adverse_selection_cost_apr_proxy,
    -- Per-position AS proxy = Python derivation (needs liquidity share + active days).
    CAST(NULL AS Nullable(Float64))                                        AS adverse_selection_cost_token0_proxy,

    -- ─── Lifecycle ──────────────────────────────────────────────────────────
    c.position_age_days,
    c.observed_window_seconds,
    c.observed_time_in_range_seconds,
    c.is_lot_benchmark_valid,
    c.entry_state_missing,

    now()                                                                  AS updated_at
FROM cards c
LEFT JOIN pool_features pf ON pf.pool_address = c.pool_address
