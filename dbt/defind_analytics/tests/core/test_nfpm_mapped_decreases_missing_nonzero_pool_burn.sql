WITH pool_burns AS (
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
    FROM {{ source('analytics', 'uniswap_usdc_weth_burn') }}
    WHERE lower(owner) = '0xc36442b4a4522e871399cd717abdd847ab11fe88'
      AND toInt32OrNull(tickLower) IS NOT NULL
      AND toInt32OrNull(tickUpper) IS NOT NULL
      AND toDecimal128(amount, 0) != 0
),

mapped_decreases AS (
    SELECT
        d.token_id,
        d.tx_hash,
        d.log_index,
        d.liquidity_delta_raw,
        d.amount0_raw,
        d.amount1_raw,
        row_number() OVER (
            PARTITION BY
                d.tx_hash,
                d.liquidity_delta_raw,
                d.amount0_raw,
                d.amount1_raw
            ORDER BY d.log_index, d.token_id
        )                                                                       AS tx_match_ordinal
    FROM {{ ref('stg_nfpm_decrease_liquidity') }} d
    INNER JOIN {{ ref('int_nfpm_positions') }} p ON d.token_id = p.token_id
)

SELECT
    d.token_id,
    d.tx_hash,
    d.log_index,
    d.liquidity_delta_raw,
    d.amount0_raw,
    d.amount1_raw
FROM mapped_decreases d
LEFT JOIN pool_burns b
    ON d.tx_hash = b.tx_hash
   AND d.liquidity_delta_raw = b.liquidity_delta_raw
   AND d.amount0_raw = b.amount0_raw
   AND d.amount1_raw = b.amount1_raw
   AND d.tx_match_ordinal = b.tx_match_ordinal
WHERE b.tx_hash IS NULL
