WITH per_event AS (
    SELECT
        pool,
        block_number,
        log_index,
        tx_hash,
        count(*) AS boundary_row_count,
        sum(liquidity_net_delta) AS net_liquidity_delta_sum
    FROM {{ ref('int_tick_boundary_deltas') }}
    GROUP BY pool, block_number, log_index, tx_hash
)

SELECT
    pool,
    block_number,
    log_index,
    tx_hash,
    boundary_row_count,
    net_liquidity_delta_sum
FROM per_event
WHERE boundary_row_count != 2
   OR net_liquidity_delta_sum != 0
