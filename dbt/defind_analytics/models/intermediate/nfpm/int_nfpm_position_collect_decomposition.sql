{{ config(materialized='table', order_by=['token_id', 'block_number', 'log_index']) }}

WITH decrease_events AS (
    SELECT
        token_id,
        pool,
        tx_hash,
        block_number,
        block_time,
        log_index,
        1                                                                     AS event_rank,
        'DecreaseLiquidity'                                                   AS source_event,
        -liquidity_delta_raw                                                  AS liquidity_removed_raw,
        -amount0_raw                                                          AS principal_generated_amount0_raw,
        -amount1_raw                                                          AS principal_generated_amount1_raw,
        toDecimal256(0, 0)                                                    AS collect_amount0_raw,
        toDecimal256(0, 0)                                                    AS collect_amount1_raw
    FROM {{ ref('int_nfpm_position_liquidity_events') }}
    WHERE event_type = 'DecreaseLiquidity'
),

collect_events AS (
    SELECT
        token_id,
        pool,
        tx_hash,
        block_number,
        block_time,
        log_index,
        2                                                                     AS event_rank,
        'Collect'                                                             AS source_event,
        toDecimal128(0, 0)                                                    AS liquidity_removed_raw,
        toDecimal256(0, 0)                                                    AS principal_generated_amount0_raw,
        toDecimal256(0, 0)                                                    AS principal_generated_amount1_raw,
        amount0_raw                                                           AS collect_amount0_raw,
        amount1_raw                                                           AS collect_amount1_raw
    FROM {{ ref('int_nfpm_position_collect_events') }}
),

event_stream AS (
    SELECT * FROM decrease_events
    UNION ALL
    SELECT * FROM collect_events
),

running AS (
    SELECT
        *,
        sum(principal_generated_amount0_raw) OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index, event_rank
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                     AS cumulative_principal_generated_amount0_raw,
        sum(principal_generated_amount1_raw) OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index, event_rank
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                     AS cumulative_principal_generated_amount1_raw,
        sum(collect_amount0_raw) OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index, event_rank
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                     AS cumulative_collect_amount0_raw,
        sum(collect_amount1_raw) OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index, event_rank
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                     AS cumulative_collect_amount1_raw
    FROM event_stream
),

allocated AS (
    SELECT
        *,
        least(cumulative_principal_generated_amount0_raw, cumulative_collect_amount0_raw) AS cumulative_principal_collected_amount0_raw,
        least(cumulative_principal_generated_amount1_raw, cumulative_collect_amount1_raw) AS cumulative_principal_collected_amount1_raw
    FROM running
),

collect_rows AS (
    SELECT
        *,
        -- Default scale 0 matches: raw amounts are Decimal256(0) from staging,
        -- sum() and least() preserve the scale through running / allocated CTEs.
        cumulative_principal_collected_amount0_raw
            - lagInFrame(cumulative_principal_collected_amount0_raw, 1, toDecimal256(0, 0)) OVER (
                PARTITION BY token_id
                ORDER BY block_number, log_index, event_rank
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )                                                                 AS principal_collected_amount0_raw,
        cumulative_principal_collected_amount1_raw
            - lagInFrame(cumulative_principal_collected_amount1_raw, 1, toDecimal256(0, 0)) OVER (
                PARTITION BY token_id
                ORDER BY block_number, log_index, event_rank
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )                                                                 AS principal_collected_amount1_raw
    FROM allocated
    WHERE source_event = 'Collect'
)

SELECT
    c.token_id,
    c.pool,
    c.tx_hash,
    c.block_number,
    c.block_time,
    c.log_index,
    c.collect_amount0_raw,
    c.collect_amount1_raw,
    c.principal_collected_amount0_raw,
    c.principal_collected_amount1_raw,
    c.collect_amount0_raw - c.principal_collected_amount0_raw                AS fees_collected_amount0_raw,
    c.collect_amount1_raw - c.principal_collected_amount1_raw                AS fees_collected_amount1_raw,
    p.token0_symbol,
    p.token1_symbol,
    {{ scale_raw_token_amount('c.collect_amount0_raw', 'p.token0_decimals') }} AS collect_amount0,
    {{ scale_raw_token_amount('c.collect_amount1_raw', 'p.token1_decimals') }} AS collect_amount1,
    {{ scale_raw_token_amount('c.principal_collected_amount0_raw', 'p.token0_decimals') }} AS principal_collected_amount0,
    {{ scale_raw_token_amount('c.principal_collected_amount1_raw', 'p.token1_decimals') }} AS principal_collected_amount1,
    {{ scale_raw_token_amount('c.collect_amount0_raw - c.principal_collected_amount0_raw', 'p.token0_decimals') }} AS fees_collected_amount0,
    {{ scale_raw_token_amount('c.collect_amount1_raw - c.principal_collected_amount1_raw', 'p.token1_decimals') }} AS fees_collected_amount1
FROM collect_rows c
INNER JOIN {{ ref('stg_pools') }} p ON c.pool = lower(p.pool)
