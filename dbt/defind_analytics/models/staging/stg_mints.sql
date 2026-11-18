-- Staging model for Uniswap V3 USDC/WETH mint events.
-- Materialized incrementally because the source is S3-backed and append-only in practice.
-- The first build loads full history; later runs only process newer blocks.
--
-- GRAIN         : 1 row per mint event (tx_hash, log_index)
-- DEPENDS ON    : source analytics.uniswap_usdc_weth_mint, stg_pools
-- KEY DECISIONS :
--   - Pool metadata (decimals, symbols) is joined from stg_pools to centralise
--     any schema changes and drive dynamic decimal scaling.
--   - sender is included (unlike burns) because the Mint event emits it explicitly;
--     it identifies the contract or EOA that triggered the liquidity deposit.
--   - Human-readable token amounts are stored with 18 digits of fractional
--     precision via Decimal256 so that tiny token1 legs are preserved.
--   - toInt32OrNull is used on tickLower / tickUpper as a temporary guard against
--     an int24 sign overflow bug in DefInd: negative ticks are currently written
--     as uint256 two's complement values (~2^256) which exceed Int32 range.
--     Remove OrNull and the WHERE filter once the DefInd fix is deployed and
--     source data is reprocessed. Fix tracked in DefInd issue #XX.
{% set staging_settings = {'storage_policy': 'r2_policy'} if target.name == 'remote' else {} %}

{{ config(
    materialized='incremental',
    order_by=[
        "coalesce(pool, '')",
        'coalesce(block_number, 0)',
        'coalesce(log_index, 0)'
    ],
    partition_by="toYYYYMM(coalesce(block_time, toDateTime('1970-01-01 00:00:00')))",
    settings=staging_settings
) }}

WITH source AS (
    SELECT *
    FROM {{ source('analytics', 'uniswap_usdc_weth_mint') }}
    {% if is_incremental() %}
    -- Only process blocks beyond the current table maximum on incremental runs.
    WHERE block_number > (
        SELECT coalesce(max(block_number), 0)
        FROM {{ this }}
    )
    {% endif %}
),

-- Pool metadata: token symbols and decimals.
-- Joined here to drive dynamic decimal scaling for amounts.
pool_meta AS (
    SELECT pool, token0_decimals, token1_decimals, token0_symbol, token1_symbol
    FROM {{ ref('stg_pools') }}
),

joined AS (
    SELECT s.*, p.token0_decimals, p.token1_decimals, p.token0_symbol, p.token1_symbol
    FROM source s
    INNER JOIN pool_meta p ON s.contract = p.pool
),

cleaned AS (
    SELECT
        -- identifiers
        tx_hash,
        block_number,
        toUInt64(log_index)                                           AS log_index,
        toDateTime(block_timestamp)                                   AS block_time,
        contract                                                      AS pool,
        token0_symbol,
        token1_symbol,

        -- actors
        owner,
        sender,

        -- liquidity and amounts
        toDecimal128(amount, 0)                                       AS liquidity_delta,
        toDecimal256(amount0, 18)
            / toDecimal256(toString(intExp10(token0_decimals)), 0) AS amount0,
        toDecimal256(amount1, 18)
            / toDecimal256(toString(intExp10(token1_decimals)), 0) AS amount1,

        -- position range
        -- TEMPORARY GUARD: OrNull filters out int24 sign overflow from DefInd.
        -- Remove once fix is deployed and source data is reprocessed.
        toInt32OrNull(tickLower)                                      AS tick_lower,
        toInt32OrNull(tickUpper)                                      AS tick_upper

    FROM joined
    WHERE amount0 IS NOT NULL
      AND amount1 IS NOT NULL
      -- TEMPORARY GUARD: excludes rows where tickLower/tickUpper are corrupted
      -- due to int24 sign overflow in DefInd. Remove once fix is deployed.
      AND toInt32OrNull(tickLower) IS NOT NULL
      AND toInt32OrNull(tickUpper) IS NOT NULL
)

SELECT * FROM cleaned
