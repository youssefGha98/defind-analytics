-- Current state of each pool: latest tick and price.
-- The latest swap is selected by (block_number, log_index), not block_number alone,
-- so multiple swaps in the same block keep deterministic ordering.
-- Materialized as table to avoid view expansion during joins
-- in marts that use window functions.
--
-- GRAIN         : 1 row per pool
-- DEPENDS ON    : stg_swaps, stg_pools
-- KEY DECISIONS :
--   - Two separate argMax calls instead of a single tuple-based argMax.
--     Tuple approach (tupleElement) was fragile: field access by position breaks
--     silently if the tuple definition changes.
--   - stg_pools joined to provide token decimals for the generic sqrt_price_from_price macro.

WITH latest_state AS (
    SELECT
        s.pool,
        {{ latest_swap_state_columns('s', include_snapshot_keys=false) }},
        any(p.token0_decimals)                                               AS token0_decimals,
        any(p.token1_decimals)                                               AS token1_decimals
    FROM {{ ref('stg_swaps') }} s
    INNER JOIN {{ ref('stg_pools') }} p ON s.pool = p.pool
    GROUP BY s.pool
)

SELECT
    pool,
    current_tick,
    price_token1_in_token0,
    {{ sqrt_price_from_price('price_token1_in_token0', 'token0_decimals', 'token1_decimals') }} AS sqrt_price_current
FROM latest_state
