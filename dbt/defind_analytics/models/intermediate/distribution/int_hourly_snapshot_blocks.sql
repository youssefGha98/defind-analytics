{{ config(
    order_by=['pool', 'hour'],
    partition_by='toYYYYMM(hour)'
) }}

-- Dense hourly pool-state spine.
--
-- One row per (pool, hour) across the pool's observed activity window.
-- LP-only hours are preserved so downstream hourly distribution models can
-- revalue the pool when composition changes without a new swap. Swap-derived
-- state is carried forward from the most recent observed swap hour.
--
-- GRAIN         : 1 row per (pool, hour)
-- DEPENDS ON    : stg_swaps, int_lp_events
-- KEY DECISIONS :
--   - Bounds come from the union of swaps and LP events, not swaps only.
--     This preserves hours where LP composition changes but price does not.
--   - snapshot_* / current_tick / price_token1_in_token0 come only from swaps
--     and are carried forward hour by hour using the last observed swap key.
--   - Hours before the first observed swap remain in the table with NULL state.
--     Downstream marts can decide whether to filter them or keep them for QA.

WITH activity_hours AS (
    SELECT
        pool,
        toStartOfHour(block_time) AS hour
    FROM {{ ref('stg_swaps') }}

    UNION ALL

    SELECT
        pool,
        toStartOfHour(block_time) AS hour
    FROM {{ ref('int_lp_events') }}
),

hour_bounds AS (
    SELECT
        pool,
        min(hour) AS min_hour,
        max(hour) AS max_hour
    FROM activity_hours
    GROUP BY pool
),

hour_spine AS (
    SELECT
        pool,
        addHours(min_hour, toInt32(offset)) AS hour
    FROM hour_bounds
    ARRAY JOIN range(toUInt32(dateDiff('hour', min_hour, max_hour) + 1)) AS offset
),

hourly_swaps AS (
    SELECT
        pool,
        toStartOfHour(block_time)                                               AS hour,
        argMax(block_number,            tuple(block_number, log_index))          AS snapshot_block_number,
        argMax(log_index,               tuple(block_number, log_index))          AS snapshot_log_index,
        argMax(block_time,              tuple(block_number, log_index))          AS snapshot_block_time,
        argMax(tick,                    tuple(block_number, log_index))          AS current_tick,
        argMax(price_token1_in_token0,  tuple(block_number, log_index))          AS price_token1_in_token0
    FROM {{ ref('stg_swaps') }}
    GROUP BY pool, toStartOfHour(block_time)
),

dense_with_nulls AS (
    SELECT
        hs.pool,
        hs.hour,
        if(os.snapshot_block_number IS NOT NULL, toUInt8(1), toUInt8(0))        AS has_swap_hour,
        if(
            os.snapshot_block_number IS NOT NULL,
            toNullable(os.snapshot_block_number),
            CAST(NULL AS Nullable(UInt64))
        )                                                                        AS snapshot_block_number,
        if(
            os.snapshot_block_number IS NOT NULL,
            toNullable(os.snapshot_log_index),
            CAST(NULL AS Nullable(UInt64))
        )                                                                        AS snapshot_log_index,
        if(
            os.snapshot_block_number IS NOT NULL,
            toNullable(os.snapshot_block_time),
            CAST(NULL AS Nullable(DateTime))
        )                                                                        AS snapshot_block_time,
        CAST(NULL AS Nullable(Int32))                                             AS current_tick,
        CAST(NULL AS Nullable(Float64))                                           AS price_token1_in_token0
    FROM hour_spine hs
    LEFT JOIN hourly_swaps os
        ON  hs.pool = os.pool
        AND hs.hour = os.hour
),

carried_state AS (
    SELECT
        pool,
        hour,
        has_swap_hour,
        last_value(snapshot_block_number) IGNORE NULLS OVER (
            PARTITION BY pool
            ORDER BY hour
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                        AS snapshot_block_number,
        last_value(snapshot_log_index) IGNORE NULLS OVER (
            PARTITION BY pool
            ORDER BY hour
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                        AS snapshot_log_index,
        last_value(snapshot_block_time) IGNORE NULLS OVER (
            PARTITION BY pool
            ORDER BY hour
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                        AS snapshot_block_time
    FROM dense_with_nulls
)

SELECT
    assumeNotNull(cs.pool)                                                      AS pool,
    toDateTime(assumeNotNull(cs.hour))                                          AS hour,
    cs.has_swap_hour,
    cs.snapshot_block_number,
    cs.snapshot_log_index,
    cs.snapshot_block_time,
    s.tick                                                                     AS current_tick,
    s.price_token1_in_token0
FROM carried_state cs
LEFT JOIN {{ ref('stg_swaps') }} s
    ON  cs.pool = s.pool
    AND cs.snapshot_block_number = s.block_number
    AND cs.snapshot_log_index = s.log_index
