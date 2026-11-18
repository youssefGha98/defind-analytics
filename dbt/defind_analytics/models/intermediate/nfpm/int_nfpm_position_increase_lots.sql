-- ASOF JOIN is unsupported by the profile-wide join_algorithm=partial_merge on ClickHouse 26.
{{ config(materialized='table', order_by=['token_id', 'lot_seq'], query_settings={'join_algorithm': 'hash'}) }}

-- Canonical increase-lot facts per NFPM tokenId.
--
-- GRAIN         : 1 row per IncreaseLiquidity event, treated as a distinct capital lot
-- DEPENDS ON    : int_nfpm_position_liquidity_events, stg_swaps
-- KEY DECISIONS :
--   - Every IncreaseLiquidity is treated as a new economic capital contribution,
--     including the initial mint-time increase (lot_seq = 1).
--   - Entry state is looked up at the pool state immediately before the increase
--     event, using ASOF JOIN on the pool-side swap stream.
--   - This model intentionally does not allocate decreases across lots yet; it is
--     the canonical benchmark/cost-basis input for aggregate tokenId PnL.

WITH increases AS (
    SELECT
        token_id,
        pool,
        tick_lower,
        tick_upper,
        tx_hash,
        block_number                                                         AS lot_block_number,
        block_time                                                           AS lot_block_time,
        log_index                                                            AS lot_log_index,
        liquidity_delta_raw                                                  AS lot_liquidity_added_raw,
        amount0_raw                                                          AS lot_amount0_raw,
        amount1_raw                                                          AS lot_amount1_raw,
        amount0                                                              AS lot_amount0,
        amount1                                                              AS lot_amount1,
        token0_symbol,
        token1_symbol,
        row_number() OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index
        )                                                                    AS lot_seq,
        toUInt64(block_number) * 100000000 + toUInt64(log_index)             AS lot_event_seq
    FROM {{ ref('int_nfpm_position_liquidity_events') }}
    WHERE event_type = 'IncreaseLiquidity'
    ORDER BY pool, lot_event_seq
),

swaps AS (
    SELECT
        lower(pool)                                                          AS pool,
        block_number                                                         AS entry_snapshot_block_number_raw,
        log_index                                                            AS entry_snapshot_log_index_raw,
        block_time                                                           AS entry_snapshot_block_time_raw,
        tick                                                                 AS entry_tick_raw,
        price_token1_in_token0                                               AS entry_price_token1_in_token0_raw,
        toUInt64(block_number) * 100000000 + toUInt64(log_index)             AS swap_event_seq
    FROM {{ ref('stg_swaps') }}
    ORDER BY lower(pool), swap_event_seq
),

lot_entry_raw AS (
    SELECT
        i.token_id,
        i.pool,
        i.tick_lower,
        i.tick_upper,
        i.tx_hash,
        i.lot_seq,
        i.lot_block_number,
        i.lot_block_time,
        i.lot_log_index,
        i.lot_liquidity_added_raw,
        i.lot_amount0_raw,
        i.lot_amount1_raw,
        i.lot_amount0,
        i.lot_amount1,
        i.token0_symbol,
        i.token1_symbol,
        s.entry_snapshot_block_number_raw,
        s.entry_snapshot_log_index_raw,
        s.entry_snapshot_block_time_raw,
        s.entry_tick_raw,
        s.entry_price_token1_in_token0_raw
    FROM increases i
    ASOF LEFT JOIN swaps s
        ON i.pool = s.pool
       AND i.lot_event_seq >= s.swap_event_seq
)

SELECT
    token_id,
    pool,
    lot_seq,
    lot_seq = 1                                                              AS is_mint_lot,
    tick_lower,
    tick_upper,
    tx_hash,
    lot_block_number,
    lot_block_time,
    lot_log_index,
    lot_liquidity_added_raw,
    lot_amount0_raw,
    lot_amount1_raw,
    lot_amount0,
    lot_amount1,
    token0_symbol,
    token1_symbol,
    isNull(entry_snapshot_block_number_raw)
        OR entry_snapshot_block_number_raw = 0                               AS entry_state_missing,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_snapshot_block_number_raw)
    )                                                                        AS entry_snapshot_block_number,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_snapshot_log_index_raw)
    )                                                                        AS entry_snapshot_log_index,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_snapshot_block_time_raw)
    )                                                                        AS entry_snapshot_block_time,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_tick_raw)
    )                                                                        AS entry_tick,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_price_token1_in_token0_raw)
    )                                                                        AS entry_price_token1_in_token0,
    if(
        isNull(entry_snapshot_block_number_raw)
        OR entry_snapshot_block_number_raw = 0
        OR isNull(entry_price_token1_in_token0_raw)
        OR entry_price_token1_in_token0_raw <= 0,
        NULL,
        toFloat64(lot_amount0) + toFloat64(lot_amount1) * toFloat64(entry_price_token1_in_token0_raw)
    )                                                                        AS contribution_value_token0_at_entry
FROM lot_entry_raw
