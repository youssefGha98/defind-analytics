{{ config(
    order_by=['pool', 'block_number', 'log_index', 'tick_boundary'],
    partition_by="toYYYYMM(coalesce(block_time, toDateTime('1970-01-01 00:00:00')))"
) }}

-- Event-level liquidityNet deltas at LP tick boundaries.
--
-- This is the canonical bridge from range-level LP events to distribution-style
-- liquidity reconstruction:
--   +liquidity_delta at tick_lower
--   -liquidity_delta at tick_upper
-- A cumsum over tick_boundary then reconstructs available liquidity by bin.
--
-- GRAIN         : 2 rows per LP event (one lower boundary, one upper boundary)
-- DEPENDS ON    : int_lp_events
-- KEY DECISIONS :
--   - int_lp_events remains the LP source of truth; this model is a derived,
--     distribution-oriented representation only.
--   - Burns stay naturally correct because int_lp_events already stores signed
--     liquidity_delta, so lower keeps liquidity_delta and upper keeps its negation.
--   - boundary_side is preserved for auditability, but downstream models should
--     rely on tick_boundary + liquidity_net_delta semantics.

WITH boundary_deltas AS (
    SELECT
        pool,
        block_number,
        block_time,
        tx_hash,
        log_index,
        toInt32(tick_lower)                                                AS tick_boundary,
        toInt128(liquidity_delta)                                          AS liquidity_net_delta,
        'lower'                                                            AS boundary_side
    FROM {{ ref('int_lp_events') }}

    UNION ALL

    SELECT
        pool,
        block_number,
        block_time,
        tx_hash,
        log_index,
        toInt32(tick_upper)                                                AS tick_boundary,
        -toInt128(liquidity_delta)                                         AS liquidity_net_delta,
        'upper'                                                            AS boundary_side
    FROM {{ ref('int_lp_events') }}
)

SELECT
    assumeNotNull(pool)                                                    AS pool,
    toUInt64(assumeNotNull(block_number))                                  AS block_number,
    toDateTime(assumeNotNull(block_time))                                  AS block_time,
    assumeNotNull(tx_hash)                                                 AS tx_hash,
    toUInt64(assumeNotNull(log_index))                                     AS log_index,
    toInt32(assumeNotNull(tick_boundary))                                  AS tick_boundary,
    toInt128(assumeNotNull(liquidity_net_delta))                           AS liquidity_net_delta,
    assumeNotNull(boundary_side)                                           AS boundary_side
FROM boundary_deltas
