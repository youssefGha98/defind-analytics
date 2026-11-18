SELECT
    p.token_id                                                             AS token_id,
    p.pool                                                                 AS pool,
    p.tick_lower                                                           AS tick_lower,
    p.tick_upper                                                           AS tick_upper,
    c.tx_hash                                                              AS tx_hash,
    c.block_number                                                         AS block_number,
    c.block_time                                                           AS block_time,
    c.log_index                                                            AS log_index,
    c.recipient                                                            AS recipient,
    c.amount0_raw                                                          AS amount0_raw,
    c.amount1_raw                                                          AS amount1_raw,
    sp.token0_symbol                                                       AS token0_symbol,
    sp.token1_symbol                                                       AS token1_symbol,
    {{ scale_raw_token_amount('c.amount0_raw', 'sp.token0_decimals') }}         AS amount0,
    {{ scale_raw_token_amount('c.amount1_raw', 'sp.token1_decimals') }}         AS amount1
FROM {{ ref('stg_nfpm_collects') }} c
INNER JOIN {{ ref('int_nfpm_positions') }} p ON c.token_id = p.token_id
INNER JOIN {{ ref('stg_pools') }} sp ON p.pool = lower(sp.pool)
