{{ config(materialized='table', order_by=['token_id']) }}

-- Aggregate lot-based benchmark state per NFPM tokenId.
--
-- GRAIN         : 1 row per token_id
-- DEPENDS ON    : int_nfpm_position_increase_lots, int_current_state
-- KEY DECISIONS :
--   - Benchmarks are now capital-lot aware: every increase contributes its own
--     entry-time cost basis and current HODL benchmark.
--   - Percent metrics downstream should always be derived from these aggregated
--     value totals, never from arithmetic averages of per-lot percentages.
--   - A tokenId benchmark is valid only when every lot has an observable entry state.

WITH current_state AS (
    SELECT
        lower(pool)                                                          AS pool,
        toFloat64(price_token1_in_token0)                                    AS current_price_token1_in_token0
    FROM {{ ref('int_current_state') }}
),

lots AS (
    SELECT
        l.token_id,
        l.pool,
        l.lot_seq,
        l.entry_state_missing,
        toFloat64(l.lot_amount0)                                             AS lot_amount0_f64,
        toFloat64(l.lot_amount1)                                             AS lot_amount1_f64,
        l.contribution_value_token0_at_entry                                 AS contribution_value_token0_at_entry
    FROM {{ ref('int_nfpm_position_increase_lots') }} l
)

SELECT
    l.token_id,
    l.pool,
    count()                                                                  AS lot_count,
    countIf(NOT l.entry_state_missing)                                       AS valid_lot_benchmark_count,
    countIf(l.entry_state_missing)                                           AS missing_lot_benchmark_count,
    countIf(l.entry_state_missing) = 0                                       AS is_lot_benchmark_valid,
    sum(l.lot_amount0_f64)                                                   AS total_contribution_amount0,
    sum(l.lot_amount1_f64)                                                   AS total_contribution_amount1,
    sumIf(l.contribution_value_token0_at_entry, NOT l.entry_state_missing)   AS total_contribution_value_token0_at_entry,
    sum(
        l.lot_amount0_f64
        + l.lot_amount1_f64 * c.current_price_token1_in_token0
    )                                                                        AS total_hodl_value_token0_current
FROM lots l
INNER JOIN current_state c ON l.pool = c.pool
GROUP BY
    l.token_id,
    l.pool,
    c.current_price_token1_in_token0
