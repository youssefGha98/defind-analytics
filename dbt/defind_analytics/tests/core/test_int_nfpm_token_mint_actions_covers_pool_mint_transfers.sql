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
    e.token_id,
    e.tx_hash
FROM expected e
LEFT JOIN actual a
    ON e.token_id = a.token_id
   AND e.tx_hash = a.tx_hash
WHERE a.token_id IS NULL

