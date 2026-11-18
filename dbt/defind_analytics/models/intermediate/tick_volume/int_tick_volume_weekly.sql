{{ config(
    order_by=['pool', 'week_start', 'tick'],
    partition_by='toYYYYMM(week_start)'
) }}

-- Weekly tick volume derived from exact hourly flow.
--
-- Volume aggregation is associative, so weekly sums can safely reuse the hourly
-- layer without losing token0/token1 composition.
--
-- GRAIN         : 1 row per (pool, week_start, tick)
-- DEPENDS ON    : int_tick_volume_hourly
-- WEEK SEMANTIC : calendar week starting Monday

SELECT
    pool,
    toStartOfWeek(toDate(hour), 1)                                             AS week_start,
    tick,
    sum(swap_count)                                                            AS swap_count,
    sum(fallback_after_swap_count)                                             AS fallback_after_swap_count,
    round(sum(volume_token0), 6)                                               AS volume_token0,
    round(sum(volume_token1), 12)                                              AS volume_token1,
    round(sum(volume_token0_equiv), 6)                                         AS volume_token0_equiv,
    round(sum(fees_generated_token0), 6)                                       AS fees_generated_token0,
    round(sum(fees_generated_token1), 12)                                      AS fees_generated_token1,
    round(sum(fees_generated_token0_equiv), 6)                                 AS fees_generated_token0_equiv
FROM {{ ref('int_tick_volume_hourly') }}
GROUP BY pool, toStartOfWeek(toDate(hour), 1), tick
