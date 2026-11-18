WITH expected AS (
    SELECT
        pool,
        toDate(block_time) AS date,
        round(sum(volume_token0), 6) AS expected_volume_token0,
        round(sum(volume_token1), 12) AS expected_volume_token1,
        round(sum(volume_token0_equiv), 6) AS expected_volume_token0_equiv,
        count() AS expected_swap_count,
        round(sum(fees_generated_token0), 6) AS expected_fees_token0,
        round(sum(fees_generated_token1), 12) AS expected_fees_token1,
        round(sum(fees_generated_token0_equiv), 6) AS expected_fees_token0_equiv
    FROM {{ ref('int_swaps_enriched') }}
    GROUP BY pool, toDate(block_time)
)

SELECT
    coalesce(a.pool, e.pool) AS pool,
    coalesce(a.date, e.date) AS date,
    a.volume_token0,
    e.expected_volume_token0,
    a.volume_token1,
    e.expected_volume_token1,
    a.volume_token0_equiv,
    e.expected_volume_token0_equiv,
    a.swap_count,
    e.expected_swap_count,
    a.fees_token0,
    e.expected_fees_token0,
    a.fees_token1,
    e.expected_fees_token1,
    a.fees_token0_equiv,
    e.expected_fees_token0_equiv
FROM {{ ref('mart_volume_daily') }} a
FULL OUTER JOIN expected e
    ON  a.pool = e.pool
    AND a.date = e.date
-- Relative tolerance: float sums over ~10k swaps differ by ~1e-14 relative depending on
-- ClickHouse's parallel aggregation order, which exceeds a fixed 1e-5 on $1B+ volume days.
WHERE a.pool IS NULL
   OR e.pool IS NULL
   OR abs(a.volume_token0 - e.expected_volume_token0) > greatest(1e-5, 1e-12 * abs(e.expected_volume_token0))
   OR abs(a.volume_token1 - e.expected_volume_token1) > greatest(1e-8, 1e-12 * abs(e.expected_volume_token1))
   OR abs(a.volume_token0_equiv - e.expected_volume_token0_equiv) > greatest(1e-5, 1e-12 * abs(e.expected_volume_token0_equiv))
   OR a.swap_count != e.expected_swap_count
   OR abs(a.fees_token0 - e.expected_fees_token0) > greatest(1e-5, 1e-12 * abs(e.expected_fees_token0))
   OR abs(a.fees_token1 - e.expected_fees_token1) > greatest(1e-8, 1e-12 * abs(e.expected_fees_token1))
   OR abs(a.fees_token0_equiv - e.expected_fees_token0_equiv) > greatest(1e-5, 1e-12 * abs(e.expected_fees_token0_equiv))
