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

-- Chunkable observed time-in-range facts per NFPM tokenId and day.
--
-- GRAIN         : 1 row per (token_id, date)
-- DEPENDS ON    : int_nfpm_position_liquidity_spans, int_swaps_enriched
-- KEY DECISIONS :
--   - This uses the observed swap-state timeline, just like the simulated backtest.
--   - Intervals are split by day boundaries exactly, so token-level rollups remain
--     additive and chunkable by calendar date.
--   - Quiet periods after the last observed swap are not extrapolated.

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
        sw.block_time                                                           AS swap_time,
        sw.next_block_time                                                      AS next_swap_time,
        sw.tick_after                                                           AS tick_after,
        toUInt64(sw.block_number) * 100000000 + toUInt64(sw.log_index)          AS swap_event_seq,
        b.chunk_start_time                                                      AS chunk_start_time,
        b.chunk_end_time                                                        AS chunk_end_time
    FROM {{ ref('int_swaps_enriched') }} sw
    CROSS JOIN bounds b
    WHERE coalesce(sw.next_block_time, sw.block_time) > b.chunk_start_time
      AND (b.chunk_end_time IS NULL OR sw.block_time < b.chunk_end_time)
),

matched AS (
    SELECT
        sp.token_id                                                             AS token_id,
        sp.pool                                                                 AS pool,
        sp.tick_lower                                                           AS tick_lower,
        sp.tick_upper                                                           AS tick_upper,
        sp.start_block_time                                                     AS span_start_time,
        sp.end_block_time                                                       AS span_end_time,
        sw.swap_time                                                            AS swap_time,
        sw.next_swap_time                                                       AS next_swap_time,
        sw.tick_after                                                           AS tick_after,
        sw.chunk_start_time                                                     AS chunk_start_time,
        sw.chunk_end_time                                                       AS chunk_end_time
    FROM {{ ref('int_nfpm_position_liquidity_spans') }} sp
    CROSS JOIN bounds b
    INNER JOIN swaps sw
        ON  sp.pool = sw.pool
        AND sw.block_number >= sp.start_block_number
        AND (sp.end_block_number IS NULL OR sw.block_number <= sp.end_block_number)
        AND sw.swap_event_seq > sp.start_event_seq
        AND (sp.end_event_seq IS NULL OR sw.swap_event_seq < sp.end_event_seq)
        AND (sp.end_block_time IS NULL OR sw.swap_time < sp.end_block_time)
        AND coalesce(sw.next_swap_time, sw.swap_time) > sp.start_block_time
    WHERE sp.start_block_time < coalesce(b.chunk_end_time, toDateTime('2100-01-01 00:00:00'))
      AND (sp.end_block_time IS NULL OR sp.end_block_time > b.chunk_start_time)
),

intervals AS (
    SELECT
        token_id,
        pool,
        greatest(swap_time, span_start_time, chunk_start_time)                  AS effective_start_time,
        least(
            coalesce(next_swap_time, swap_time),
            coalesce(span_end_time, coalesce(next_swap_time, swap_time)),
            coalesce(chunk_end_time, coalesce(next_swap_time, swap_time))
        )                                                                       AS effective_end_time,
        if(
            tick_after IS NOT NULL
            AND {{ is_range_active('tick_after', 'tick_lower', 'tick_upper') }},
            toUInt8(1),
            toUInt8(0)
        )                                                                       AS is_active_after_swap
    FROM matched
),

expanded_days AS (
    SELECT
        token_id,
        pool,
        is_active_after_swap,
        effective_start_time,
        effective_end_time,
        addDays(toDate(effective_start_time), toInt32(offset))                  AS date
    FROM intervals
    ARRAY JOIN range(
        toUInt32(
            greatest(
                dateDiff(
                    'day',
                    toDate(effective_start_time),
                    toDate(subtractSeconds(effective_end_time, 1))
                ) + 1,
                1
            )
        )
    ) AS offset
    WHERE effective_end_time > effective_start_time
),

daily_overlaps AS (
    SELECT
        token_id,
        pool,
        date,
        greatest(
            dateDiff(
                'second',
                greatest(effective_start_time, toDateTime(date)),
                least(effective_end_time, addDays(toDateTime(date), 1))
            ),
            0
        )                                                                       AS overlap_seconds,
        is_active_after_swap
    FROM expanded_days
)

SELECT
    assumeNotNull(token_id)                                                       AS token_id,
    any(pool)                                                                   AS pool,
    toDate(assumeNotNull(date))                                                 AS date,
    coalesce(sumIf(overlap_seconds, is_active_after_swap = 1), 0)               AS observed_time_in_range_seconds,
    coalesce(sum(overlap_seconds), 0)                                           AS observed_window_seconds,
    coalesce(sum(overlap_seconds), 0)
        - coalesce(sumIf(overlap_seconds, is_active_after_swap = 1), 0)         AS observed_out_of_range_seconds,
    if(
        coalesce(sum(overlap_seconds), 0) > 0,
        coalesce(sumIf(overlap_seconds, is_active_after_swap = 1), 0) / coalesce(sum(overlap_seconds), 0),
        NULL
    )                                                                           AS observed_time_in_range_pct,
    if(
        coalesce(sum(overlap_seconds), 0) > 0,
        (
            coalesce(sum(overlap_seconds), 0)
            - coalesce(sumIf(overlap_seconds, is_active_after_swap = 1), 0)
        ) / coalesce(sum(overlap_seconds), 0),
        NULL
    )                                                                           AS observed_out_of_range_pct
FROM daily_overlaps
GROUP BY token_id, date
