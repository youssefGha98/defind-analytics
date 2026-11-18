{{ config(
    order_by=['pool', 'date'],
    partition_by='toYYYYMM(date)'
) }}

-- Dense daily pool-state spine.
--
-- One row per (pool, date) across the pool's observed activity window.
-- LP-only days are preserved so downstream daily distribution models can
-- revalue the pool when composition changes without a new swap. Swap-derived
-- state is carried forward from the most recent observed swap date.
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : stg_swaps, int_lp_events
-- KEY DECISIONS :
--   - Bounds come from the union of swaps and LP events, not swaps only.
--   - snapshot_* / current_tick / price_token1_in_token0 come only from swaps
--     and are carried forward date by date using the last observed swap key.
--   - Dates before the first observed swap remain in the table with NULL state.
--     Downstream marts can decide whether to filter them or keep them for QA.

WITH activity_dates AS (
    SELECT
        pool,
        toDate(block_time) AS date
    FROM {{ ref('stg_swaps') }}

    UNION ALL

    SELECT
        pool,
        toDate(block_time) AS date
    FROM {{ ref('int_lp_events') }}
),

date_bounds AS (
    SELECT
        pool,
        min(date) AS min_date,
        max(date) AS max_date
    FROM activity_dates
    GROUP BY pool
),

date_spine AS (
    SELECT
        pool,
        addDays(min_date, toInt32(offset)) AS date
    FROM date_bounds
    ARRAY JOIN range(toUInt32(dateDiff('day', min_date, max_date) + 1)) AS offset
),

daily_swaps AS (
    SELECT
        pool,
        toDate(block_time)                                                       AS date,
        argMax(block_number,            tuple(block_number, log_index))          AS snapshot_block_number,
        argMax(log_index,               tuple(block_number, log_index))          AS snapshot_log_index,
        argMax(block_time,              tuple(block_number, log_index))          AS snapshot_block_time,
        argMax(tick,                    tuple(block_number, log_index))          AS current_tick,
        argMax(price_token1_in_token0,  tuple(block_number, log_index))          AS price_token1_in_token0
    FROM {{ ref('stg_swaps') }}
    GROUP BY pool, toDate(block_time)
),

dense_with_nulls AS (
    SELECT
        ds.pool,
        ds.date,
        if(os.snapshot_block_number IS NOT NULL, toUInt8(1), toUInt8(0))        AS has_swap_day,
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
        CAST(NULL AS Nullable(Int32))                                            AS current_tick,
        CAST(NULL AS Nullable(Float64))                                          AS price_token1_in_token0
    FROM date_spine ds
    LEFT JOIN daily_swaps os
        ON  ds.pool = os.pool
        AND ds.date = os.date
),

carried_state AS (
    SELECT
        pool,
        date,
        has_swap_day,
        last_value(snapshot_block_number) IGNORE NULLS OVER (
            PARTITION BY pool
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                        AS snapshot_block_number,
        last_value(snapshot_log_index) IGNORE NULLS OVER (
            PARTITION BY pool
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                        AS snapshot_log_index,
        last_value(snapshot_block_time) IGNORE NULLS OVER (
            PARTITION BY pool
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                        AS snapshot_block_time
    FROM dense_with_nulls
)

SELECT
    assumeNotNull(cs.pool)                                                      AS pool,
    toDate(assumeNotNull(cs.date))                                              AS date,
    cs.has_swap_day,
    cs.snapshot_block_number,
    cs.snapshot_log_index,
    cs.snapshot_block_time,
    s.tick                                                                      AS current_tick,
    s.price_token1_in_token0
FROM carried_state cs
LEFT JOIN {{ ref('stg_swaps') }} s
    ON  cs.pool = s.pool
    AND cs.snapshot_block_number = s.block_number
    AND cs.snapshot_log_index = s.log_index
