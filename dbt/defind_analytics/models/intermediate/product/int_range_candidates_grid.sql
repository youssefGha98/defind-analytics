-- Per-pool/day candidate range grid for the Range Optimizer.
--
-- Generates 6 candidate ranges per (pool, date), all snapped to the pool's
-- tick_spacing. These are the inputs to mart_range_candidates_features and
-- mart_range_heatmap_features. Range scoring/ranking happens in Python, not here.
--
-- Candidate set (V1):
--   centered_1pct      ±100 ticks  ≈ ±1%
--   centered_2pct      ±200 ticks  ≈ ±2%
--   centered_5pct      ±500 ticks  ≈ ±5%
--   centered_10pct     ±1000 ticks ≈ ±10%
--   shifted_up_2pct    ±200 ticks centered on (close_tick + 200)
--   shifted_down_2pct  ±200 ticks centered on (close_tick - 200)
--
-- A 1% price move is ~100 ticks in V3 because ln(1.01) / ln(1.0001) ≈ 99.5.
--
-- Snap convention:
--   tick_lower snapped DOWN (floor) to tick_spacing
--   tick_upper snapped UP   (ceil)  to tick_spacing
-- This guarantees the actual realized width is >= the requested half_width on each
-- side — never silently narrower than requested.
--
-- GRAIN         : 1 row per (pool, date, candidate_id) — 6 rows per pool/day
-- DEPENDS ON    : int_daily_close_dense, stg_pools, dim_indexed_pools
-- KEY DECISIONS :
--   - Scoped to indexed pools via dim_indexed_pools (pool universe gate).
--   - Skips days where close_tick is NULL (warm-up before first observed swap).
--   - Floor/ceil are computed via float division so they handle negative ticks
--     correctly (USDC/WETH ticks are negative).

{{ config(materialized='table') }}

WITH spine AS (
    SELECT
        d.pool                                                             AS pool,
        d.date                                                             AS date,
        d.close_tick                                                       AS close_tick,
        d.close_price                                                      AS close_price,
        d.has_swap                                                         AS has_swap,
        p.tick_spacing                                                     AS tick_spacing
    FROM {{ ref('int_daily_close_dense') }} d
    INNER JOIN {{ ref('dim_indexed_pools') }} dim ON dim.pool_address = d.pool AND dim.is_active = 1
    INNER JOIN {{ ref('stg_pools') }} p             ON p.pool         = d.pool
    WHERE d.close_tick IS NOT NULL
),

candidate_specs AS (
    SELECT
        candidate_id,
        range_type,
        toInt32(half_width_ticks) AS half_width_ticks,
        toInt32(shift_ticks)      AS shift_ticks
    FROM (
        SELECT 'centered_1pct'      AS candidate_id, 'centered'     AS range_type, 100   AS half_width_ticks, 0    AS shift_ticks
        UNION ALL SELECT 'centered_2pct',     'centered',     200,   0
        UNION ALL SELECT 'centered_5pct',     'centered',     500,   0
        UNION ALL SELECT 'centered_10pct',    'centered',     1000,  0
        UNION ALL SELECT 'shifted_up_2pct',   'shifted_up',   200,   200
        UNION ALL SELECT 'shifted_down_2pct', 'shifted_down', 200,  -200
    )
),

raw_ranges AS (
    SELECT
        s.pool,
        s.date,
        s.close_tick,
        s.close_price,
        s.has_swap,
        s.tick_spacing,
        c.candidate_id,
        c.range_type,
        c.half_width_ticks,
        c.shift_ticks,
        s.close_tick + c.shift_ticks - c.half_width_ticks                  AS raw_lower,
        s.close_tick + c.shift_ticks + c.half_width_ticks                  AS raw_upper
    FROM spine s
    CROSS JOIN candidate_specs c
)

SELECT
    pool,
    date,
    candidate_id,
    range_type,
    close_tick,
    close_price,
    has_swap,
    tick_spacing,
    half_width_ticks,
    shift_ticks,

    -- Floor lower / ceil upper to tick_spacing using float math (negative-safe).
    toInt32(floor(toFloat64(raw_lower) / toFloat64(tick_spacing)) * toFloat64(tick_spacing))            AS tick_lower,
    toInt32(ceil(toFloat64(raw_upper)  / toFloat64(tick_spacing)) * toFloat64(tick_spacing))            AS tick_upper,

    raw_lower                                                              AS raw_tick_lower,
    raw_upper                                                              AS raw_tick_upper
FROM raw_ranges
