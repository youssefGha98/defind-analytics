{% set nfpm_metrics_start_date = var('nfpm_metrics_start_date', none) %}
{% set nfpm_metrics_end_date = var('nfpm_metrics_end_date', none) %}
{% set nfpm_metrics_incremental_lookback_days = var('nfpm_metrics_incremental_lookback_days', 3) %}

{{ config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key=['token_id', 'date'],
    order_by=['token_id', 'date'],
    partition_by='toYYYYMM(date)'
) }}

-- Chunkable generated-fee accrual facts per NFPM tokenId and day.
--
-- GRAIN         : 1 row per (token_id, date)
-- DEPENDS ON    : int_nfpm_position_liquidity_spans, int_swaps_enriched
-- KEY DECISIONS :
--   - Fees are attributed swap by swap using the position's liquidity weight versus
--     active pool liquidity at the moment of the swap.
--   - The earning predicate uses tick_before, because fees are earned by positions
--     active immediately before execution.
--   - Daily rows are the backfillable truth; the token-level summary is a light
--     aggregation on top of this model.

WITH incremental_cutoff AS (
    {% if is_incremental() %}
    SELECT addDays(
        coalesce(max(date), toDate('1970-01-01')),
        -toInt32({{ nfpm_metrics_incremental_lookback_days }})
    ) AS date_cutoff
    FROM {{ this }}
    {% else %}
    SELECT toDate('1970-01-01') AS date_cutoff
    {% endif %}
),

bounds AS (
    SELECT
        {% if nfpm_metrics_start_date is not none %}
        toDateTime('{{ nfpm_metrics_start_date }} 00:00:00')                    AS chunk_start_time,
        {% elif is_incremental() %}
        toDateTime((SELECT date_cutoff FROM incremental_cutoff))                AS chunk_start_time,
        {% else %}
        toDateTime('1970-01-01 00:00:00')                                       AS chunk_start_time,
        {% endif %}
        {% if nfpm_metrics_end_date is not none %}
        addDays(toDateTime('{{ nfpm_metrics_end_date }} 00:00:00'), 1)          AS chunk_end_time
        {% else %}
        CAST(NULL AS Nullable(DateTime))                                        AS chunk_end_time
        {% endif %}
),

swaps AS (
    SELECT
        sw.pool                                                                 AS pool,
        sw.block_number                                                         AS block_number,
        sw.log_index                                                            AS log_index,
        sw.block_time                                                           AS block_time,
        toDate(sw.block_time)                                                   AS date,
        sw.tick_before                                                          AS tick_before,
        sw.active_liquidity_at_swap                                             AS active_liquidity_at_swap,
        sw.fees_generated_token0                                                AS fees_generated_token0,
        sw.fees_generated_token1                                                AS fees_generated_token1,
        sw.fees_generated_token0_equiv                                          AS fees_generated_token0_equiv,
        toUInt64(sw.block_number) * 100000000 + toUInt64(sw.log_index)          AS swap_event_seq
    FROM {{ ref('int_swaps_enriched') }} sw
    CROSS JOIN bounds b
    WHERE sw.block_time >= b.chunk_start_time
      AND (b.chunk_end_time IS NULL OR sw.block_time < b.chunk_end_time)
),

spans AS (
    SELECT
        sp.*
    FROM {{ ref('int_nfpm_position_liquidity_spans') }} sp
    CROSS JOIN bounds b
    WHERE sp.start_block_time < coalesce(b.chunk_end_time, toDateTime('2100-01-01 00:00:00'))
      AND (sp.end_block_time IS NULL OR sp.end_block_time > b.chunk_start_time)
),

matched AS (
    SELECT
        sp.token_id                                                             AS token_id,
        sp.pool                                                                 AS pool,
        sw.date                                                                 AS date,
        sp.tick_lower                                                           AS tick_lower,
        sp.tick_upper                                                           AS tick_upper,
        sp.position_liquidity_raw                                               AS position_liquidity_raw,
        sw.tick_before                                                          AS tick_before,
        sw.active_liquidity_at_swap                                             AS active_liquidity_at_swap,
        sw.fees_generated_token0                                                AS fees_generated_token0,
        sw.fees_generated_token1                                                AS fees_generated_token1,
        sw.fees_generated_token0_equiv                                          AS fees_generated_token0_equiv
    FROM spans sp
    INNER JOIN swaps sw
        ON  sp.pool = sw.pool
        AND sw.block_number >= sp.start_block_number
        AND (sp.end_block_number IS NULL OR sw.block_number <= sp.end_block_number)
        AND sw.swap_event_seq > sp.start_event_seq
        AND (sp.end_event_seq IS NULL OR sw.swap_event_seq < sp.end_event_seq)
        AND sw.tick_before IS NOT NULL
        AND sp.tick_lower <= sw.tick_before
        AND sw.tick_before < sp.tick_upper
),

accruals AS (
    SELECT
        token_id,
        pool,
        date,
        if(
            tick_before IS NOT NULL
            AND {{ is_range_active('tick_before', 'tick_lower', 'tick_upper') }}
            AND active_liquidity_at_swap > 0,
            toFloat64(position_liquidity_raw) / active_liquidity_at_swap,
            NULL
        )                                                                       AS fee_share,
        if(
            tick_before IS NOT NULL
            AND {{ is_range_active('tick_before', 'tick_lower', 'tick_upper') }}
            AND active_liquidity_at_swap > 0,
            fees_generated_token0 * toFloat64(position_liquidity_raw) / active_liquidity_at_swap,
            0.0
        )                                                                       AS fees_accrued_amount0,
        if(
            tick_before IS NOT NULL
            AND {{ is_range_active('tick_before', 'tick_lower', 'tick_upper') }}
            AND active_liquidity_at_swap > 0,
            fees_generated_token1 * toFloat64(position_liquidity_raw) / active_liquidity_at_swap,
            0.0
        )                                                                       AS fees_accrued_amount1,
        if(
            tick_before IS NOT NULL
            AND {{ is_range_active('tick_before', 'tick_lower', 'tick_upper') }}
            AND active_liquidity_at_swap > 0,
            fees_generated_token0_equiv * toFloat64(position_liquidity_raw) / active_liquidity_at_swap,
            0.0
        )                                                                       AS fees_accrued_token0_equiv_generated
    FROM matched
)

SELECT
    assumeNotNull(token_id)                                                       AS token_id,
    any(pool)                                                                   AS pool,
    toDate(assumeNotNull(date))                                                 AS date,
    countIf(fee_share IS NOT NULL)                                              AS active_swap_count,
    sum(fees_accrued_amount0)                                                   AS total_fees_accrued_amount0,
    sum(fees_accrued_amount1)                                                   AS total_fees_accrued_amount1,
    sum(fees_accrued_token0_equiv_generated)                                    AS total_fees_accrued_token0_equiv_generated
FROM accruals
GROUP BY token_id, date
