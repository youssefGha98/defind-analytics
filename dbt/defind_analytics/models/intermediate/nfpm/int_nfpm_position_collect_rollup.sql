{{ config(materialized='table', order_by=['token_id']) }}

-- Consolidated collect rollup per mapped NFPM tokenId.
--
-- GRAIN         : 1 row per token_id
-- DEPENDS ON    : int_nfpm_position_collect_events, int_nfpm_position_collect_decomposition
-- KEY DECISIONS :
--   - Raw and human-readable collect totals come from the collect event stream.
--   - Principal/fee splits come from the decomposition model but are surfaced here
--     so current/lifecycle marts can depend on one collect rollup only.

WITH collect_base AS (
    SELECT
        token_id,
        count()                                                                     AS collect_count,
        min(block_number)                                                           AS first_collect_block_number,
        min(block_time)                                                             AS first_collect_block_time,
        sum(amount0_raw)                                                            AS total_collected_amount0_raw,
        sum(amount1_raw)                                                            AS total_collected_amount1_raw,
        sum(amount0)                                                                AS total_collected_amount0,
        sum(amount1)                                                                AS total_collected_amount1,
        argMax(recipient, tuple(block_number, log_index))                           AS last_collect_recipient,
        argMax(block_number, tuple(block_number, log_index))                        AS last_collect_block_number,
        argMax(block_time, tuple(block_number, log_index))                          AS last_collect_block_time,
        argMax(log_index, tuple(block_number, log_index))                           AS last_collect_log_index
    FROM {{ ref('int_nfpm_position_collect_events') }}
    GROUP BY token_id
),

decomposition_base AS (
    SELECT
        token_id,
        count()                                                                     AS collect_event_count,
        sum(principal_collected_amount0_raw)                                        AS total_principal_collected_amount0_raw,
        sum(principal_collected_amount1_raw)                                        AS total_principal_collected_amount1_raw,
        sum(fees_collected_amount0_raw)                                             AS total_fees_collected_amount0_raw,
        sum(fees_collected_amount1_raw)                                             AS total_fees_collected_amount1_raw,
        sum(principal_collected_amount0)                                            AS total_principal_collected_amount0,
        sum(principal_collected_amount1)                                            AS total_principal_collected_amount1,
        sum(fees_collected_amount0)                                                 AS total_fees_collected_amount0,
        sum(fees_collected_amount1)                                                 AS total_fees_collected_amount1
    FROM {{ ref('int_nfpm_position_collect_decomposition') }}
    GROUP BY token_id
)

SELECT
    cb.token_id,
    cb.collect_count,
    cb.first_collect_block_number,
    cb.first_collect_block_time,
    cb.total_collected_amount0_raw,
    cb.total_collected_amount1_raw,
    cb.total_collected_amount0,
    cb.total_collected_amount1,
    cb.last_collect_recipient,
    cb.last_collect_block_number,
    cb.last_collect_block_time,
    cb.last_collect_log_index,
    coalesce(db.collect_event_count, 0)                                            AS collect_event_count,
    coalesce(db.total_principal_collected_amount0_raw, toDecimal256(0, 0))         AS total_principal_collected_amount0_raw,
    coalesce(db.total_principal_collected_amount1_raw, toDecimal256(0, 0))         AS total_principal_collected_amount1_raw,
    coalesce(db.total_fees_collected_amount0_raw, toDecimal256(0, 0))              AS total_fees_collected_amount0_raw,
    coalesce(db.total_fees_collected_amount1_raw, toDecimal256(0, 0))              AS total_fees_collected_amount1_raw,
    coalesce(db.total_principal_collected_amount0, toDecimal256(0, 18))            AS total_principal_collected_amount0,
    coalesce(db.total_principal_collected_amount1, toDecimal256(0, 18))            AS total_principal_collected_amount1,
    coalesce(db.total_fees_collected_amount0, toDecimal256(0, 18))                 AS total_fees_collected_amount0,
    coalesce(db.total_fees_collected_amount1, toDecimal256(0, 18))                 AS total_fees_collected_amount1
FROM collect_base cb
LEFT JOIN decomposition_base db ON cb.token_id = db.token_id
