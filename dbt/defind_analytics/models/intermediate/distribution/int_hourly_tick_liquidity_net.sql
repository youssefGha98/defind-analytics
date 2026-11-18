{{ config(
    order_by=['pool', 'tick', 'hour'],
    partition_by='toYYYYMM(hour)'
) }}

-- Hourly liquidityNet state at each LP tick boundary.
--
-- For each (pool, tick), we accumulate canonical boundary deltas through time so downstream hourly
-- marts can reconstruct the full bin liquidity curve with a second cumsum over tick.
--
-- GRAIN         : 1 row per (pool, hour, tick)
-- DEPENDS ON    : int_hourly_snapshot_blocks, int_tick_boundary_deltas
-- KEY DECISIONS :
--   - The hour spine comes from int_hourly_snapshot_blocks so LP-only quiet hours
--     remain represented.
--   - Distinct tick boundaries come from int_tick_boundary_deltas only; bins never exist
--     outside the observed LP range boundaries.
--   - liquidity_net is the cumulative net delta at that boundary as of hour-end.

WITH tick_boundaries AS (
    SELECT
        pool,
        tick_boundary AS tick
    FROM {{ ref('int_tick_boundary_deltas') }}
    GROUP BY pool, tick_boundary
),

hourly_tick_deltas AS (
    SELECT
        pool,
        toStartOfHour(block_time)                                               AS hour,
        tick_boundary                                                          AS tick,
        sum(liquidity_net_delta)                                               AS liquidity_delta
    FROM {{ ref('int_tick_boundary_deltas') }}
    GROUP BY pool, toStartOfHour(block_time), tick_boundary
),

hour_tick_spine AS (
    SELECT
        hs.pool,
        hs.hour,
        tb.tick
    FROM {{ ref('int_hourly_snapshot_blocks') }} hs
    INNER JOIN tick_boundaries tb ON hs.pool = tb.pool
),

hourly_changes AS (
    SELECT
        spine.pool,
        spine.hour,
        spine.tick,
        coalesce(deltas.liquidity_delta, 0)                                     AS liquidity_delta
    FROM hour_tick_spine spine
    LEFT JOIN hourly_tick_deltas deltas
        ON  spine.pool = deltas.pool
        AND spine.hour = deltas.hour
        AND spine.tick = deltas.tick
)

SELECT
    assumeNotNull(pool)                                                           AS pool,
    toDateTime(assumeNotNull(hour))                                               AS hour,
    toInt32(assumeNotNull(tick))                                                  AS tick,
    sum(toInt128(liquidity_delta)) OVER (
        PARTITION BY pool, tick
        ORDER BY hour
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                                            AS liquidity_net
FROM hourly_changes
