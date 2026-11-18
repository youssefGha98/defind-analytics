WITH pool_mint_tx_hashes AS (
    SELECT DISTINCT tx_hash
    FROM {{ source('analytics', 'uniswap_usdc_weth_mint') }}
    WHERE lower(owner) = '0xc36442b4a4522e871399cd717abdd847ab11fe88'
      AND lower(sender) = '0xc36442b4a4522e871399cd717abdd847ab11fe88'
      AND toInt32OrNull(tickLower) IS NOT NULL
      AND toInt32OrNull(tickUpper) IS NOT NULL
      AND toDecimal128(amount, 0) != 0
),

expected AS (
    SELECT
        t.token_id,
        t.tx_hash
    FROM {{ ref('stg_nfpm_transfers') }} t
    WHERE t.is_mint_transfer
      AND t.tx_hash IN (SELECT tx_hash FROM pool_mint_tx_hashes)
),

actual AS (
    SELECT
        token_id,
        tx_hash
    FROM {{ ref('int_nfpm_token_mint_actions') }}
)

SELECT
    a.token_id,
    a.tx_hash
FROM actual a
LEFT JOIN expected e
    ON a.token_id = e.token_id
   AND a.tx_hash = e.tx_hash
WHERE e.token_id IS NULL
