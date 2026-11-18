{{ config(materialized='table', order_by=['token_id', 'start_block_number', 'start_log_index']) }}

-- Constant-liquidity spans per NFPM tokenId.
--
-- GRAIN         : 1 row per token_id liquidity span with strictly positive deployed liquidity
-- DEPENDS ON    : int_nfpm_position_liquidity_events
-- KEY DECISIONS :
--   - Each span starts immediately after a liquidity event and ends at the next
--     liquidity event for the same tokenId.
--   - Only spans with positive cumulative liquidity are kept because these are the
--     only intervals where the position can earn fees or be considered deployed.
--   - start_event_seq / end_event_seq are global log-order surrogates used later for
--     exact swap-path joins without relying only on timestamps.

WITH event_states AS (
    SELECT
        token_id,
        pool,
        tick_lower,
        tick_upper,
        block_number,
        block_time,
        log_index,
        sum(liquidity_delta_raw) OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                     AS liquidity_raw_after_event,
        leadInFrame(toNullable(block_number), 1, CAST(NULL AS Nullable(UInt64))) OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                                                     AS next_block_number,
        leadInFrame(toNullable(block_time), 1, CAST(NULL AS Nullable(DateTime))) OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                                                     AS next_block_time,
        leadInFrame(toNullable(log_index), 1, CAST(NULL AS Nullable(UInt64))) OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                                                     AS next_log_index
    FROM {{ ref('int_nfpm_position_liquidity_events') }}
)

SELECT
    token_id,
    pool,
    tick_lower,
    tick_upper,
    block_number                                                             AS start_block_number,
    block_time                                                               AS start_block_time,
    log_index                                                                AS start_log_index,
    next_block_number                                                        AS end_block_number,
    next_block_time                                                          AS end_block_time,
    next_log_index                                                           AS end_log_index,
    toUInt64(block_number) * 100000000 + toUInt64(log_index)                 AS start_event_seq,
    if(
        next_block_number IS NULL OR next_log_index IS NULL,
        NULL,
        toNullable(toUInt64(next_block_number) * 100000000 + toUInt64(next_log_index))
    )                                                                        AS end_event_seq,
    liquidity_raw_after_event                                                AS position_liquidity_raw
FROM event_states
WHERE liquidity_raw_after_event > 0
