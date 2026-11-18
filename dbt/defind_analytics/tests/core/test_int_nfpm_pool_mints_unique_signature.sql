SELECT
    tx_hash,
    liquidity_delta_raw,
    amount0_raw,
    amount1_raw,
    tx_match_ordinal,
    count(*) AS n
FROM {{ ref('int_nfpm_pool_mints') }}
GROUP BY
    tx_hash,
    liquidity_delta_raw,
    amount0_raw,
    amount1_raw,
    tx_match_ordinal
HAVING n > 1
