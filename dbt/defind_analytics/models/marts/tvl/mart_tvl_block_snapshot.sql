-- Exact pool TVL snapshot at a target block (end-of-block semantics).
--
-- Optional parameter: target_block (default = latest available swap block).
-- Example: dbt build --select mart_tvl_distribution mart_tvl_block_snapshot --vars '{"target_block": 24820333}'
--
-- GRAIN         : 1 row per pool
-- DEPENDS ON    : stg_swaps, stg_pools, int_lp_events, mart_tvl_distribution
-- KEY DECISIONS :
--   - End-of-block semantics: LP deltas include all events with block_number <= target_block,
--     while price/current_tick use the last swap with block_number <= target_block.
--   - total_tvl_token0 and current-bin metrics are reused from mart_tvl_distribution,
--     which already implements exact tick-delta reconstruction at target_block.
--   - active_tvl_token0 / out_of_range_tvl_token0 are computed from aggregated open ranges
--     (pool × tick_lower × tick_upper), which is exact because V3 valuation is linear in liquidity.

{% set target_block = var('target_block', none) %}

WITH pool_state AS (
    SELECT
        s.pool,
        {{ latest_swap_state_columns('s') }},
        any(p.token0_decimals)                                                   AS token0_decimals,
        any(p.token1_decimals)                                                   AS token1_decimals,
        {{ sqrt_price_from_price(
            latest_by_block_log('s.price_token1_in_token0', 's.block_number', 's.log_index'),
            'any(p.token0_decimals)',
            'any(p.token1_decimals)'
        ) }}                                                                     AS sqrt_price_current
    FROM {{ ref('stg_swaps') }} s
    INNER JOIN {{ ref('stg_pools') }} p ON s.pool = p.pool
    {% if target_block is not none %}
    WHERE s.block_number <= {{ target_block }}
    {% endif %}
    GROUP BY s.pool
),

net_ranges AS (
    SELECT
        pool,
        tick_lower,
        tick_upper,
        sum(liquidity_delta)                                                     AS net_liquidity
    FROM {{ ref('int_lp_events') }}
    {% if target_block is not none %}
    WHERE block_number <= {{ target_block }}
    {% endif %}
    GROUP BY pool, tick_lower, tick_upper
    HAVING net_liquidity > 0
),

valued_ranges AS (
    SELECT
        r.pool,
        r.tick_lower <= ps.current_tick
            AND ps.current_tick < r.tick_upper                                   AS is_active,
        {{ amount0_from_liquidity(
            'r.net_liquidity',
            clamp_sqrt_price('ps.sqrt_price_current', 'r.tick_lower', 'r.tick_upper'),
            sqrt_price_at_tick('r.tick_upper'),
            'ps.token0_decimals'
        ) }}                                                                     AS amount0,
        {{ amount1_from_liquidity(
            'r.net_liquidity',
            clamp_sqrt_price('ps.sqrt_price_current', 'r.tick_lower', 'r.tick_upper'),
            sqrt_price_at_tick('r.tick_lower'),
            'ps.token1_decimals'
        ) }}                                                                     AS amount1,
        toFloat64(ps.price_token1_in_token0)                                     AS price_token1_in_token0
    FROM net_ranges r
    INNER JOIN pool_state ps ON r.pool = ps.pool
),

position_totals AS (
    SELECT
        pool,
        sumIf(amount0 + amount1 * price_token1_in_token0, is_active = 1)        AS active_tvl_token0,
        sumIf(amount0 + amount1 * price_token1_in_token0, is_active = 0)        AS out_of_range_tvl_token0
    FROM valued_ranges
    GROUP BY pool
),

distribution_totals AS (
    SELECT
        pool,
        sum(tvl_token0)                                                          AS total_tvl_token0
    FROM {{ ref('mart_tvl_distribution') }}
    GROUP BY pool
),

current_bin AS (
    SELECT
        pool,
        any(tick_lower)                                                          AS current_bin_tick_lower,
        any(tick_upper)                                                          AS current_bin_tick_upper,
        sum(coalesce(liquidity, 0.0))                                            AS current_bin_liquidity,
        sum(coalesce(amount0, 0.0))                                              AS current_bin_token0,
        sum(coalesce(amount1, 0.0))                                              AS current_bin_token1,
        sum(coalesce(amount1, 0.0) * toFloat64(price_token1_in_token0))          AS current_bin_token1_in_token0,
        sum(coalesce(tvl_token0, 0.0))                                           AS current_bin_tvl_token0
    FROM {{ ref('mart_tvl_distribution') }}
    WHERE is_active_bin = 1
    GROUP BY pool
)

SELECT
    ps.pool                                                                     AS pool,
    {% if target_block is not none %}
    toUInt64({{ target_block }})                                                 AS target_block,
    {% else %}
    ps.snapshot_block_number                                                     AS target_block,
    {% endif %}
    ps.snapshot_log_index,
    ps.snapshot_block_time,
    ps.current_tick,
    ps.price_token1_in_token0,
    {{ tvl_snapshot_component_columns(
        'dt.total_tvl_token0',
        'pt.active_tvl_token0',
        'pt.out_of_range_tvl_token0',
        'cb'
    ) }}
FROM pool_state ps
LEFT JOIN distribution_totals dt ON ps.pool = dt.pool
LEFT JOIN position_totals pt ON ps.pool = pt.pool
LEFT JOIN current_bin cb ON ps.pool = cb.pool
