-- TVL distribution by tick bins — tick_deltas method.
--
-- Optional parameter: target_block (default = latest block).
-- Example: dbt run --select mart_tvl_distribution --vars '{"target_block": 18000000}'
--
-- tick_deltas principle:
--   +liquidity_delta at tick_lower → position enters the range when price moves up
--   -liquidity_delta at tick_upper → position exits the range when price moves up
--   cumsum gives the available liquidity in each bin
--
-- GRAIN         : 1 row per (pool, tick_lower, tick_upper)
-- DEPENDS ON    : int_current_state, stg_pools, int_tick_boundary_deltas
-- KEY DECISIONS :
--   - tvl_token0 = amount0 + amount1 * price_token1_in_token0.
--     Equals USD only when token0 is a known stablecoin (e.g. USDC).
--   - price_lower/price_upper use pow(10, token1_decimals - token0_decimals) generically,
--     replacing the previously hardcoded 1e12 constant (specific to USDC/WETH).
--   - ClickHouse 26.x note: triple JOIN on a CTE with window functions triggers
--     UNKNOWN_IDENTIFIER. Workaround: pre-join pool_state = int_current_state ⋈ stg_pools.
--   - target_block branch uses two separate argMax calls instead of latest_swap_state_tuple
--     macro (tuple approach was fragile: field access by position breaks silently).

{% set target_block = var('target_block', none) %}

WITH

-- ─── 1. Pool state + metadata (pre-joined to avoid ClickHouse 26.x bug) ─────
{% if target_block %}
pool_state AS (
    SELECT
        s.pool,
        s.current_tick,
        s.price_token1_in_token0,
        {{ sqrt_price_from_price('s.price_token1_in_token0', 'p.token0_decimals', 'p.token1_decimals') }} AS sqrt_price_current,
        p.tick_spacing,
        p.token0_symbol,
        p.token1_symbol,
        p.token0_decimals,
        p.token1_decimals
    FROM (
        SELECT
            pool,
            argMax(tick,                   tuple(block_number, log_index)) AS current_tick,
            argMax(price_token1_in_token0, tuple(block_number, log_index)) AS price_token1_in_token0
        FROM {{ ref('stg_swaps') }}
        WHERE block_number <= {{ target_block }}
        GROUP BY pool
    ) s
    INNER JOIN {{ ref('stg_pools') }} p ON s.pool = p.pool
),
{% else %}
pool_state AS (
    SELECT
        s.pool,
        s.current_tick,
        s.sqrt_price_current,
        s.price_token1_in_token0,
        p.tick_spacing,
        p.token0_symbol,
        p.token1_symbol,
        p.token0_decimals,
        p.token1_decimals
    FROM {{ ref('int_current_state') }} s
    INNER JOIN {{ ref('stg_pools') }} p ON s.pool = p.pool
),
{% endif %}

-- ─── 2. liquidityNet per tick (filtered to target block) ─────────────────────
tick_net AS (
    SELECT
        pool,
        tick_boundary                                                          AS tick,
        sum(liquidity_net_delta)                                               AS liquidity_net
    FROM {{ ref('int_tick_boundary_deltas') }}
    {% if target_block %} WHERE block_number <= {{ target_block }} {% endif %}
    GROUP BY pool, tick_boundary
    HAVING liquidity_net != 0
),

-- ─── 3. Ranges with cumulative liquidity ─────────────────────────────────────
tick_ranges AS (
    SELECT
        pool,
        tick                                                               AS tick_lower,
        LEAD(tick) OVER (PARTITION BY pool ORDER BY tick)                  AS tick_upper,
        toFloat64(greatest(
            sum(liquidity_net) OVER (PARTITION BY pool ORDER BY tick ROWS UNBOUNDED PRECEDING),
            0
        ))                                                                 AS liquidity
    FROM tick_net
),

-- ─── 4. token0/token1 amounts per bin ────────────────────────────────────────
bin_bounds AS (
    SELECT
        r.pool,
        r.tick_lower,
        r.tick_upper,
        r.liquidity,
        ps.tick_spacing,
        ps.token0_symbol,
        ps.token1_symbol,
        ps.token0_decimals,
        ps.token1_decimals,

        {{ sqrt_price_at_tick('r.tick_lower') }}                           AS sp_low,
        {{ sqrt_price_at_tick('r.tick_upper') }}                           AS sp_high,
        {{ clamp_sqrt_price('ps.sqrt_price_current', 'r.tick_lower', 'r.tick_upper') }} AS sp,

        ps.current_tick,
        ps.sqrt_price_current,
        ps.price_token1_in_token0,

        r.tick_lower <= ps.current_tick
            AND ps.current_tick < r.tick_upper                             AS is_active_bin

    FROM tick_ranges r
    INNER JOIN pool_state ps ON r.pool = ps.pool
    WHERE r.tick_upper IS NOT NULL
      AND r.liquidity > 0
),

bin_amounts AS (
    SELECT
        pool,
        tick_lower,
        tick_upper,
        liquidity,
        tick_spacing,
        token0_symbol,
        token1_symbol,
        token0_decimals,
        token1_decimals,
        current_tick,
        sqrt_price_current,
        price_token1_in_token0,
        sp_low,
        sp_high,
        sp,
        is_active_bin,

        {{ amount0_from_liquidity('liquidity', 'sp', 'sp_high', 'token0_decimals') }} AS amount0,
        {{ amount1_from_liquidity('liquidity', 'sp', 'sp_low',  'token1_decimals') }} AS amount1
    FROM bin_bounds
)

SELECT
    pool,
    tick_lower,
    tick_upper,
    tick_spacing,
    liquidity,
    is_active_bin,
    current_tick,
    price_token1_in_token0,
    token0_symbol,
    token1_symbol,

    amount0,
    amount1,
    -- tvl_token0: denominated in token0. Equals USD only when token0 is a stablecoin.
    amount0 + amount1 * toFloat64(price_token1_in_token0)                  AS tvl_token0,

    100.0 * liquidity / sum(liquidity) OVER (PARTITION BY pool)            AS pct_liquidity,

    -- Human-readable price bounds: token1 per token0, generic via decimal ratio.
    round(pow(10, toFloat64(token1_decimals - token0_decimals)) / pow(1.0001, tick_lower), 2) AS price_lower,
    round(pow(10, toFloat64(token1_decimals - token0_decimals)) / pow(1.0001, tick_upper), 2) AS price_upper,

    -- Midpoint tick for X-axis on charts.
    (tick_lower + tick_upper) / 2                                          AS tick_mid

FROM bin_amounts
