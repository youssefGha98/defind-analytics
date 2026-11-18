{{ config(materialized='table', order_by=['token_id']) }}

SELECT
    token_id,
    count()                                                                 AS liquidity_event_count,
    countIf(event_type = 'IncreaseLiquidity')                               AS increase_count,
    countIf(event_type = 'DecreaseLiquidity')                               AS decrease_count,
    sum(liquidity_delta_raw)                                                AS current_liquidity_raw,
    sumIf(liquidity_delta_raw, liquidity_delta_raw > 0)                     AS total_increase_liquidity_raw,
    -sumIf(liquidity_delta_raw, liquidity_delta_raw < 0)                    AS total_decrease_liquidity_raw,
    sum(amount0_raw)                                                        AS net_amount0_raw,
    sum(amount1_raw)                                                        AS net_amount1_raw,
    sum(amount0)                                                            AS net_amount0,
    sum(amount1)                                                            AS net_amount1,
    sumIf(amount0, amount0 > 0)                                             AS total_deposit_amount0,
    sumIf(amount1, amount1 > 0)                                             AS total_deposit_amount1,
    -sumIf(amount0, amount0 < 0)                                            AS total_withdraw_amount0,
    -sumIf(amount1, amount1 < 0)                                            AS total_withdraw_amount1,
    argMax(block_number, tuple(block_number, log_index))                    AS last_liquidity_event_block_number,
    argMax(block_time, tuple(block_number, log_index))                      AS last_liquidity_event_block_time,
    argMax(log_index, tuple(block_number, log_index))                       AS last_liquidity_event_log_index
FROM {{ ref('int_nfpm_position_liquidity_events') }}
GROUP BY token_id

