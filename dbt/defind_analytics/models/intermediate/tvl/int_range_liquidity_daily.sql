-- Dense daily net liquidity per pool/range.
--
-- This materializes the expensive LP-event cumulative state once, so downstream
-- daily models can join on (pool, date) instead of repeating a non-equi cumsum.
-- Semantics remain date-based: all LP events on a calendar day affect that day's snapshot.
-- Each pool is spined independently: range dates never extend beyond that pool's
-- own activity window, even if other pools are active much earlier or later.
--
-- GRAIN         : 1 row per (pool, date, tick_lower, tick_upper) where net_liquidity > 0
-- DEPENDS ON    : int_lp_events, int_daily_close
-- KEY DECISIONS :
--   - Date spine is built per range (pool × tick_lower × tick_upper), not per pool.
--     This avoids materializing zero rows before a range first appears.
--   - ARRAY JOIN range(N) expands each range into N daily rows starting from its
--     first event date, then LEFT JOIN fills days without LP events with delta = 0.
--   - greatest(cumsum, 0) is a TEMPORARY GUARD against negative net_liquidity caused
--     by the int24 sign overflow bug in DefInd (corrupted tick rows that slipped in
--     before the toInt32OrNull guard was added in stg_mints/stg_burns).
--     Remove once DefInd fix is deployed, source data is reprocessed, and the
--     dbt test below is green.
--   - TODO: add a dbt test that asserts no range ever has a negative cumsum before
--     the greatest() clamp. Once that test is consistently green in prod, the clamp
--     and this guard can be removed.
--   - WHERE net_liquidity > 0 drops closed ranges (fully burned positions) to keep
--     the table lean for downstream joins.

WITH activity_dates AS (
    SELECT
        pool,
        toDate(block_time) AS date
    FROM {{ ref('int_lp_events') }}

    UNION ALL

    SELECT
        pool,
        date
    FROM {{ ref('int_daily_close') }}
),

pool_bounds AS (
    SELECT
        pool,
        max(date) AS max_date
    FROM activity_dates
    GROUP BY pool
),

range_deltas_daily AS (
    SELECT
        pool,
        toDate(block_time) AS date,
        tick_lower,
        tick_upper,
        sum(liquidity_delta) AS liquidity_delta
    FROM {{ ref('int_lp_events') }}
    GROUP BY pool, toDate(block_time), tick_lower, tick_upper
),

range_bounds AS (
    SELECT
        rd.pool,
        rd.tick_lower,
        rd.tick_upper,
        min(rd.date)       AS start_date,
        any(pb.max_date)   AS max_date
    FROM range_deltas_daily rd
    INNER JOIN pool_bounds pb ON rd.pool = pb.pool
    GROUP BY rd.pool, rd.tick_lower, rd.tick_upper
),

-- Expands each range into one row per day from its first event to the pool's last active day.
-- ARRAY JOIN range(N) generates offsets [0, 1, ..., N-1] and explodes into N rows.
range_date_spine AS (
    SELECT
        pool,
        tick_lower,
        tick_upper,
        addDays(start_date, toInt32(offset)) AS date
    FROM range_bounds
    ARRAY JOIN range(toUInt32(dateDiff('day', start_date, max_date) + 1)) AS offset
),

-- Days with no LP event get liquidity_delta = 0 via LEFT JOIN.
daily_changes AS (
    SELECT
        spine.pool,
        spine.date,
        spine.tick_lower,
        spine.tick_upper,
        coalesce(deltas.liquidity_delta, 0) AS liquidity_delta
    FROM range_date_spine spine
    LEFT JOIN range_deltas_daily deltas
        ON  spine.pool       = deltas.pool
        AND spine.date       = deltas.date
        AND spine.tick_lower = deltas.tick_lower
        AND spine.tick_upper = deltas.tick_upper
),

range_state AS (
    SELECT
        pool,
        date,
        tick_lower,
        tick_upper,
        -- Cumulative sum of liquidity deltas reconstructs net liquidity at each date.
        -- TEMPORARY GUARD: greatest(..., 0) clamps negative values caused by the
        -- int24 sign overflow bug in DefInd. Remove once fix is deployed and the
        -- no-negative-cumsum dbt test is green in prod.
        greatest(
            sum(toInt128(liquidity_delta)) OVER (
                PARTITION BY pool, tick_lower, tick_upper
                ORDER BY date
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ),
            toInt128(0)
        ) AS net_liquidity
    FROM daily_changes
)

SELECT
    pool,
    date,
    tick_lower,
    tick_upper,
    net_liquidity
FROM range_state
WHERE net_liquidity > 0  -- excludes closed ranges (fully burned positions)