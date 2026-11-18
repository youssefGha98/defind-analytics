{{ config(materialized='table', order_by=['token_id']) }}

-- Canonical generated-fee summary per NFPM tokenId.
--
-- GRAIN         : 1 row per token_id
-- DEPENDS ON    : int_nfpm_position_fee_daily
-- KEY DECISIONS :
--   - The swap-level fee attribution lives in int_nfpm_position_fee_daily.
--   - This model stays as the stable 1-row-per-token contract consumed by marts.

SELECT
    token_id,
    any(pool)                                                                AS pool,
    sum(active_swap_count)                                                   AS active_swap_count,
    sum(total_fees_accrued_amount0)                                          AS total_fees_accrued_amount0,
    sum(total_fees_accrued_amount1)                                          AS total_fees_accrued_amount1,
    sum(total_fees_accrued_token0_equiv_generated)                           AS total_fees_accrued_token0_equiv_generated
FROM {{ ref('int_nfpm_position_fee_daily') }}
GROUP BY token_id
