-- Pool metadata: one row per pool with centralized type casts.
-- Joining source('analytics', 'pools') directly in marts/intermediates means
-- any schema change (e.g. fee_bps type) requires fixes in every downstream model.
-- This model is the single cast point for the pools source.
-- It stays a view because the source is tiny and almost static.
{{ config(materialized='view') }}

SELECT
    pool,
    toFloat64(fee_bps)              AS fee_bps,
    toUInt32(tick_spacing)          AS tick_spacing,
    token0_address,
    toString(token0_symbol)         AS token0_symbol,
    toUInt8(token0_decimals)        AS token0_decimals,
    token1_address,
    toString(token1_symbol)         AS token1_symbol,
    toUInt8(token1_decimals)        AS token1_decimals,
    deployment_block,
    toDateTime(deployment_ts)       AS deployment_ts
FROM {{ source('analytics', 'pools') }}
