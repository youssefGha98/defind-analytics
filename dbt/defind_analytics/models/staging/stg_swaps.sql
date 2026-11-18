-- Staging model for Uniswap V3 USDC/WETH swap events.
-- Materialized incrementally because the source is S3-backed and very large.
-- The first build loads full history; later runs only process newer blocks.
--
-- GRAIN         : 1 row per swap event (tx_hash, log_index)
-- DEPENDS ON    : source analytics.uniswap_usdc_weth_swap, stg_pools
-- KEY DECISIONS :
--   - Pool metadata (decimals, symbols) is joined from stg_pools to avoid
--     hardcoding token specs here and to centralise any schema changes.
--   - amount0 / amount1 use dynamic decimals from pool metadata.
--   - Human-readable token amounts are stored with 18 digits of fractional
--     precision via Decimal256 so that tiny WETH legs are not truncated to zero.
--     A Decimal(..., 6) human amount was lossy for 18-decimal tokens.
--   - price_token1_in_token0 is derived from sqrtPriceX96 using dynamic token decimals.
--     Generic: 10^(token1_decimals - token0_decimals) replaces the previously
--     hardcoded 10^12 constant. Naming is token-order agnostic.
--   - price_scale (= 6) controls precision throughout the sqrtPriceX96 conversion.
--     It is hardcoded as a literal in toDecimal128() due to a ClickHouse constraint
--     (compile-time literal required); all other occurrences use the CTE variable.
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
    FROM {{ source('analytics', 'uniswap_usdc_weth_swap') }}
    {% if is_incremental() %}
    -- Only process blocks beyond the current table maximum on incremental runs.
    WHERE block_number > (
        SELECT coalesce(max(block_number), 0)
        FROM {{ this }}
    )
    {% endif %}
),

-- Pool metadata: token symbols and decimals.
-- Joined here to drive dynamic decimal scaling for amounts and price conversion.
pool_meta AS (
    SELECT pool, token0_decimals, token1_decimals, token0_symbol, token1_symbol
    FROM {{ ref('stg_pools') }}
),

joined AS (
    SELECT s.*, p.token0_decimals, p.token1_decimals, p.token0_symbol, p.token1_symbol
    FROM source s
    INNER JOIN pool_meta p ON s.contract = p.pool
),

-- price_scale drives precision for the sqrtPriceX96 → human price conversion.
-- It appears in three places: the UInt256 multiplier, the toDecimal128 scale
-- (hardcoded literal, ClickHouse constraint), and the final divisor.
constants AS (
    SELECT 6 AS price_scale
),

cleaned AS (
    SELECT
        -- identifiers
        tx_hash,
        block_number,
        toUInt64(log_index)                                               AS log_index,
        toDateTime(block_timestamp)                                       AS block_time,
        contract                                                          AS pool,
        token0_symbol,
        token1_symbol,

        -- actors
        sender,
        recipient,

        -- Token amounts scaled to human-readable units using dynamic decimals.
        -- Decimal256(..., 18) preserves sub-micro token legs for 18-decimal assets
        -- such as WETH; Decimal(..., 6) was truncating many legitimate swaps to zero.
        toDecimal256(amount0, 18)
            / toDecimal256(toString(intExp10(token0_decimals)), 0)        AS amount0,
        toDecimal256(amount1, 18)
            / toDecimal256(toString(intExp10(token1_decimals)), 0)        AS amount1,

        -- Active liquidity at the time of the swap.
        toDecimal128(liquidity, 0)                                        AS liquidity,

        -- Price of token1 denominated in token0, derived from sqrtPriceX96.
        -- sqrtPriceX96 = sqrt(token1_raw / token0_raw) * 2^96
        -- → price_raw    = sqrtPriceX96² / 2^192
        -- → price_human  = price_raw * 10^(token1_decimals - token0_decimals)
        -- Precision trick: multiply by 10^price_scale before integer division,
        -- then shift the decimal point back with / intExp10(price_scale).
        -- Computed in UInt256 because sqrtPriceX96² ~ 10^66, exceeds Decimal128 range.
        -- toString() bridge required: toDecimal128 cannot ingest UInt256 directly.
        toDecimal128(
            toString(
                bitShiftLeft(toUInt256(1), 192)
                * toUInt256(intExp10(token1_decimals - token0_decimals + price_scale))
                / (toUInt256(assumeNotNull(sqrtPriceX96)) * toUInt256(assumeNotNull(sqrtPriceX96)))
            ),
            6  -- = price_scale, hardcoded: ClickHouse requires a compile-time literal here
        ) / intExp10(price_scale)                                         AS price_token1_in_token0,

        -- Current tick at the time of the swap.
        toInt32(tick)                                                     AS tick

    FROM joined
    CROSS JOIN constants  -- scalar CTE, single row, no fanout risk
    WHERE amount0 IS NOT NULL
      AND amount1 IS NOT NULL
      AND sqrtPriceX96 IS NOT NULL
)

SELECT * FROM cleaned
