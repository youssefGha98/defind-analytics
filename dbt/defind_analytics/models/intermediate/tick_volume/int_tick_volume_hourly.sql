{{ config(
    order_by=['pool', 'hour', 'tick'],
    partition_by='toYYYYMM(hour)'
) }}

-- Hourly swap volume attributed to the active tick before execution.
--
-- This is the exact time-bucketed flow view for tick studies: each swap remains
-- assigned to the tick that was active immediately before it executes, then gets
-- aggregated into hourly buckets.
--
-- GRAIN         : 1 row per (pool, hour, tick)
-- DEPENDS ON    : int_swaps_tick_volume

SELECT
    pool,
    toStartOfHour(block_time)                                                 AS hour,
    active_tick                                                               AS tick,
    count()                                                                   AS swap_count,
    sum(fallback_after_swap)                                                  AS fallback_after_swap_count,
    round(sum(volume_token0), 6)                                              AS volume_token0,
    round(sum(volume_token1), 12)                                             AS volume_token1,
    round(sum(volume_token0_equiv), 6)                                        AS volume_token0_equiv,
    round(sum(fees_generated_token0), 6)                                      AS fees_generated_token0,
    round(sum(fees_generated_token1), 12)                                     AS fees_generated_token1,
    round(sum(fees_generated_token0_equiv), 6)                                AS fees_generated_token0_equiv
FROM {{ ref('int_swaps_tick_volume') }}
GROUP BY pool, toStartOfHour(block_time), active_tick
