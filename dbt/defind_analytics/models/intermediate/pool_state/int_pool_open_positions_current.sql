-- Pool-level open LP owner-ranges, reconstructed from pool Mint/Burn events.
--
-- WHY THIS LIVES IN intermediate/ AND NOT IN marts/:
--   This model is the canonical pool-level liquidity state. It is intentionally
--   NOT a frontend mart — it is consumed only by `mart_tvl_current` (and
--   downstream pool TVL reconstructions).
--
--   Pool-level liquidity / TVL / tick distribution / EVC denominators MUST be
--   reconstructed from pool Mint/Burn events (this model), NOT from NFPM
--   positions. NFPM is non-exhaustive: a position can be minted directly on
--   the pool or through a custom manager / ALM without any ERC-721 NFPM token
--   ever being issued. Using `mart_nfpm_*` as the source of pool TVL would
--   undercount active liquidity.
--
--   NFPM marts (mart_nfpm_*) cover NFT position analytics: lifecycle,
--   ownership, fees, wallet-level views, PnL decomposition. They are correct
--   for those use cases but are NOT a substitute for pool-level state.
--
-- All owner × range buckets with net_liquidity > 0 at the current block.
-- Net liquidity = cumulative sum of all mint (+) and burn (-) events per (owner, range).
-- position_token0 is the exact current V3 mark-to-market of the owner-range bucket,
-- denominated in token0. Equals USD only when token0 is a known stablecoin (e.g. USDC).
-- net_amount0 / net_amount1 are kept as historical net deposited token flows.
--
-- GRAIN         : 1 row per (pool, owner, tick_lower, tick_upper) where net_liquidity > 0
-- DEPENDS ON    : int_lp_events, int_current_state, stg_pools
-- KEY DECISIONS :
--   - Inner subquery converted to CTE: ClickHouse new analyzer cannot resolve
--     column references from inline subquery aliases.

WITH net_positions AS (
    SELECT
        pool,
        owner,
        tick_lower,
        tick_upper,
        sum(liquidity_delta) AS net_liquidity,
        sum(amount0)         AS net_amount0,
        sum(amount1)         AS net_amount1
    FROM {{ ref('int_lp_events') }}
    GROUP BY pool, owner, tick_lower, tick_upper
    HAVING net_liquidity > 0
),

position_amounts AS (
    SELECT
        n.pool                                                           AS pool,
        n.owner,
        n.tick_lower,
        n.tick_upper,
        n.net_liquidity,
        n.net_amount0,
        n.net_amount1,
        c.current_tick,
        c.price_token1_in_token0,
        p.tick_spacing,
        p.token0_symbol,
        p.token1_symbol,
        n.tick_lower <= c.current_tick
            AND c.current_tick < n.tick_upper                                AS is_active,
        {{ amount0_from_liquidity('n.net_liquidity', clamp_sqrt_price('c.sqrt_price_current', 'n.tick_lower', 'n.tick_upper'), sqrt_price_at_tick('n.tick_upper'), 'p.token0_decimals') }} AS position_amount0,
        {{ amount1_from_liquidity('n.net_liquidity', clamp_sqrt_price('c.sqrt_price_current', 'n.tick_lower', 'n.tick_upper'), sqrt_price_at_tick('n.tick_lower'), 'p.token1_decimals') }} AS position_amount1
    FROM net_positions n
    INNER JOIN {{ ref('int_current_state') }} c ON n.pool = c.pool
    LEFT JOIN {{ ref('stg_pools') }} p ON n.pool = p.pool
),

valued_positions AS (
    SELECT
        *,
        position_amount0 + position_amount1 * toFloat64(price_token1_in_token0) AS position_token0
    FROM position_amounts
)

SELECT * FROM valued_positions
