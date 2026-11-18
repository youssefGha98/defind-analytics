WITH expected AS (
    SELECT
        pool,
        block_number,
        log_index,
        lagInFrame(toNullable(tick), 1, CAST(NULL AS Nullable(Int32))) OVER (
            PARTITION BY pool
            ORDER BY block_number, log_index
        ) AS expected_tick_before,
        lagInFrame(toNullable(toFloat64(price_token1_in_token0)), 1, CAST(NULL AS Nullable(Float64))) OVER (
            PARTITION BY pool
            ORDER BY block_number, log_index
        ) AS expected_price_before,
        lead(toNullable(block_time), 1, CAST(NULL AS Nullable(DateTime))) OVER (
            PARTITION BY pool
            ORDER BY block_number, log_index
        ) AS expected_next_block_time
    FROM {{ ref('stg_swaps') }}
)

SELECT
    e.pool,
    e.block_number,
    e.log_index,
    e.tick_before,
    x.expected_tick_before,
    e.price_before,
    x.expected_price_before,
    e.next_block_time,
    x.expected_next_block_time
FROM {{ ref('int_swaps_enriched') }} e
INNER JOIN expected x
    ON  e.pool = x.pool
    AND e.block_number = x.block_number
    AND e.log_index = x.log_index
WHERE NOT (
        (e.tick_before IS NULL AND x.expected_tick_before IS NULL)
        OR e.tick_before = x.expected_tick_before
      )
   OR NOT (
        (e.price_before IS NULL AND x.expected_price_before IS NULL)
        OR (
            e.price_before IS NOT NULL
            AND x.expected_price_before IS NOT NULL
            AND abs(e.price_before - x.expected_price_before) <= 1e-12
        )
      )
   OR NOT (
        (e.next_block_time IS NULL AND x.expected_next_block_time IS NULL)
        OR e.next_block_time = x.expected_next_block_time
      )
