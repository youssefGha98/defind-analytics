{{ config(
    order_by=['pool', 'date', 'tick'],
    partition_by='toYYYYMM(date)'
) }}

-- Daily liquidityNet state at each LP tick boundary.
--
-- For each (pool, tick), we accumulate canonical boundary deltas through time so downstream daily
-- marts can reconstruct the full bin liquidity curve with a second cumsum over tick.
--
-- GRAIN         : 1 row per (pool, date, tick)
-- DEPENDS ON    : int_daily_snapshot_blocks, int_tick_boundary_deltas
-- KEY DECISIONS :
--   - The date spine comes from int_daily_snapshot_blocks so LP-only quiet days
--     remain represented.
--   - Distinct tick boundaries come from int_tick_boundary_deltas only.
--   - liquidity_net is the cumulative net delta at that boundary as of day-end.

WITH tick_boundaries AS (
    SELECT
        pool,
        tick_boundary AS tick
    FROM {{ ref('int_tick_boundary_deltas') }}
    GROUP BY pool, tick_boundary
),

daily_tick_deltas AS (
    SELECT
        pool,
        toDate(block_time)                                                       AS date,
        tick_boundary                                                          AS tick,
        sum(liquidity_net_delta)                                               AS liquidity_delta
    FROM {{ ref('int_tick_boundary_deltas') }}
    GROUP BY pool, toDate(block_time), tick_boundary
),

date_tick_spine AS (
    SELECT
        ds.pool,
        ds.date,
        tb.tick
    FROM {{ ref('int_daily_snapshot_blocks') }} ds
    INNER JOIN tick_boundaries tb ON ds.pool = tb.pool
),

daily_changes AS (
    SELECT
        spine.pool,
        spine.date,
        spine.tick,
        coalesce(deltas.liquidity_delta, 0)                                      AS liquidity_delta
    FROM date_tick_spine spine
    LEFT JOIN daily_tick_deltas deltas
        ON  spine.pool = deltas.pool
        AND spine.date = deltas.date
        AND spine.tick = deltas.tick
)

SELECT
    assumeNotNull(pool)                                                          AS pool,
    toDate(assumeNotNull(date))                                                  AS date,
    toInt32(assumeNotNull(tick))                                                 AS tick,
    sum(toInt128(liquidity_delta)) OVER (
        PARTITION BY pool, tick
        ORDER BY date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                                            AS liquidity_net
FROM daily_changes
