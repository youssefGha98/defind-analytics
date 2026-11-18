-- Dense daily close helper per pool.
--
-- Fills quiet calendar days between the first and last observed swap date for each
-- pool so downstream rolling windows operate on contiguous daily rows.
-- close_price and close_tick are carried forward independently; close_sqrt_price
-- is always recomputed from close_price in the final SELECT so both stay consistent.
--
-- GRAIN         : 1 row per (pool, date) — contiguous, no gaps
-- DEPENDS ON    : int_daily_close, stg_pools
-- KEY DECISIONS :
--   - ARRAY JOIN range(N) builds a per-pool date spine from first to last observed swap.
--   - last_value(...) IGNORE NULLS carries forward close_tick and close_price on quiet days.
--     Note: IGNORE NULLS syntax may be unstable on some ClickHouse versions — verify on run.
--   - stg_pools joined to provide token decimals for the generic sqrt_price_from_price macro.
--   - close_sqrt_price is recomputed from close_price in the final SELECT (not carried forward)
--     to ensure consistency when close_price is filled from a previous day.

WITH pool_bounds AS (
    SELECT
        pool,
        min(date) AS min_date,
        max(date) AS max_date
    FROM {{ ref('int_daily_close') }}
    GROUP BY pool
),

date_spine AS (
    SELECT
        pool,
        addDays(min_date, toInt32(offset)) AS date
    FROM pool_bounds
    ARRAY JOIN range(toUInt32(dateDiff('day', min_date, max_date) + 1)) AS offset
),

observed_close AS (
    SELECT
        pool,
        date,
        toNullable(close_tick)  AS close_tick,
        toNullable(close_price) AS close_price
    FROM {{ ref('int_daily_close') }}
),

dense_with_nulls AS (
    SELECT
        ds.pool,
        ds.date,
        if(oc.close_price IS NOT NULL, toUInt8(1), toUInt8(0)) AS has_swap,
        oc.close_tick,
        oc.close_price
    FROM date_spine ds
    LEFT JOIN observed_close oc
        ON  ds.pool = oc.pool
        AND ds.date = oc.date
),

carried_close AS (
    SELECT
        pool,
        date,
        has_swap,
        last_value(close_tick) IGNORE NULLS OVER (
            PARTITION BY pool
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                AS close_tick,
        last_value(close_price) IGNORE NULLS OVER (
            PARTITION BY pool
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                AS close_price
    FROM dense_with_nulls
),

-- Join pool metadata to get token decimals for generic sqrt_price_from_price.
with_meta AS (
    SELECT
        c.pool,
        c.date,
        c.has_swap,
        c.close_tick,
        c.close_price,
        p.token0_decimals,
        p.token1_decimals
    FROM carried_close c
    INNER JOIN {{ ref('stg_pools') }} p ON c.pool = p.pool
)

SELECT
    pool,
    date,
    toInt32(close_tick)                                                              AS close_tick,
    toFloat64(close_price)                                                           AS close_price,
    {{ sqrt_price_from_price('close_price', 'token0_decimals', 'token1_decimals') }} AS close_sqrt_price,
    has_swap
FROM with_meta