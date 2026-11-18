-- ASOF JOIN is unsupported by the profile-wide join_algorithm=partial_merge on ClickHouse 26.
{{ config(materialized='table', order_by=['token_id'], query_settings={'join_algorithm': 'hash'}) }}

-- Entry state snapshot for each mapped NFPM tokenId.
--
-- GRAIN         : 1 row per token_id
-- DEPENDS ON    : int_nfpm_positions, stg_swaps
-- KEY DECISIONS :
--   - Entry state is the latest observed swap state at or before the pool Mint log
--     that created the position. pool_mint_log_index is used instead of the NFPM
--     transfer/increase log because it is the actual pool-side liquidity placement.
--   - ASOF JOIN keeps the lookup efficient across many tokenIds without expanding
--     into a large inequality join.
--   - One early position predates the first observed swap on the pool; that case is
--     preserved as entry_state_missing = 1 instead of fabricating an entry price.

WITH positions AS (
    SELECT
        p.token_id                                                            AS token_id,
        p.pool                                                                AS pool,
        p.mint_block_number                                                   AS mint_block_number,
        p.mint_block_time                                                     AS mint_block_time,
        p.pool_mint_log_index                                                 AS pool_mint_log_index,
        p.token0_decimals                                                     AS token0_decimals,
        p.token1_decimals                                                     AS token1_decimals,
        toUInt64(p.mint_block_number) * 100000000 + toUInt64(p.pool_mint_log_index) AS mint_event_seq
    FROM {{ ref('int_nfpm_positions') }} p
    ORDER BY p.pool, mint_event_seq
),

swaps AS (
    SELECT
        s.pool                                                                AS pool,
        s.block_number                                                        AS entry_snapshot_block_number_raw,
        s.log_index                                                           AS entry_snapshot_log_index_raw,
        s.block_time                                                          AS entry_snapshot_block_time_raw,
        s.tick                                                                AS entry_tick_raw,
        s.price_token1_in_token0                                              AS entry_price_token1_in_token0_raw,
        toUInt64(s.block_number) * 100000000 + toUInt64(s.log_index)          AS swap_event_seq
    FROM {{ ref('stg_swaps') }} s
    ORDER BY s.pool, swap_event_seq
),

entry_state_raw AS (
    SELECT
        p.token_id                                                            AS token_id,
        p.pool                                                                AS pool,
        p.mint_block_number                                                   AS mint_block_number,
        p.mint_block_time                                                     AS mint_block_time,
        p.pool_mint_log_index                                                 AS pool_mint_log_index,
        p.token0_decimals                                                     AS token0_decimals,
        p.token1_decimals                                                     AS token1_decimals,
        s.entry_snapshot_block_number_raw                                     AS entry_snapshot_block_number_raw,
        s.entry_snapshot_log_index_raw                                        AS entry_snapshot_log_index_raw,
        s.entry_snapshot_block_time_raw                                       AS entry_snapshot_block_time_raw,
        s.entry_tick_raw                                                      AS entry_tick_raw,
        s.entry_price_token1_in_token0_raw                                    AS entry_price_token1_in_token0_raw
    FROM positions p
    ASOF LEFT JOIN swaps s
        ON p.pool = s.pool
       AND p.mint_event_seq >= s.swap_event_seq
)

SELECT
    token_id,
    pool,
    mint_block_number,
    mint_block_time,
    pool_mint_log_index,
    isNull(entry_snapshot_block_number_raw)
        OR entry_snapshot_block_number_raw = 0                                AS entry_state_missing,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_snapshot_block_number_raw)
    )                                                                         AS entry_snapshot_block_number,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_snapshot_log_index_raw)
    )                                                                         AS entry_snapshot_log_index,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_snapshot_block_time_raw)
    )                                                                         AS entry_snapshot_block_time,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_tick_raw)
    )                                                                         AS entry_tick,
    if(
        isNull(entry_snapshot_block_number_raw) OR entry_snapshot_block_number_raw = 0,
        NULL,
        toNullable(entry_price_token1_in_token0_raw)
    )                                                                         AS entry_price_token1_in_token0,
    if(
        isNull(entry_snapshot_block_number_raw)
        OR entry_snapshot_block_number_raw = 0
        OR isNull(entry_price_token1_in_token0_raw)
        OR entry_price_token1_in_token0_raw <= 0,
        NULL,
        {{ sqrt_price_from_price(
            'entry_price_token1_in_token0_raw',
            'token0_decimals',
            'token1_decimals'
        ) }}
    )                                                                         AS entry_sqrt_price
FROM entry_state_raw
