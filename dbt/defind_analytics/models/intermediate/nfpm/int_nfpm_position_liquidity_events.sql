WITH increases AS (
    SELECT
        p.token_id                                                             AS token_id,
        p.pool                                                                 AS pool,
        p.tick_lower                                                           AS tick_lower,
        p.tick_upper                                                           AS tick_upper,
        i.tx_hash                                                              AS tx_hash,
        i.block_number                                                         AS block_number,
        i.block_time                                                           AS block_time,
        i.log_index                                                            AS log_index,
        'IncreaseLiquidity'                                                     AS event_type,
        i.liquidity_delta_raw                                                   AS liquidity_delta_raw,
        i.amount0_raw                                                           AS amount0_raw,
        i.amount1_raw                                                           AS amount1_raw
    FROM {{ ref('stg_nfpm_increase_liquidity') }} i
    INNER JOIN {{ ref('int_nfpm_positions') }} p ON i.token_id = p.token_id
),

decreases AS (
    SELECT
        p.token_id                                                             AS token_id,
        p.pool                                                                 AS pool,
        p.tick_lower                                                           AS tick_lower,
        p.tick_upper                                                           AS tick_upper,
        d.tx_hash                                                              AS tx_hash,
        d.block_number                                                         AS block_number,
        d.block_time                                                           AS block_time,
        d.log_index                                                            AS log_index,
        'DecreaseLiquidity'                                                     AS event_type,
        -d.liquidity_delta_raw                                                  AS liquidity_delta_raw,
        -d.amount0_raw                                                          AS amount0_raw,
        -d.amount1_raw                                                          AS amount1_raw
    FROM {{ ref('stg_nfpm_decrease_liquidity') }} d
    INNER JOIN {{ ref('int_nfpm_positions') }} p ON d.token_id = p.token_id
),

unioned AS (
    SELECT * FROM increases
    UNION ALL
    SELECT * FROM decreases
)

SELECT
    u.token_id                                                             AS token_id,
    u.pool                                                                 AS pool,
    u.tick_lower                                                           AS tick_lower,
    u.tick_upper                                                           AS tick_upper,
    u.tx_hash                                                              AS tx_hash,
    u.block_number                                                         AS block_number,
    u.block_time                                                           AS block_time,
    u.log_index                                                            AS log_index,
    u.event_type                                                           AS event_type,
    u.liquidity_delta_raw                                                  AS liquidity_delta_raw,
    u.amount0_raw                                                          AS amount0_raw,
    u.amount1_raw                                                          AS amount1_raw,
    sp.token0_symbol                                                       AS token0_symbol,
    sp.token1_symbol                                                       AS token1_symbol,
    {{ scale_raw_token_amount('u.amount0_raw', 'sp.token0_decimals') }}         AS amount0,
    {{ scale_raw_token_amount('u.amount1_raw', 'sp.token1_decimals') }}         AS amount1
FROM unioned u
INNER JOIN {{ ref('stg_pools') }} sp ON u.pool = lower(sp.pool)
