-- Range heatmap features mart — 2D grid of (lower_offset × upper_offset) cells
-- per indexed pool, "as of latest" only.
--
-- Powers the Range Optimizer heatmap. Each cell carries factual features; the
-- Python optimizer computes the risk-adjusted score that produces the heatmap
-- color value.
--
-- V1 grid (per pool):
--   lower_offsets = {-1000, -800, -600, -500, -400, -300, -200, -100}  (ticks)
--   upper_offsets = { +100, +200, +300, +400, +500, +600, +800, +1000} (ticks)
--   => 8 × 8 = 64 cells. tick_lower / tick_upper snapped to tick_spacing.
--
-- GRAIN         : 1 row per (pool, lower_tick, upper_tick) — latest-only
-- DEPENDS ON    : dim_indexed_pools, int_daily_close_dense, stg_pools,
--                 int_daily_close, int_tick_volume_daily,
--                 mart_pool_screener_daily, int_adverse_selection_proxy_daily
-- KEY DECISIONS :
--   - Anchored on the latest dense-close date per pool (ensures close_tick is set).
--   - IRP computed inline over a 7d trailing window from the anchor date.
--   - Same simplification as mart_range_candidates_features for AS proxy
--     (pool-level value, same across all cells of a pool).

-- JOIN with mixed (equality + range) conditions is unsupported by the profile-wide
-- join_algorithm=partial_merge on ClickHouse 26; grace_hash supports it and still spills to disk.
{{ config(materialized='table', query_settings={'join_algorithm': 'grace_hash'}) }}

WITH

indexed AS (
    SELECT pool_address
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

-- Latest dense close per pool. (pool, max_date) IN (...) pattern to avoid
-- CH 26.x analyzer issues with SELECT * + row_number().
latest_close_dates AS (
    SELECT d.pool AS pool, max(d.date) AS max_date
    FROM {{ ref('int_daily_close_dense') }} d
    INNER JOIN indexed ip ON ip.pool_address = d.pool
    WHERE d.close_tick IS NOT NULL
    GROUP BY d.pool
),

latest_close AS (
    SELECT
        d.pool                                                             AS pool,
        d.date                                                             AS date,
        d.close_tick                                                       AS close_tick,
        d.close_price                                                      AS close_price,
        p.tick_spacing                                                     AS tick_spacing,
        p.token0_decimals                                                  AS token0_decimals,
        p.token1_decimals                                                  AS token1_decimals
    FROM {{ ref('int_daily_close_dense') }} d
    INNER JOIN latest_close_dates lcd
        ON  d.pool = lcd.pool
        AND d.date = lcd.max_date
    INNER JOIN {{ ref('stg_pools') }} p ON p.pool = d.pool
),

offsets AS (
    SELECT
        toInt32(lo) AS lower_offset,
        toInt32(uo) AS upper_offset
    FROM numbers(1)
    ARRAY JOIN [-1000, -800, -600, -500, -400, -300, -200, -100] AS lo
    ARRAY JOIN [100, 200, 300, 400, 500, 600, 800, 1000]         AS uo
),

cells AS (
    SELECT
        lc.pool                                                            AS pool_address,
        lc.date                                                            AS anchor_date,
        lc.close_tick,
        lc.close_price,
        lc.tick_spacing,
        lc.token0_decimals,
        lc.token1_decimals,
        toInt32(floor(toFloat64(lc.close_tick + o.lower_offset) / toFloat64(lc.tick_spacing)) * toFloat64(lc.tick_spacing)) AS tick_lower,
        toInt32(ceil(toFloat64(lc.close_tick + o.upper_offset)  / toFloat64(lc.tick_spacing)) * toFloat64(lc.tick_spacing)) AS tick_upper
    FROM latest_close lc
    CROSS JOIN offsets o
),

irp_7d AS (
    SELECT
        c.pool_address, c.tick_lower, c.tick_upper,
        avgIf(1.0, d.close_tick >= c.tick_lower AND d.close_tick < c.tick_upper) AS in_range_probability_observed
    FROM cells c
    INNER JOIN {{ ref('int_daily_close_dense') }} d
        ON  d.pool = c.pool_address
        AND d.date BETWEEN addDays(c.anchor_date, -6) AND c.anchor_date
    GROUP BY c.pool_address, c.tick_lower, c.tick_upper
),

activity_inside AS (
    SELECT
        c.pool_address, c.tick_lower, c.tick_upper,
        sum(v.fees_generated_token0_equiv)                                 AS fees_7d_inside_token0_equiv,
        sum(v.volume_token0_equiv)                                         AS volume_7d_inside_token0_equiv
    FROM cells c
    LEFT JOIN {{ ref('int_tick_volume_daily') }} v
        ON  v.pool = c.pool_address
        AND v.tick >= c.tick_lower
        AND v.tick <  c.tick_upper
        AND v.date BETWEEN addDays(c.anchor_date, -6) AND c.anchor_date
    GROUP BY c.pool_address, c.tick_lower, c.tick_upper
),

-- Same (pool, max_date) IN (...) pattern as elsewhere.
pool_features_dates AS (
    SELECT pool_address, max(date) AS max_date
    FROM {{ ref('mart_pool_screener_daily') }}
    GROUP BY pool_address
),

pool_features AS (
    SELECT
        s.pool_address                                                     AS pool_address,
        s.realized_vol_7d                                                  AS realized_vol_7d,
        s.adverse_selection_cost_apr_proxy                                 AS adverse_selection_cost_apr_proxy,
        s.gross_fee_apr                                                    AS gross_fee_apr,
        s.capital_utilization                                              AS capital_utilization
    FROM {{ ref('mart_pool_screener_daily') }} s
    INNER JOIN pool_features_dates fd
        ON  s.pool_address = fd.pool_address
        AND s.date         = fd.max_date
)

SELECT
    c.pool_address                                                         AS pool_address,
    c.tick_lower                                                           AS lower_tick,
    c.tick_upper                                                           AS upper_tick,
    -- price bounds: token1 per token0, generic via decimal ratio
    pow(10, toFloat64(c.token1_decimals - c.token0_decimals)) / pow(1.0001, c.tick_upper) AS lower_price,
    pow(10, toFloat64(c.token1_decimals - c.token0_decimals)) / pow(1.0001, c.tick_lower) AS upper_price,

    c.close_tick                                                           AS close_tick,
    c.close_price                                                          AS close_price,
    c.tick_spacing                                                         AS tick_spacing,

    -- Trailing 7d fees flowing through the cell.
    coalesce(a.fees_7d_inside_token0_equiv, 0.0)                           AS fees_7d_inside_token0_equiv,
    coalesce(a.volume_7d_inside_token0_equiv, 0.0)                         AS volume_7d_inside_token0_equiv,

    -- fee_apr_proxy: trailing 7d fees inside extrapolated to a year.
    coalesce(a.fees_7d_inside_token0_equiv, 0.0) * 365.0 / 7.0             AS fee_apr_proxy,

    -- expected_fee_apr_proxy: pool gross APR × IRP. Python may refine.
    pf.gross_fee_apr * coalesce(irp.in_range_probability_observed, 0.0)    AS expected_fee_apr_proxy,

    irp.in_range_probability_observed                                      AS in_range_probability_observed,
    pf.adverse_selection_cost_apr_proxy                                    AS adverse_selection_cost_proxy,
    pf.capital_utilization                                                 AS capital_utilization,

    -- Raw width-based crowding signal — Python decides risk weighting.
    least(1.0, toFloat64(c.tick_upper - c.tick_lower) / 2000.0)            AS crowding_penalty_raw,

    toUInt8(1)                                                             AS is_estimated,
    now()                                                                  AS updated_at
FROM cells c
LEFT JOIN irp_7d irp
    ON  irp.pool_address = c.pool_address
    AND irp.tick_lower   = c.tick_lower
    AND irp.tick_upper   = c.tick_upper
LEFT JOIN activity_inside a
    ON  a.pool_address = c.pool_address
    AND a.tick_lower   = c.tick_lower
    AND a.tick_upper   = c.tick_upper
LEFT JOIN pool_features pf
    ON pf.pool_address = c.pool_address
