-- Tracked-LP wallet exposure breakdown — 1 row per (wallet, exposure_dimension,
-- exposure_name).
--
-- V1 dimensions:
--   - by_token   : exposure to token0 vs token1 across all open positions (token0-priced)
--   - by_status  : in-range vs out-of-range capital
--   - by_pool    : exposure per pool (single-row in V1, trivially equal to total)
--
-- All exposures denominated in token0. exposure_pct is computed within the
-- wallet × dimension scope, so each dimension sums to 1.0 per wallet.
--
-- GRAIN         : 1 row per (wallet, exposure_dimension, exposure_name)
-- DEPENDS ON    : dim_indexed_pools, mart_nfpm_positions_current,
--                 mart_nfpm_position_pnl_current
-- KEY DECISIONS :
--   - Open positions only — closed positions don't carry meaningful current exposure.
--   - Burn-like owners excluded.
--   - exposure_pct uses sum-within-dimension as denominator. NULL when total = 0.

{{ config(materialized='table', order_by=['wallet']) }}

WITH

indexed AS (
    SELECT pool_address
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

open_positions AS (
    SELECT
        pos.current_owner                                                  AS wallet,
        pos.pool                                                           AS pool_address,
        pos.is_active                                                      AS is_active,
        pnl.current_position_amount0                                       AS amount0,
        pnl.current_position_amount1                                       AS amount1,
        pnl.current_price_token1_in_token0                                 AS current_price,
        pnl.current_principal_wealth_token0                                AS principal_token0
    FROM {{ ref('mart_nfpm_positions_current') }} pos
    INNER JOIN {{ ref('mart_nfpm_position_pnl_current') }} pnl ON pnl.token_id = pos.token_id
    INNER JOIN indexed ip ON ip.pool_address = pos.pool
    WHERE pos.is_open = 1
      AND pos.is_current_owner_burn_like = 0
),

-- ─── by_token ─────────────────────────────────────────────────────────────────
by_token AS (
    SELECT
        wallet,
        sum(toFloat64(amount0))                                            AS token0_token0,
        sum(toFloat64(amount1) * toFloat64(current_price))                 AS token1_token0
    FROM open_positions
    GROUP BY wallet
),
by_token_long AS (
    SELECT
        wallet,
        'by_token'                                                         AS exposure_dimension,
        'token0'                                                           AS exposure_name,
        token0_token0                                                      AS exposure_token0,
        if(token0_token0 + token1_token0 > 0,
           token0_token0 / (token0_token0 + token1_token0),
           NULL)                                                           AS exposure_pct
    FROM by_token
    UNION ALL
    SELECT
        wallet,
        'by_token'                                                         AS exposure_dimension,
        'token1'                                                           AS exposure_name,
        token1_token0                                                      AS exposure_token0,
        if(token0_token0 + token1_token0 > 0,
           token1_token0 / (token0_token0 + token1_token0),
           NULL)                                                           AS exposure_pct
    FROM by_token
),

-- ─── by_status ────────────────────────────────────────────────────────────────
by_status AS (
    SELECT
        wallet,
        sumIf(principal_token0, is_active = 1)                             AS in_range_token0,
        sumIf(principal_token0, is_active = 0)                             AS out_of_range_token0
    FROM open_positions
    GROUP BY wallet
),
by_status_long AS (
    SELECT
        wallet,
        'by_status'                                                        AS exposure_dimension,
        'in_range'                                                         AS exposure_name,
        in_range_token0                                                    AS exposure_token0,
        if(in_range_token0 + out_of_range_token0 > 0,
           in_range_token0 / (in_range_token0 + out_of_range_token0),
           NULL)                                                           AS exposure_pct
    FROM by_status
    UNION ALL
    SELECT
        wallet,
        'by_status'                                                        AS exposure_dimension,
        'out_of_range'                                                     AS exposure_name,
        out_of_range_token0                                                AS exposure_token0,
        if(in_range_token0 + out_of_range_token0 > 0,
           out_of_range_token0 / (in_range_token0 + out_of_range_token0),
           NULL)                                                           AS exposure_pct
    FROM by_status
),

-- ─── by_pool ──────────────────────────────────────────────────────────────────
by_pool AS (
    SELECT
        wallet,
        pool_address,
        sum(principal_token0)                                              AS pool_token0
    FROM open_positions
    GROUP BY wallet, pool_address
),
by_pool_long AS (
    SELECT
        bp.wallet,
        'by_pool'                                                          AS exposure_dimension,
        bp.pool_address                                                    AS exposure_name,
        bp.pool_token0                                                     AS exposure_token0,
        if(t.total_token0 > 0, bp.pool_token0 / t.total_token0, NULL)      AS exposure_pct
    FROM by_pool bp
    INNER JOIN (
        SELECT wallet, sum(pool_token0) AS total_token0
        FROM by_pool GROUP BY wallet
    ) t ON t.wallet = bp.wallet
)

SELECT
    wallet,
    exposure_dimension,
    exposure_name,
    exposure_token0,
    exposure_pct,
    'indexed_pools_only'                                                   AS coverage_scope,
    now()                                                                  AS updated_at
FROM (
    SELECT * FROM by_token_long
    UNION ALL SELECT * FROM by_status_long
    UNION ALL SELECT * FROM by_pool_long
)
