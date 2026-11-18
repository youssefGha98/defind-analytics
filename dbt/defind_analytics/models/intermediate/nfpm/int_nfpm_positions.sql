WITH matched AS (
    SELECT
        nm.token_id                                                           AS token_id,
        nm.pool                                                               AS pool,
        nm.tick_lower                                                         AS tick_lower,
        nm.tick_upper                                                         AS tick_upper,
        nm.initial_owner                                                      AS initial_owner,
        nm.tx_hash                                                            AS tx_hash,
        nm.mint_block_number                                                  AS mint_block_number,
        nm.mint_block_time                                                    AS mint_block_time,
        nm.transfer_log_index                                                 AS transfer_log_index,
        nm.increase_log_index                                                 AS increase_log_index,
        nm.pool_mint_log_index                                                AS pool_mint_log_index,
        nm.liquidity_delta_raw                                                AS liquidity_delta_raw,
        nm.amount0_raw                                                        AS amount0_raw,
        nm.amount1_raw                                                        AS amount1_raw
    FROM {{ ref('int_nfpm_token_mint_actions') }} nm
),

enriched AS (
    SELECT
        m.*,
        p.token0_symbol,
        p.token1_symbol,
        p.token0_decimals,
        p.token1_decimals,
        p.fee_bps,
        {{ scale_raw_token_amount('m.amount0_raw', 'p.token0_decimals') }}      AS amount0,
        {{ scale_raw_token_amount('m.amount1_raw', 'p.token1_decimals') }}      AS amount1
    FROM matched m
    INNER JOIN {{ ref('stg_pools') }} p ON m.pool = lower(p.pool)
)

SELECT * FROM enriched
