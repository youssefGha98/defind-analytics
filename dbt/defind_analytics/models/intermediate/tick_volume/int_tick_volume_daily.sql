{{ config(
    order_by=['pool', 'date', 'tick'],
    partition_by='toYYYYMM(date)'
) }}

-- Daily swap volume attributed to the active tick before execution.
--
-- This aggregates exact hourly tick flow to a daily view. Because volume is
-- additive, the hourly layer is a safe reusable base for broader periods.
--
-- GRAIN         : 1 row per (pool, date, tick)
-- DEPENDS ON    : int_tick_volume_hourly

SELECT
    pool,
    toDate(hour)                                                               AS date,
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
GROUP BY pool, toDate(hour), tick
