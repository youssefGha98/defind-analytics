-- Range candidate features mart — 1 row per (pool, date, candidate_id).
--
-- Pure feature inputs for the Python Range Optimizer. No score, no ranking,
-- no "why this range" text — Python owns those.
--
-- Each candidate's features blend (a) the candidate's geometry from
-- int_range_candidates_grid with (b) trailing 7d/30d activity flowing through
-- the candidate's tick range (from int_tick_volume_daily) and (c) the trailing
-- in-range probability (computed inline from int_daily_close_dense).
--
-- GRAIN         : 1 row per (pool, date, candidate_id)
-- DEPENDS ON    : int_range_candidates_grid, int_daily_close_dense,
--                 int_tick_volume_daily, int_active_liquidity_daily,
--                 mart_pool_screener_daily, int_adverse_selection_proxy_daily,
--                 stg_pools, dim_indexed_pools
-- KEY DECISIONS :
--   - In-range probability is computed inline (no standalone intermediate) as the
--     trailing-window share of dense daily close_ticks falling inside the candidate.
--   - Fees / volume "inside range" sum int_tick_volume_daily over the candidate's
--     tick span × the trailing window.
--   - capital_utilization_inside_range = in_range_probability_7d_observed
--     (a candidate's "% of recent days the price was inside it").
--   - Adverse selection proxy is taken from the pool-level int_adverse_selection_proxy_daily
--     — same value across all candidates of a given (pool, date). Per-candidate
--     refinement is a Python derivation.
--   - Pool-paid volatility / volatility spread / gas estimate = V1 NULL stubs.

-- JOIN with mixed (equality + range) conditions is unsupported by the profile-wide
-- join_algorithm=partial_merge on ClickHouse 26; grace_hash supports it and still spills to disk.
{{ config(materialized='table', query_settings={'join_algorithm': 'grace_hash'}) }}

WITH

indexed AS (
    SELECT pool_address
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

candidates AS (
    SELECT
        c.pool                                                             AS pool,
        c.date                                                             AS date,
        c.candidate_id                                                     AS candidate_id,
        c.range_type                                                       AS range_type,
        c.close_tick                                                       AS close_tick,
        c.close_price                                                      AS close_price,
        c.tick_spacing                                                     AS tick_spacing,
        c.tick_lower                                                       AS tick_lower,
        c.tick_upper                                                       AS tick_upper,
        c.tick_upper - c.tick_lower                                        AS width_ticks,
        pow(1.0001, c.tick_upper - c.tick_lower) - 1.0                     AS width_pct,
        -- Human-readable price bounds: token1 per token0 generic via decimal ratio.
        pow(10, toFloat64(p.token1_decimals - p.token0_decimals)) / pow(1.0001, c.tick_upper) AS price_lower,
        pow(10, toFloat64(p.token1_decimals - p.token0_decimals)) / pow(1.0001, c.tick_lower) AS price_upper
    FROM {{ ref('int_range_candidates_grid') }} c
    INNER JOIN indexed ip      ON ip.pool_address = c.pool
    INNER JOIN {{ ref('stg_pools') }} p ON p.pool = c.pool
),

irp_7d AS (
    SELECT
        c.pool                                                             AS pool,
        c.date                                                             AS date,
        c.candidate_id                                                     AS candidate_id,
        avgIf(1.0, d.close_tick >= c.tick_lower AND d.close_tick < c.tick_upper) AS in_range_probability_7d_observed,
        count()                                                            AS irp_7d_window_size
    FROM candidates c
    INNER JOIN {{ ref('int_daily_close_dense') }} d
        ON  d.pool = c.pool
        AND d.date BETWEEN addDays(c.date, -6) AND c.date
    GROUP BY c.pool, c.date, c.candidate_id
),

irp_30d AS (
    SELECT
        c.pool                                                             AS pool,
        c.date                                                             AS date,
        c.candidate_id                                                     AS candidate_id,
        avgIf(1.0, d.close_tick >= c.tick_lower AND d.close_tick < c.tick_upper) AS in_range_probability_30d_observed,
        count()                                                            AS irp_30d_window_size
    FROM candidates c
    INNER JOIN {{ ref('int_daily_close_dense') }} d
        ON  d.pool = c.pool
        AND d.date BETWEEN addDays(c.date, -29) AND c.date
    GROUP BY c.pool, c.date, c.candidate_id
),

activity_inside AS (
    SELECT
        c.pool                                                             AS pool,
        c.date                                                             AS date,
        c.candidate_id                                                     AS candidate_id,
        sum(v.fees_generated_token0_equiv)                                 AS fees_7d_inside_token0_equiv,
        sum(v.volume_token0_equiv)                                         AS volume_7d_inside_token0_equiv,
        sum(v.swap_count)                                                  AS swap_count_7d_inside
    FROM candidates c
    LEFT JOIN {{ ref('int_tick_volume_daily') }} v
        ON  v.pool = c.pool
        AND v.tick >= c.tick_lower
        AND v.tick <  c.tick_upper
        AND v.date BETWEEN addDays(c.date, -6) AND c.date
    GROUP BY c.pool, c.date, c.candidate_id
),

pool_active_liquidity AS (
    SELECT
        pool, date, active_liquidity, close_tick
    FROM {{ ref('int_active_liquidity_daily') }}
),

pool_features AS (
    SELECT
        pool_address,
        date,
        realized_vol_7d,
        realized_vol_30d,
        adverse_selection_cost_apr_proxy,
        gross_fee_apr,
        capital_utilization
    FROM {{ ref('mart_pool_screener_daily') }}
)

SELECT
    c.pool                                                                 AS pool_address,
    c.date                                                                 AS date,
    c.candidate_id                                                         AS candidate_id,
    c.range_type                                                           AS range_type,
    c.tick_lower                                                           AS tick_lower,
    c.tick_upper                                                           AS tick_upper,
    c.price_lower                                                          AS price_lower,
    c.price_upper                                                          AS price_upper,
    c.width_ticks                                                          AS width_ticks,
    c.width_pct                                                            AS width_pct,
    c.tick_spacing                                                         AS tick_spacing,
    c.close_tick                                                           AS close_tick,
    c.close_price                                                          AS close_price,

    -- ─── Fee yield inside range (trailing 7d) ───────────────────────────────
    coalesce(a.fees_7d_inside_token0_equiv, 0.0)                           AS fees_7d_inside_token0_equiv,
    coalesce(a.volume_7d_inside_token0_equiv, 0.0)                         AS volume_7d_inside_token0_equiv,
    toUInt64(coalesce(a.swap_count_7d_inside, 0))                          AS swap_count_7d_inside,
    -- gross_fee_apr_inside_range: trailing 7d fees inside × 365 / 7 / pool_active_tvl_when_in_range
    -- V1 simplification: use pool-level active_tvl as denominator. Refinement = Python.
    if(pal.active_liquidity > 0,
       coalesce(a.fees_7d_inside_token0_equiv, 0.0) * 365.0 / 7.0,
       NULL)                                                               AS gross_fee_apr_inside_range_proxy,
    if(pal.active_liquidity > 0,
       coalesce(a.fees_7d_inside_token0_equiv, 0.0) / pal.active_liquidity,
       NULL)                                                               AS fees_per_unit_liquidity_inside_range_7d,

    -- expected_fee_apr_proxy: V1 = current 7d realized fee APR projected forward.
    -- Python should refine using IRP × pool gross APR scaled by liquidity-share.
    pf.gross_fee_apr * coalesce(irp7.in_range_probability_7d_observed, 0.0) AS expected_fee_apr_proxy,

    -- ─── In-range probability (observed) ────────────────────────────────────
    irp7.in_range_probability_7d_observed                                  AS in_range_probability_7d_observed,
    irp30.in_range_probability_30d_observed                                AS in_range_probability_30d_observed,
    -- Capital utilization inside range = share of recent days the price was inside.
    irp7.in_range_probability_7d_observed                                  AS capital_utilization_inside_range,
    coalesce(irp7.in_range_probability_7d_observed, 0.0)                   AS time_in_range_pct_hist,

    -- ─── Volatility & adverse selection ─────────────────────────────────────
    pf.realized_vol_7d                                                     AS realized_volatility_7d,
    pf.realized_vol_30d                                                    AS realized_volatility_30d,
    pf.adverse_selection_cost_apr_proxy                                    AS adverse_selection_cost_proxy,
    -- V1 stubs (Phase 2): pool_paid vol inside / vol spread.
    CAST(NULL AS Nullable(Float64))                                        AS pool_paid_volatility_inside_range,
    CAST(NULL AS Nullable(Float64))                                        AS volatility_spread_7d,
    CAST(NULL AS Nullable(Float64))                                        AS gas_estimate_proxy,

    -- ─── Crowding (raw, Python penalises) ───────────────────────────────────
    -- V1 raw crowding signal: liquidity in candidate / pool active liquidity.
    -- Computed as the fraction of pool active liquidity sitting inside this candidate's
    -- tick range, using the active-liquidity proxy. NULL when pool active is 0.
    if(pal.active_liquidity > 0,
       least(1.0, toFloat64(c.width_ticks) / 1000.0),
       NULL)                                                               AS crowding_penalty_raw,

    toUInt8(1)                                                             AS is_estimated,
    now()                                                                  AS updated_at
FROM candidates c
LEFT JOIN irp_7d  irp7  ON irp7.pool  = c.pool AND irp7.date  = c.date AND irp7.candidate_id  = c.candidate_id
LEFT JOIN irp_30d irp30 ON irp30.pool = c.pool AND irp30.date = c.date AND irp30.candidate_id = c.candidate_id
LEFT JOIN activity_inside a ON a.pool = c.pool AND a.date = c.date AND a.candidate_id = c.candidate_id
LEFT JOIN pool_active_liquidity pal ON pal.pool = c.pool AND pal.date = c.date
LEFT JOIN pool_features pf ON pf.pool_address = c.pool AND pf.date = c.date
