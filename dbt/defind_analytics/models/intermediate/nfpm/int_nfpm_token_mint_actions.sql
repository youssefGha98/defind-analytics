WITH pool_mints AS (
    SELECT
        tx_hash,
        pool_mint_log_index,
        pool,
        liquidity_delta_raw,
        amount0_raw,
        amount1_raw,
        tick_lower,
        tick_upper,
        tx_match_ordinal
    FROM {{ ref('int_nfpm_pool_mints') }}
),

pool_mint_tx_hashes AS (
    SELECT DISTINCT tx_hash
    FROM pool_mints
),

mint_transfers AS (
    SELECT
        tx_hash,
        block_number,
        block_time,
        log_index                                                               AS transfer_log_index,
        token_id,
        to_address                                                              AS initial_owner
    FROM {{ ref('stg_nfpm_transfers') }}
    WHERE is_mint_transfer
      AND tx_hash IN (SELECT tx_hash FROM pool_mint_tx_hashes)
),

initial_increases AS (
    SELECT
        tx_hash,
        block_number,
        block_time,
        log_index,
        token_id,
        liquidity_delta_raw,
        amount0_raw,
        amount1_raw,
        row_number() OVER (
            PARTITION BY token_id
            ORDER BY block_number, log_index
        )                                                                       AS token_increase_rank
    FROM {{ ref('stg_nfpm_increase_liquidity') }}
    WHERE tx_hash IN (SELECT tx_hash FROM pool_mint_tx_hashes)
),

mint_actions AS (
    SELECT
        mt.token_id,
        mt.tx_hash,
        mt.block_number                                                         AS mint_block_number,
        mt.block_time                                                           AS mint_block_time,
        mt.transfer_log_index,
        mt.initial_owner,
        ii.log_index                                                            AS increase_log_index,
        ii.liquidity_delta_raw,
        ii.amount0_raw,
        ii.amount1_raw,
        -- Ordinal must match int_nfpm_pool_mints.tx_match_ordinal:
        -- same PARTITION BY keys, ORDER BY a single log_index (no secondary key).
        -- ii.log_index (IncreaseLiquidity) and pool_mint_log_index (Mint) share
        -- the same relative ordering within a tx because each NFPM mint emits
        -- its pool Mint before its IncreaseLiquidity in one atomic internal call.
        row_number() OVER (
            PARTITION BY
                mt.tx_hash,
                ii.liquidity_delta_raw,
                ii.amount0_raw,
                ii.amount1_raw
            ORDER BY ii.log_index
        )                                                                       AS tx_match_ordinal
    FROM mint_transfers mt
    INNER JOIN initial_increases ii
        ON  mt.token_id = ii.token_id
        AND mt.tx_hash = ii.tx_hash
        AND ii.token_increase_rank = 1
),

pool_scoped AS (
    SELECT
        ma.*,
        pm.pool_mint_log_index,
        pm.pool,
        pm.tick_lower,
        pm.tick_upper
    FROM mint_actions ma
    INNER JOIN pool_mints pm
        ON  ma.tx_hash = pm.tx_hash
        AND ma.liquidity_delta_raw = pm.liquidity_delta_raw
        AND ma.amount0_raw = pm.amount0_raw
        AND ma.amount1_raw = pm.amount1_raw
        AND ma.tx_match_ordinal = pm.tx_match_ordinal
)

SELECT * FROM pool_scoped
