-- Indexed pool universe — the canonical dimension that scopes every product mart.
--
-- Every pool-, wallet-, position-, screener-, optimizer-, and intelligence-facing
-- output must scope to this table. Wallet metrics in particular are LP-only on
-- indexed pools, not full ERC20 wallet balances.
--
-- V1 policy: every pool present in stg_pools is considered an active indexed pool.
-- chain and dex are hardcoded for now (single-chain, single-DEX universe).
-- Future: gate via a coverage seed/var when more pools are indexed but not all
-- product-ready (coverage_status = 'partial' / 'paused').
--
-- GRAIN         : 1 row per pool
-- DEPENDS ON    : stg_pools
-- KEY DECISIONS :
--   - fee_tier is exposed as a percentage (0.05 means 0.05%), matching the
--     stg_pools.fee_bps convention used everywhere in the project.
--   - indexed_until_block is NULL while coverage_status = 'active'.
--   - created_at = pool deployment_ts; updated_at = build time.

{{ config(materialized='table') }}

SELECT
    p.pool                                                                 AS pool_address,
    'ethereum'                                                             AS chain,
    'uniswap_v3'                                                           AS dex,
    p.token0_address,
    p.token1_address,
    p.token0_symbol,
    p.token1_symbol,
    p.token0_decimals,
    p.token1_decimals,
    toFloat64(p.fee_bps)                                                   AS fee_tier,
    p.tick_spacing,
    toUInt8(1)                                                             AS is_active,
    toUInt64(p.deployment_block)                                           AS indexed_since_block,
    CAST(NULL AS Nullable(UInt64))                                         AS indexed_until_block,
    'active'                                                               AS coverage_status,
    p.deployment_ts                                                        AS created_at,
    now()                                                                  AS updated_at
FROM {{ ref('stg_pools') }} p
