WITH pool_mints AS (
    SELECT
        tx_hash,
        toDecimal128(amount, 0)                                                 AS liquidity_delta_raw,
        toDecimal256(amount0, 0)                                                AS amount0_raw,
        toDecimal256(amount1, 0)                                                AS amount1_raw,
        row_number() OVER (
            PARTITION BY
                tx_hash,
                toDecimal128(amount, 0),
                toDecimal256(amount0, 0),
                toDecimal256(amount1, 0)
            ORDER BY toUInt64(log_index)
        )                                                                       AS tx_match_ordinal
    FROM {{ source('analytics', 'uniswap_usdc_weth_mint') }}
    WHERE lower(owner) = '0xc36442b4a4522e871399cd717abdd847ab11fe88'
      AND lower(sender) = '0xc36442b4a4522e871399cd717abdd847ab11fe88'
      AND toInt32OrNull(tickLower) IS NOT NULL
      AND toInt32OrNull(tickUpper) IS NOT NULL
      AND toDecimal128(amount, 0) != 0
),

mapped_increases AS (
    SELECT
        i.token_id,
        i.tx_hash,
        i.log_index,
        i.liquidity_delta_raw,
        i.amount0_raw,
        i.amount1_raw,
        row_number() OVER (
            PARTITION BY
                i.tx_hash,
                i.liquidity_delta_raw,
                i.amount0_raw,
                i.amount1_raw
            ORDER BY i.log_index, i.token_id
        )                                                                       AS tx_match_ordinal
    FROM {{ ref('stg_nfpm_increase_liquidity') }} i
    INNER JOIN {{ ref('int_nfpm_positions') }} p ON i.token_id = p.token_id
)

SELECT
    i.token_id,
    i.tx_hash,
    i.log_index,
    i.liquidity_delta_raw,
    i.amount0_raw,
    i.amount1_raw
FROM mapped_increases i
LEFT JOIN pool_mints m
    ON i.tx_hash = m.tx_hash
   AND i.liquidity_delta_raw = m.liquidity_delta_raw
   AND i.amount0_raw = m.amount0_raw
   AND i.amount1_raw = m.amount1_raw
   AND i.tx_match_ordinal = m.tx_match_ordinal
WHERE m.tx_hash IS NULL

