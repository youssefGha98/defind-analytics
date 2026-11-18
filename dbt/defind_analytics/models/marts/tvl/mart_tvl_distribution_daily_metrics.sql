{{ config(
    order_by=['pool', 'date'],
    partition_by='toYYYYMM(date)'
) }}

-- Daily recentering metrics derived from the centered local TVL distribution.
--
-- This mart compresses the per-bin daily distribution into one row per day with
-- interpretable concentration metrics suitable for slower-moving time-series charts.
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : mart_tvl_distribution_daily_centered
-- KEY DECISIONS :
--   - All shares are computed inside the visible centered window only.
--   - share_overlapping_* uses bin overlap with [current_tick - N, current_tick + N].
--   - weighted_* statistics use relative_tick_mid weighted by tvl_token0.

WITH metrics_base AS (
    SELECT
        *,
        greatest(
            0,
            least(toInt32(tick_upper), current_tick + 50)
            - greatest(toInt32(tick_lower), current_tick - 50)
        ) > 0                                                                    AS overlaps_50_ticks,
        greatest(
            0,
            least(toInt32(tick_upper), current_tick + 100)
            - greatest(toInt32(tick_lower), current_tick - 100)
        ) > 0                                                                    AS overlaps_100_ticks,
        greatest(
            0,
            least(toInt32(tick_upper), current_tick + 250)
            - greatest(toInt32(tick_lower), current_tick - 250)
        ) > 0                                                                    AS overlaps_250_ticks,
        greatest(
            0,
            least(toInt32(tick_upper), current_tick + 500)
            - greatest(toInt32(tick_lower), current_tick - 500)
        ) > 0                                                                    AS overlaps_500_ticks
    FROM {{ ref('mart_tvl_distribution_daily_centered') }}
),

aggregated AS (
    SELECT
        pool,
        date,
        any(snapshot_block_number)                                               AS snapshot_block_number,
        any(snapshot_log_index)                                                  AS snapshot_log_index,
        any(snapshot_block_time)                                                 AS snapshot_block_time,
        any(current_tick)                                                        AS current_tick,
        any(price_token1_in_token0)                                              AS price_token1_in_token0,
        sum(tvl_token0)                                                          AS visible_tvl_token0,
        sumIf(tvl_token0, is_active_bin = 1)                                     AS current_bin_tvl_token0,
        sumIf(liquidity, is_active_bin = 1)                                      AS current_bin_liquidity,
        sumIf(tvl_token0, overlaps_50_ticks)                                     AS overlapping_50_tvl_token0,
        sumIf(tvl_token0, overlaps_100_ticks)                                    AS overlapping_100_tvl_token0,
        sumIf(tvl_token0, overlaps_250_ticks)                                    AS overlapping_250_tvl_token0,
        sumIf(tvl_token0, overlaps_500_ticks)                                    AS overlapping_500_tvl_token0,
        sum(relative_tick_mid * tvl_token0)                                      AS weighted_relative_tick_sum,
        sum(abs(relative_tick_mid) * tvl_token0)                                 AS weighted_abs_relative_tick_sum,
        sum(pow(relative_tick_mid, 2) * tvl_token0)                              AS weighted_relative_tick_sq_sum
    FROM metrics_base
    GROUP BY pool, date
)

SELECT
    pool,
    date,
    snapshot_block_number,
    snapshot_log_index,
    snapshot_block_time,
    current_tick,
    price_token1_in_token0,
    visible_tvl_token0,
    current_bin_tvl_token0,
    current_bin_liquidity,
    current_bin_tvl_token0 / nullIf(visible_tvl_token0, 0.0)                    AS current_bin_share_visible,
    overlapping_50_tvl_token0 / nullIf(visible_tvl_token0, 0.0)                 AS share_overlapping_50_ticks,
    overlapping_100_tvl_token0 / nullIf(visible_tvl_token0, 0.0)                AS share_overlapping_100_ticks,
    overlapping_250_tvl_token0 / nullIf(visible_tvl_token0, 0.0)                AS share_overlapping_250_ticks,
    overlapping_500_tvl_token0 / nullIf(visible_tvl_token0, 0.0)                AS share_overlapping_500_ticks,
    weighted_relative_tick_sum / nullIf(visible_tvl_token0, 0.0)                AS weighted_mean_relative_tick,
    weighted_abs_relative_tick_sum / nullIf(visible_tvl_token0, 0.0)            AS weighted_abs_relative_tick,
    sqrt(greatest(
        weighted_relative_tick_sq_sum / nullIf(visible_tvl_token0, 0.0)
        - pow(weighted_relative_tick_sum / nullIf(visible_tvl_token0, 0.0), 2),
        0.0
    ))                                                                          AS weighted_std_relative_tick
FROM aggregated
