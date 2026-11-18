-- Every pool/day with at least one swap must have a daily close row.
-- This catches stale or incomplete int_daily_close rebuilds immediately.

WITH swap_days AS (
    SELECT
        pool,
        toDate(block_time) AS date
    FROM {{ ref('stg_swaps') }}
    GROUP BY pool, toDate(block_time)
),

close_days AS (
    SELECT
        pool,
        date
    FROM {{ ref('int_daily_close') }}
    GROUP BY pool, date
)

SELECT
    s.pool,
    s.date
FROM swap_days s
LEFT JOIN close_days c
    ON  s.pool = c.pool
    AND s.date = c.date
WHERE c.date IS NULL
