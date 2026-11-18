-- Current pool TVL snapshot: total / active / out-of-range plus current-bin breakdown.
--
-- GRAIN         : 1 row per pool
-- DEPENDS ON    : int_current_state, int_pool_open_positions_current, mart_tvl_distribution
-- KEY DECISIONS :
--   - total_tvl_token0 is reconstructed from pool Mint/Burn events
--     (via int_pool_open_positions_current), NOT from NFPM positions.
--     NFPM is non-exhaustive (custom managers, direct pool mints), so it
--     would undercount active liquidity. See int_pool_open_positions_current
--     header for the full rationale.
--   - active_tvl_token0 = in-range TVL at the current tick.
--   - out_of_range_tvl_token0 is the complement of active_tvl_token0 within total_tvl_token0.
--   - current_bin_* metrics come from the active bin in mart_tvl_distribution.
--   - tvl_reconciliation_gap is kept explicitly as a data-quality check:
--       total - active - out_of_range

WITH position_totals AS (
    SELECT
        pool,
        sum(position_token0)                       AS total_tvl_token0,
        sumIf(position_token0, is_active = 1)     AS active_tvl_token0,
        sumIf(position_token0, is_active = 0)     AS out_of_range_tvl_token0
    FROM {{ ref('int_pool_open_positions_current') }}
    GROUP BY pool
),

current_bin AS (
    SELECT
        pool,
        any(tick_lower)                           AS current_bin_tick_lower,
        any(tick_upper)                           AS current_bin_tick_upper,
        sum(coalesce(liquidity, 0.0))             AS current_bin_liquidity,
        sum(coalesce(amount0, 0.0))               AS current_bin_token0,
        sum(coalesce(amount1, 0.0))               AS current_bin_token1,
        sum(
            coalesce(amount1, 0.0)
            * toFloat64(price_token1_in_token0)
        )                                         AS current_bin_token1_in_token0,
        sum(coalesce(tvl_token0, 0.0))            AS current_bin_tvl_token0
    FROM {{ ref('mart_tvl_distribution') }}
    WHERE is_active_bin = 1
    GROUP BY pool
)

SELECT
    s.pool                                                                           AS pool,
    s.current_tick,
    s.price_token1_in_token0,
    {{ tvl_snapshot_component_columns(
        'pt.total_tvl_token0',
        'pt.active_tvl_token0',
        'pt.out_of_range_tvl_token0',
        'cb'
    ) }}
FROM {{ ref('int_current_state') }} s
LEFT JOIN position_totals pt ON s.pool = pt.pool
LEFT JOIN current_bin cb ON s.pool = cb.pool
