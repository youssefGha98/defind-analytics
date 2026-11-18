{{ config(materialized='table', order_by=['block_number', 'pool_mint_log_index']) }}

-- Canonical pool-side Mint signatures attributable to NFPM on the tracked pool.
--
-- GRAIN         : 1 row per matched pool Mint signature inside a transaction
-- DEPENDS ON    : source analytics.uniswap_usdc_weth_mint
-- KEY DECISIONS :
--   - tx_match_ordinal disambiguates repeated identical Mint signatures inside the
--     same transaction.
--   - Zero-liquidity rows are excluded because they do not create a usable NFPM
--     position mapping and only add noise to the matching surface.

SELECT
    assumeNotNull(tx_hash)                                                      AS tx_hash,
    toUInt64(assumeNotNull(block_number))                                       AS block_number,
    toDateTime(assumeNotNull(block_timestamp))                                  AS block_time,
    toUInt64(assumeNotNull(log_index))                                          AS pool_mint_log_index,
    lower(assumeNotNull(contract))                                              AS pool,
    toDecimal128(assumeNotNull(amount), 0)                                      AS liquidity_delta_raw,
    toDecimal256(assumeNotNull(amount0), 0)                                     AS amount0_raw,
    toDecimal256(assumeNotNull(amount1), 0)                                     AS amount1_raw,
    toInt32(assumeNotNull(tickLower))                                           AS tick_lower,
    toInt32(assumeNotNull(tickUpper))                                           AS tick_upper,
    row_number() OVER (
        PARTITION BY
            assumeNotNull(tx_hash),
            toDecimal128(assumeNotNull(amount), 0),
            toDecimal256(assumeNotNull(amount0), 0),
            toDecimal256(assumeNotNull(amount1), 0)
        ORDER BY toUInt64(assumeNotNull(log_index))
    )                                                                           AS tx_match_ordinal
FROM {{ source('analytics', 'uniswap_usdc_weth_mint') }}
WHERE tx_hash IS NOT NULL
  AND block_number IS NOT NULL
  AND block_timestamp IS NOT NULL
  AND log_index IS NOT NULL
  AND contract IS NOT NULL
  AND amount IS NOT NULL
  AND amount0 IS NOT NULL
  AND amount1 IS NOT NULL
  AND tickLower IS NOT NULL
  AND tickUpper IS NOT NULL
  AND lower(owner) = '0xc36442b4a4522e871399cd717abdd847ab11fe88'
  AND lower(sender) = '0xc36442b4a4522e871399cd717abdd847ab11fe88'
  AND toDecimal128(assumeNotNull(amount), 0) != 0
