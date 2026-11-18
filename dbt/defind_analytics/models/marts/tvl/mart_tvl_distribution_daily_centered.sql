{{ config(
    order_by=['pool', 'date', 'tick_lower'],
    partition_by='toYYYYMM(date)'
) }}

-- Daily TVL / liquidity distribution centered around the current tick.
--
-- Reconstructs the full daily bin liquidity curve from daily boundary-level
-- liquidityNet, then keeps only the bins that overlap a centered local window
-- around the day-end current tick. This is the dashboard-ready mart for
-- studying slower recentering dynamics without the cost of hourly snapshots.
--
-- Optional parameter: daily_distribution_window_ticks (default = 1000)
--
-- GRAIN         : 1 row per (pool, date, tick_lower, tick_upper) within the centered window
-- DEPENDS ON    : int_daily_snapshot_blocks, int_daily_tick_liquidity_net, stg_pools
-- KEY DECISIONS :
--   - End-of-day semantics: LP state includes all LP deltas up to that day,
--     while price/current_tick are the latest observed swap state carried through that day.
--   - The centered window is defined by bin overlap with [current_tick - W, current_tick + W].
--   - pct_visible_* are normalized inside the centered window only.

{% set daily_distribution_window_ticks = var('daily_distribution_window_ticks', 1000) %}
{% set daily_distribution_start_date = var('daily_distribution_start_date', none) %}
{% set daily_distribution_end_date = var('daily_distribution_end_date', none) %}

WITH daily_state AS (
    SELECT
        ds.pool,
        ds.date,
        ds.has_swap_day,
        ds.snapshot_block_number,
        ds.snapshot_log_index,
        ds.snapshot_block_time,
        toInt32(ds.current_tick)                                                AS current_tick,
        toFloat64(ds.price_token1_in_token0)                                    AS price_token1_in_token0,
        p.tick_spacing,
        p.token0_symbol,
        p.token1_symbol,
        p.token0_decimals,
        p.token1_decimals,
        {{ sqrt_price_from_price(
            'ds.price_token1_in_token0',
            'p.token0_decimals',
            'p.token1_decimals'
        ) }}                                                                    AS sqrt_price_current
    FROM {{ ref('int_daily_snapshot_blocks') }} ds
    INNER JOIN {{ ref('stg_pools') }} p ON ds.pool = p.pool
    WHERE ds.current_tick IS NOT NULL
      AND ds.price_token1_in_token0 IS NOT NULL
      {% if daily_distribution_start_date is not none %}
      AND ds.date >= toDate(parseDateTimeBestEffort('{{ daily_distribution_start_date }}'))
      {% endif %}
      {% if daily_distribution_end_date is not none %}
      AND ds.date <= toDate(parseDateTimeBestEffort('{{ daily_distribution_end_date }}'))
      {% endif %}
),

boundary_extents AS (
    SELECT
        ds.pool,
        ds.date,
        ds.has_swap_day,
        ds.snapshot_block_number,
        ds.snapshot_log_index,
        ds.snapshot_block_time,
        ds.current_tick,
        ds.price_token1_in_token0,
        ds.tick_spacing,
        ds.token0_symbol,
        ds.token1_symbol,
        ds.token0_decimals,
        ds.token1_decimals,
        ds.sqrt_price_current,
        if(
            countIf(n.tick < ds.current_tick - {{ daily_distribution_window_ticks }}) = 0,
            CAST(NULL AS Nullable(Int32)),
            maxIf(toInt32(n.tick), n.tick < ds.current_tick - {{ daily_distribution_window_ticks }})
        )                                                                       AS previous_tick_before_window,
        if(
            countIf(n.tick > ds.current_tick + {{ daily_distribution_window_ticks }}) = 0,
            CAST(NULL AS Nullable(Int32)),
            minIf(toInt32(n.tick), n.tick > ds.current_tick + {{ daily_distribution_window_ticks }})
        )                                                                       AS next_tick_after_window,
        min(toInt32(n.tick))                                                    AS min_tick,
        max(toInt32(n.tick))                                                    AS max_tick
    FROM daily_state ds
    INNER JOIN {{ ref('int_daily_tick_liquidity_net') }} n
        ON  ds.pool = n.pool
        AND ds.date = n.date
    GROUP BY
        ds.pool,
        ds.date,
        ds.has_swap_day,
        ds.snapshot_block_number,
        ds.snapshot_log_index,
        ds.snapshot_block_time,
        ds.current_tick,
        ds.price_token1_in_token0,
        ds.tick_spacing,
        ds.token0_symbol,
        ds.token1_symbol,
        ds.token0_decimals,
        ds.token1_decimals,
        ds.sqrt_price_current
),

local_bounds AS (
    SELECT
        pool,
        date,
        has_swap_day,
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
        coalesce(previous_tick_before_window, min_tick)                         AS start_tick,
        coalesce(next_tick_after_window, max_tick)                              AS end_tick
    FROM boundary_extents
    WHERE min_tick < max_tick
),

local_tick_arrays AS (
    SELECT
        b.pool,
        b.date,
        b.has_swap_day,
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
        sumIf(toFloat64(n.liquidity_net), n.tick < b.start_tick)                AS base_liquidity_before_window,
        arraySort(
            x -> x.1,
            groupArrayIf(
                (toInt32(n.tick), toFloat64(n.liquidity_net)),
                n.tick >= b.start_tick AND n.tick <= b.end_tick
            )
        )                                                                       AS tick_pairs
    FROM local_bounds b
    INNER JOIN {{ ref('int_daily_tick_liquidity_net') }} n
        ON  b.pool = n.pool
        AND b.date = n.date
    GROUP BY
        b.pool,
        b.date,
        b.has_swap_day,
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
        has_swap_day,
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
        arrayMap(x -> toInt32(x.1), tick_pairs)                                 AS ticks,
        arrayMap(
            x -> base_liquidity_before_window + x,
            arrayCumSum(arrayMap(x -> toFloat64(x.2), tick_pairs))
        )                                                                       AS cumulative_liquidity
    FROM local_tick_arrays
    WHERE length(tick_pairs) >= 2
),

tick_ranges AS (
    SELECT
        pool,
        date,
        has_swap_day,
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
        toInt32(ticks[offset + 1])                                              AS tick_lower,
        toInt32(ticks[offset + 2])                                              AS tick_upper,
        greatest(cumulative_liquidity[offset + 1], 0.0)                         AS liquidity
    FROM prepared_arrays
    ARRAY JOIN range(length(ticks) - 1)                                         AS offset
),

bin_bounds AS (
    SELECT
        r.pool,
        r.date,
        r.has_swap_day,
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
        {{ sqrt_price_at_tick('r.tick_lower') }}                                AS sp_low,
        {{ sqrt_price_at_tick('r.tick_upper') }}                                AS sp_high,
        {{ clamp_sqrt_price('r.sqrt_price_current', 'r.tick_lower', 'r.tick_upper') }} AS sp,
        r.tick_lower <= r.current_tick
            AND r.current_tick < r.tick_upper                                   AS is_active_bin,
        greatest(
            0,
            least(toInt32(r.tick_upper), r.current_tick + {{ daily_distribution_window_ticks }})
            - greatest(toInt32(r.tick_lower), r.current_tick - {{ daily_distribution_window_ticks }})
        )                                                                       AS overlap_ticks_with_window
    FROM tick_ranges r
    WHERE r.liquidity > 0
),

windowed_bins AS (
    SELECT
        *,
        toInt32(tick_lower - current_tick)                                      AS relative_tick_lower,
        toInt32(tick_upper - current_tick)                                      AS relative_tick_upper,
        toFloat64((tick_lower + tick_upper) / 2.0 - current_tick)               AS relative_tick_mid,
        toFloat64((tick_lower + tick_upper) / 2.0)                              AS tick_mid
    FROM bin_bounds
    WHERE overlap_ticks_with_window > 0
),

bin_amounts AS (
    SELECT
        pool,
        date,
        has_swap_day,
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
        {{ amount0_from_liquidity('liquidity', 'sp', 'sp_high', 'token0_decimals') }}  AS amount0,
        {{ amount1_from_liquidity('liquidity', 'sp', 'sp_low', 'token1_decimals') }}   AS amount1
    FROM windowed_bins
),

valued_bins AS (
    SELECT
        *,
        amount0 + amount1 * toFloat64(price_token1_in_token0)                   AS tvl_token0
    FROM bin_amounts
)

SELECT
    pool,
    date,
    has_swap_day,
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
    100.0 * liquidity / nullIf(sum(liquidity) OVER (PARTITION BY pool, date), 0.0) AS pct_visible_liquidity,
    100.0 * tvl_token0 / nullIf(sum(tvl_token0) OVER (PARTITION BY pool, date), 0.0) AS pct_visible_tvl
FROM valued_bins
