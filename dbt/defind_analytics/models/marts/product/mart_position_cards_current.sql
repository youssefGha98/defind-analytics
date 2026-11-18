-- Position card mart — 1 row per OPEN NFPM token_id on indexed pools.
--
-- Powers the Positions list and Position Detail header. Factual fields only:
-- MTM, range status, fees, IL, age, observed time-in-range. No score, no
-- recommendation, no risk label — Python position_scoring owns those.
--
-- GRAIN         : 1 row per token_id (open NFPM positions only)
-- DEPENDS ON    : dim_indexed_pools, mart_nfpm_open_positions_current,
--                 mart_nfpm_position_pnl_current, stg_pools
-- KEY DECISIONS :
--   - Open positions only. Closed/burned tokenIds belong on a separate history mart.
--   - Indexed-pool scope via dim_indexed_pools.
--   - apr_estimate is the fee yield realized to date, annualized: total fee wealth
--     divided by current principal wealth, scaled to a year. NULL when principal
--     wealth is 0 (closed or never deployed) or position age < 1 day.
--   - status_in_range derived from current_tick vs (tick_lower, tick_upper).
--   - price_lower / price_upper expressed as token1-per-token0 for chart use.

{{ config(materialized='table', order_by=['token_id']) }}

WITH

indexed AS (
    SELECT
        pool_address,
        chain,
        dex,
        fee_tier,
        token0_symbol,
        token1_symbol,
        token0_decimals,
        token1_decimals,
        concat(token0_symbol, '/', token1_symbol)                          AS token_pair
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

base AS (
    SELECT
        p.token_id,
        p.current_owner                                                    AS wallet,
        p.pool                                                             AS pool_address,
        p.tick_lower,
        p.tick_upper,
        p.range_width_ticks,
        p.current_tick,
        p.price_token1_in_token0                                           AS current_price,
        p.is_open,
        p.is_active,
        p.mint_block_time,
        p.last_position_activity_time,
        pnl.current_position_amount0                                       AS pooled_amount0,
        pnl.current_position_amount1                                       AS pooled_amount1,
        pnl.current_deployed_principal_token0                              AS pooled_value_token0,
        pnl.current_principal_wealth_token0,
        pnl.current_fee_wealth_token0,
        pnl.current_collected_fee_wealth_token0,
        pnl.current_uncollected_fee_wealth_token0,
        pnl.current_total_wealth_token0,
        pnl.pnl_vs_initial_token0,
        pnl.pnl_vs_initial_pct,
        pnl.pnl_vs_hodl_token0,
        pnl.pnl_vs_hodl_pct,
        pnl.impermanent_loss_token0,
        pnl.impermanent_loss_pct,
        pnl.observed_time_in_range_pct,
        pnl.observed_time_in_range_seconds,
        pnl.observed_window_seconds,
        pnl.is_lot_benchmark_valid,
        pnl.entry_state_missing,
        pnl.entry_price_token1_in_token0
    FROM {{ ref('mart_nfpm_open_positions_current') }} p
    INNER JOIN {{ ref('mart_nfpm_position_pnl_current') }} pnl ON pnl.token_id = p.token_id
)

SELECT
    b.token_id,
    b.wallet,
    b.pool_address,
    i.chain,
    i.dex,
    i.token_pair,
    i.token0_symbol,
    i.token1_symbol,
    i.fee_tier,

    -- ─── Range geometry ─────────────────────────────────────────────────────
    b.tick_lower,
    b.tick_upper,
    b.range_width_ticks,
    -- price bounds: token1 per token0, generic via decimal ratio.
    pow(10, toFloat64(i.token1_decimals - i.token0_decimals)) / pow(1.0001, b.tick_upper) AS price_lower,
    pow(10, toFloat64(i.token1_decimals - i.token0_decimals)) / pow(1.0001, b.tick_lower) AS price_upper,

    -- ─── Live state ─────────────────────────────────────────────────────────
    b.current_tick,
    b.current_price,
    if(
        b.is_active = 1, 'in_range',
        if(b.current_tick < b.tick_lower, 'below_range', 'above_range')
    )                                                                      AS status_in_range,

    -- ─── Pooled holdings ────────────────────────────────────────────────────
    b.pooled_amount0,
    b.pooled_amount1,
    b.pooled_value_token0,

    -- ─── PnL (token0 numeraire) ─────────────────────────────────────────────
    b.current_total_wealth_token0,
    b.pnl_vs_initial_token0                                                AS pnl_token0,
    b.pnl_vs_initial_pct                                                   AS pnl_pct,
    b.pnl_vs_hodl_token0,
    b.pnl_vs_hodl_pct,
    b.impermanent_loss_token0,
    b.impermanent_loss_pct                                                 AS il_pct,

    -- ─── Fees ───────────────────────────────────────────────────────────────
    b.current_collected_fee_wealth_token0                                  AS fees_collected_token0,
    b.current_uncollected_fee_wealth_token0                                AS uncollected_fees_token0,
    b.current_fee_wealth_token0                                            AS total_fees_token0,

    -- ─── APR estimate (fee yield to date, annualized) ───────────────────────
    if(
        b.current_principal_wealth_token0 > 0
        AND b.mint_block_time IS NOT NULL
        AND dateDiff('day', b.mint_block_time, now()) >= 1,
        b.current_fee_wealth_token0 / b.current_principal_wealth_token0
            * 365.0 / dateDiff('day', b.mint_block_time, now()),
        NULL
    )                                                                      AS apr_estimate,

    -- ─── V1 placeholder: per-position AS cost is a Python derivation ────────
    CAST(NULL AS Nullable(Float64))                                        AS adverse_selection_cost_token0_proxy,

    -- ─── Lifecycle ──────────────────────────────────────────────────────────
    dateDiff('day', b.mint_block_time, now())                              AS position_age_days,
    b.observed_time_in_range_pct                                           AS time_in_range_pct_observed,
    b.observed_time_in_range_seconds,
    b.observed_window_seconds,
    b.mint_block_time,
    b.last_position_activity_time,

    -- ─── Validity flags ─────────────────────────────────────────────────────
    b.is_lot_benchmark_valid,
    b.entry_state_missing,
    b.entry_price_token1_in_token0,

    now()                                                                  AS updated_at
FROM base b
INNER JOIN indexed i ON i.pool_address = b.pool_address
