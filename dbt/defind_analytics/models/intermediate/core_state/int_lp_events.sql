-- Union of mint and burn events with signed liquidity and amount deltas.
-- Base table for all TVL and position computations.
--
-- GRAIN         : 1 row per LP event (tx_hash, log_index)
-- DEPENDS ON    : stg_mints, stg_burns
-- KEY DECISIONS :
--   - Burns are negated on liquidity_delta, amount0, amount1 so that a cumsum
--     over any block/date range gives the exact pool state at that point in time.
--   - event_type column preserves the original event for auditability downstream.

SELECT
    block_number,
    block_time,
    tx_hash,
    log_index,
    pool,
    owner,
    tick_lower,
    tick_upper,
    liquidity_delta,               -- positive (from mints)
    amount0,
    amount1,
    'mint'  AS event_type
FROM {{ ref('stg_mints') }}

UNION ALL

SELECT
    block_number,
    block_time,
    tx_hash,
    log_index,
    pool,
    owner,
    tick_lower,
    tick_upper,
    -liquidity_delta AS liquidity_delta,  -- negative (from burns)
    -amount0         AS amount0,
    -amount1         AS amount1,
    'burn'           AS event_type
FROM {{ ref('stg_burns') }}