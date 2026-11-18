{{ config(
    order_by=['pool', 'hour', 'tick_lower'],
    partition_by='toYYYYMM(hour)'
) }}

-- Hourly TVL / liquidity distribution centered around the current tick.
--
-- Reconstructs the full hourly bin liquidity curve from hourly boundary-level
-- liquidityNet, then keeps only the bins that overlap a centered local window
-- around the current tick. This is the visualization-ready mart for studying
-- how LP capital recenters around price through time.
--
-- TIME SCOPE — IMPORTANT:
--   This mart is a RECENT-WINDOW snapshot, not a full-history table. It exists to
--   inspect liquidity distribution around the current block / recent hours.
--   Rebuilding it over the whole hourly history joins int_hourly_tick_liquidity_net
--   (158M+ rows) twice and OOMs. By default it only covers the last
--   `hourly_distribution_lookback_days` days (relative to the latest hour in
--   int_hourly_snapshot_blocks). Pass explicit hours to override.
--
-- Optional parameters (dbt vars):
--   hourly_distribution_window_ticks   centered tick window half-width (default 1000)
--   hourly_distribution_lookback_days  rolling window size in days     (default 14)
--   hourly_distribution_start_hour     explicit lower bound (overrides lookback)
--   hourly_distribution_end_hour       explicit upper bound
-- Example (full custom window):
--   dbt run --select mart_tvl_distribution_hourly_centered \
--     --vars '{"hourly_distribution_start_hour": "2026-04-01 00:00:00", "hourly_distribution_end_hour": "2026-04-06 23:59:59"}'
--
-- GRAIN         : 1 row per (pool, hour, tick_lower, tick_upper) within the centered window
-- DEPENDS ON    : int_hourly_snapshot_blocks, int_hourly_tick_liquidity_net, stg_pools
-- KEY DECISIONS :
--   - End-of-hour semantics: LP state includes all LP deltas up to that hour,
--     while price/current_tick are the latest observed swap state carried through that hour.
--   - The centered window is defined by bin overlap with [current_tick - W, current_tick + W].
--     This avoids dropping the active bin when it is wider than tick_spacing.
--   - pct_visible_* are normalized inside the centered window only, which is better
--     suited for relative-shape charts than a global pool share.
--   - Both joins to int_hourly_tick_liquidity_net are bounded by the same hour
--     cutoff so the join build side stays small.

{% set hourly_distribution_window_ticks = var('hourly_distribution_window_ticks', 1000) %}
{% set hourly_distribution_start_hour = var('hourly_distribution_start_hour', none) %}
{% set hourly_distribution_end_hour = var('hourly_distribution_end_hour', none) %}
{% set hourly_distribution_lookback_days = var('hourly_distribution_lookback_days', 14) %}

-- Lower hour bound: explicit start var if given, else (latest hour − lookback days).
{% if hourly_distribution_start_hour is not none %}
  {% set hour_lower_bound %}parseDateTimeBestEffort('{{ hourly_distribution_start_hour }}'){% endset %}
{% else %}
  {% set hour_lower_bound %}(SELECT max(hour) - toIntervalDay({{ hourly_distribution_lookback_days }}) FROM {{ ref('int_hourly_snapshot_blocks') }}){% endset %}
{% endif %}

WITH hourly_state AS (
    SELECT
        hs.pool,
        toDate(hs.hour)                                                         AS date,
        hs.hour,
        hs.has_swap_hour,
        hs.snapshot_block_number,
        hs.snapshot_log_index,
        hs.snapshot_block_time,
        toInt32(hs.current_tick)                                                AS current_tick,
        toFloat64(hs.price_token1_in_token0)                                    AS price_token1_in_token0,
        p.tick_spacing,
        p.token0_symbol,
        p.token1_symbol,
        p.token0_decimals,
        p.token1_decimals,
        {{ sqrt_price_from_price(
            'hs.price_token1_in_token0',
            'p.token0_decimals',
            'p.token1_decimals'
        ) }}                                                                    AS sqrt_price_current
    FROM {{ ref('int_hourly_snapshot_blocks') }} hs
    INNER JOIN {{ ref('stg_pools') }} p ON hs.pool = p.pool
    WHERE hs.current_tick IS NOT NULL
      AND hs.price_token1_in_token0 IS NOT NULL
      AND hs.hour >= {{ hour_lower_bound }}
      {% if hourly_distribution_end_hour is not none %}
      AND hs.hour <= parseDateTimeBestEffort('{{ hourly_distribution_end_hour }}')
      {% endif %}
),

boundary_extents AS (
    SELECT
        hs.pool,
        hs.date,
        hs.hour,
        hs.has_swap_hour,
        hs.snapshot_block_number,
        hs.snapshot_log_index,
        hs.snapshot_block_time,
        hs.current_tick,
        hs.price_token1_in_token0,
        hs.tick_spacing,
        hs.token0_symbol,
        hs.token1_symbol,
        hs.token0_decimals,
        hs.token1_decimals,
        hs.sqrt_price_current,
        if(
            countIf(n.tick < hs.current_tick - {{ hourly_distribution_window_ticks }}) = 0,
            CAST(NULL AS Nullable(Int32)),
            maxIf(toInt32(n.tick), n.tick < hs.current_tick - {{ hourly_distribution_window_ticks }})
        )                                                                            AS previous_tick_before_window,
        if(
            countIf(n.tick > hs.current_tick + {{ hourly_distribution_window_ticks }}) = 0,
            CAST(NULL AS Nullable(Int32)),
            minIf(toInt32(n.tick), n.tick > hs.current_tick + {{ hourly_distribution_window_ticks }})
        )                                                                            AS next_tick_after_window,
        min(toInt32(n.tick))                                                          AS min_tick,
        max(toInt32(n.tick))                                                          AS max_tick
    FROM hourly_state hs
    INNER JOIN {{ ref('int_hourly_tick_liquidity_net') }} n
        ON  hs.pool = n.pool
        AND hs.hour = n.hour
        AND n.hour >= {{ hour_lower_bound }}
    GROUP BY
        hs.pool,
        hs.date,
        hs.hour,
        hs.has_swap_hour,
        hs.snapshot_block_number,
        hs.snapshot_log_index,
        hs.snapshot_block_time,
        hs.current_tick,
        hs.price_token1_in_token0,
        hs.tick_spacing,
        hs.token0_symbol,
        hs.token1_symbol,
        hs.token0_decimals,
        hs.token1_decimals,
        hs.sqrt_price_current
),

local_bounds AS (
    SELECT
        pool,
        date,
        hour,
        has_swap_hour,
        snapshot_block_number,
        snapshot_log_index,
        snapshot_block_time,
        current_tick,
        price_token1_in_token0,
        tick_spacing,
        token0_symbol,
        token1_symbol,
        token0_decimals,
        token1_decimals,
        sqrt_price_current,
        coalesce(previous_tick_before_window, min_tick)                              AS start_tick,
        coalesce(next_tick_after_window, max_tick)                                   AS end_tick
    FROM boundary_extents
    WHERE min_tick < max_tick
),

local_tick_arrays AS (
    SELECT
        b.pool,
        b.date,
        b.hour,
        b.has_swap_hour,
        b.snapshot_block_number,
        b.snapshot_log_index,
        b.snapshot_block_time,
        b.current_tick,
        b.price_token1_in_token0,
        b.tick_spacing,
        b.token0_symbol,
        b.token1_symbol,
        b.token0_decimals,
        b.token1_decimals,
        b.sqrt_price_current,
        b.start_tick,
        b.end_tick,
        sumIf(toFloat64(n.liquidity_net), n.tick < b.start_tick)                     AS base_liquidity_before_window,
        arraySort(
            x -> x.1,
            groupArrayIf(
                (toInt32(n.tick), toFloat64(n.liquidity_net)),
                n.tick >= b.start_tick AND n.tick <= b.end_tick
            )
        )                                                                            AS tick_pairs
    FROM local_bounds b
    INNER JOIN {{ ref('int_hourly_tick_liquidity_net') }} n
        ON  b.pool = n.pool
        AND b.hour = n.hour
        AND n.hour >= {{ hour_lower_bound }}
    GROUP BY
        b.pool,
        b.date,
        b.hour,
        b.has_swap_hour,
        b.snapshot_block_number,
        b.snapshot_log_index,
        b.snapshot_block_time,
        b.current_tick,
        b.price_token1_in_token0,
        b.tick_spacing,
        b.token0_symbol,
        b.token1_symbol,
        b.token0_decimals,
        b.token1_decimals,
        b.sqrt_price_current,
        b.start_tick,
        b.end_tick
),

prepared_arrays AS (
    SELECT
        pool,
        date,
        hour,
        has_swap_hour,
        snapshot_block_number,
        snapshot_log_index,
        snapshot_block_time,
        current_tick,
        price_token1_in_token0,
        tick_spacing,
        token0_symbol,
        token1_symbol,
        token0_decimals,
        token1_decimals,
        sqrt_price_current,
        arrayMap(x -> toInt32(x.1), tick_pairs)                                      AS ticks,
        arrayMap(
            x -> base_liquidity_before_window + x,
            arrayCumSum(arrayMap(x -> toFloat64(x.2), tick_pairs))
        )                                                                            AS cumulative_liquidity
    FROM local_tick_arrays
    WHERE length(tick_pairs) >= 2
),

tick_ranges AS (
    SELECT
        pool,
        date,
        hour,
        has_swap_hour,
        snapshot_block_number,
        snapshot_log_index,
        snapshot_block_time,
        current_tick,
        price_token1_in_token0,
        tick_spacing,
        token0_symbol,
        token1_symbol,
        token0_decimals,
        token1_decimals,
        sqrt_price_current,
        toInt32(ticks[offset + 1])                                               AS tick_lower,
        toInt32(ticks[offset + 2])                                               AS tick_upper,
        greatest(cumulative_liquidity[offset + 1], 0.0)                          AS liquidity
    FROM prepared_arrays
    ARRAY JOIN range(length(ticks) - 1)                                          AS offset
),

bin_bounds AS (
    SELECT
        r.pool,
        r.hour,
        r.date,
        r.has_swap_hour,
        r.snapshot_block_number,
        r.snapshot_log_index,
        r.snapshot_block_time,
        r.current_tick,
        r.price_token1_in_token0,
        r.tick_spacing,
        r.token0_symbol,
        r.token1_symbol,
        r.token0_decimals,
        r.token1_decimals,
        r.tick_lower,
        r.tick_upper,
        r.liquidity,
        {{ sqrt_price_at_tick('r.tick_lower') }}                                 AS sp_low,
        {{ sqrt_price_at_tick('r.tick_upper') }}                                 AS sp_high,
        {{ clamp_sqrt_price('r.sqrt_price_current', 'r.tick_lower', 'r.tick_upper') }} AS sp,
        r.tick_lower <= r.current_tick
            AND r.current_tick < r.tick_upper                                    AS is_active_bin,
        greatest(
            0,
            least(toInt32(r.tick_upper), r.current_tick + {{ hourly_distribution_window_ticks }})
            - greatest(toInt32(r.tick_lower), r.current_tick - {{ hourly_distribution_window_ticks }})
        )                                                                        AS overlap_ticks_with_window
    FROM tick_ranges r
    WHERE r.liquidity > 0
),

windowed_bins AS (
    SELECT
        *,
        toInt32(tick_lower - current_tick)                                       AS relative_tick_lower,
        toInt32(tick_upper - current_tick)                                       AS relative_tick_upper,
        toFloat64((tick_lower + tick_upper) / 2.0 - current_tick)                AS relative_tick_mid,
        toFloat64((tick_lower + tick_upper) / 2.0)                               AS tick_mid
    FROM bin_bounds
    WHERE overlap_ticks_with_window > 0
),

bin_amounts AS (
    SELECT
        pool,
        date,
        hour,
        has_swap_hour,
        snapshot_block_number,
        snapshot_log_index,
        snapshot_block_time,
        current_tick,
        price_token1_in_token0,
        tick_spacing,
        token0_symbol,
        token1_symbol,
        tick_lower,
        tick_upper,
        tick_mid,
        relative_tick_lower,
        relative_tick_upper,
        relative_tick_mid,
        overlap_ticks_with_window,
        liquidity,
        is_active_bin,
        {{ amount0_from_liquidity('liquidity', 'sp', 'sp_high', 'token0_decimals') }}   AS amount0,
        {{ amount1_from_liquidity('liquidity', 'sp', 'sp_low', 'token1_decimals') }}    AS amount1
    FROM windowed_bins
),

valued_bins AS (
    SELECT
        *,
        amount0 + amount1 * toFloat64(price_token1_in_token0)                    AS tvl_token0
    FROM bin_amounts
)

SELECT
    pool,
    date,
    hour,
    has_swap_hour,
    snapshot_block_number,
    snapshot_log_index,
    snapshot_block_time,
    current_tick,
    price_token1_in_token0,
    tick_spacing,
    token0_symbol,
    token1_symbol,
    tick_lower,
    tick_upper,
    tick_mid,
    relative_tick_lower,
    relative_tick_upper,
    relative_tick_mid,
    overlap_ticks_with_window,
    liquidity,
    is_active_bin,
    amount0,
    amount1,
    tvl_token0,
    100.0 * liquidity / nullIf(sum(liquidity) OVER (PARTITION BY pool, hour), 0.0) AS pct_visible_liquidity,
    100.0 * tvl_token0 / nullIf(sum(tvl_token0) OVER (PARTITION BY pool, hour), 0.0) AS pct_visible_tvl
FROM valued_bins
