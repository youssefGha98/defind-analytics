-- Pool screener feature mart — 1 row per (pool, date), scoped to dim_indexed_pools.
--
-- Powers the Pool Screener and feeds Python pool scoring. Factual evidence only:
-- TVL, volume, fees, APR, realized vol, adverse selection proxy, basic flow,
-- price returns, drawdown, concentration. No score, no decision label, no
-- recommendation text — those are owned by the Python scoring engine.
--
-- All token-denominated values use _token0 / _token0_equiv suffixes. They equal
-- USD only when token0 is a stablecoin (V1: token0 = USDC for the indexed pool).
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : dim_indexed_pools, mart_tvl_daily, mart_volume_daily,
--                 int_active_tvl_daily, mart_price_analytics_daily,
--                 int_lp_macro_daily, int_adverse_selection_proxy_daily,
--                 int_daily_close_dense
-- KEY DECISIONS :
--   - Spine = mart_tvl_daily (dense; quiet swap days are preserved with
--     carry-forward close_price).
--   - Volume / fees come from mart_volume_daily and are coalesced to 0 on quiet days
--     so trailing rolling sums treat no-swap days as 0 contribution, not NULL.
--   - Rolling windows (7d / 30d) only emit a value once the full N-day window is
--     available — matches the convention in mart_price_analytics_daily.
--   - lp_count is left NULL in V1 (we don't materialize a per-day owner-resolved
--     liquidity state). position_count = open_range_count from int_lp_macro_daily.
--   - is_estimated = 1 when the row carries any LVR-derived field that comes from
--     a heuristic proxy (V1 always has the AS proxy, so any row with non-NULL AS = 1).

{{ config(materialized='table') }}

WITH

-- ─── 1. Indexed pool scope + metadata ──────────────────────────────────────────
pool_dim AS (
    SELECT
        pool_address,
        chain,
        dex,
        token0_symbol,
        token1_symbol,
        token0_decimals,
        token1_decimals,
        fee_tier,
        tick_spacing,
        concat(token0_symbol, '/', token1_symbol)                          AS token_pair
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

-- ─── 2. Dense pool/day spine ──────────────────────────────────────────────────
spine AS (
    SELECT
        tvl.pool                                                           AS pool,
        tvl.date                                                           AS date,
        tvl.tvl_token0_equiv                                               AS tvl_token0_equiv,
        tvl.price_token1_in_token0                                         AS price_token1_in_token0,
        coalesce(at.active_tvl_token0, 0.0)                                AS active_tvl_token0,
        toUInt64(coalesce(at.active_range_count, 0))                       AS active_range_count,
        coalesce(vol.volume_token0_equiv, 0.0)                             AS volume_token0_equiv,
        coalesce(vol.fees_token0_equiv, 0.0)                               AS fees_token0_equiv,
        toUInt64(coalesce(vol.swap_count, 0))                              AS swap_count,
        price.close_tick                                                   AS close_tick,
        price.close_price                                                  AS close_price,
        price.has_swap                                                     AS has_swap,
        price.log_return                                                   AS log_return,
        price.realized_vol_7d                                              AS realized_vol_7d,
        price.realized_vol_30d                                             AS realized_vol_30d,
        price.drawdown                                                     AS drawdown_alltime,
        macro.capital_utilization                                          AS capital_utilization,
        macro.volume_tvl_ratio                                             AS volume_tvl_ratio,
        macro.lp_concentration_top10_pct                                   AS lp_concentration_top10_pct,
        macro.range_overlap_density                                        AS range_overlap_density,
        macro.range_width_median_ticks                                     AS range_width_median_ticks,
        macro.range_width_p25_ticks                                        AS range_width_p25_ticks,
        macro.range_width_p75_ticks                                        AS range_width_p75_ticks,
        toUInt64(coalesce(macro.open_range_count, 0))                      AS open_range_count,
        macro.apr_daily                                                    AS gross_fee_apr_daily,
        macro.apr_7d                                                       AS gross_fee_apr_7d,
        macro.apr_30d                                                      AS gross_fee_apr_30d,
        macro.apr_90d                                                      AS gross_fee_apr_90d,
        as_proxy.adverse_selection_cost_apr_proxy                          AS adverse_selection_cost_apr_proxy,
        as_proxy.adverse_selection_cost_apr_proxy_30d                      AS adverse_selection_cost_apr_proxy_30d,
        as_proxy.lvr_proxy_daily_token0                                    AS lvr_proxy_daily_token0,
        as_proxy.is_estimated                                              AS as_proxy_is_estimated
    FROM {{ ref('mart_tvl_daily') }} tvl
    LEFT JOIN {{ ref('mart_volume_daily') }} vol
        ON  tvl.pool = vol.pool
        AND tvl.date = vol.date
    LEFT JOIN {{ ref('int_active_tvl_daily') }} at
        ON  tvl.pool = at.pool
        AND tvl.date = at.date
    LEFT JOIN {{ ref('mart_price_analytics_daily') }} price
        ON  tvl.pool = price.pool
        AND tvl.date = price.date
    LEFT JOIN {{ ref('int_lp_macro_daily') }} macro
        ON  tvl.pool = macro.pool
        AND tvl.date = macro.date
    LEFT JOIN {{ ref('int_adverse_selection_proxy_daily') }} as_proxy
        ON  tvl.pool = as_proxy.pool
        AND tvl.date = as_proxy.date
),

-- ─── 3. Indexed-pool gate ─────────────────────────────────────────────────────
gated AS (
    SELECT
        s.*,
        d.chain,
        d.dex,
        d.token_pair,
        d.token0_symbol,
        d.token1_symbol,
        d.fee_tier
    FROM spine s
    INNER JOIN pool_dim d ON d.pool_address = s.pool
),

-- ─── 4. Rolling features (sums, returns, change deltas, drawdowns) ────────────
rolled AS (
    SELECT
        pool,
        date,
        chain,
        dex,
        token_pair,
        token0_symbol,
        token1_symbol,
        fee_tier,
        close_tick,
        close_price,
        has_swap,
        price_token1_in_token0,
        tvl_token0_equiv,
        active_tvl_token0,
        active_range_count,
        open_range_count,
        volume_token0_equiv,
        fees_token0_equiv,
        swap_count,
        capital_utilization,
        volume_tvl_ratio,
        lp_concentration_top10_pct,
        range_overlap_density,
        range_width_median_ticks,
        range_width_p25_ticks,
        range_width_p75_ticks,
        gross_fee_apr_daily,
        gross_fee_apr_7d,
        gross_fee_apr_30d,
        gross_fee_apr_90d,
        log_return,
        realized_vol_7d,
        realized_vol_30d,
        adverse_selection_cost_apr_proxy,
        adverse_selection_cost_apr_proxy_30d,
        lvr_proxy_daily_token0,
        as_proxy_is_estimated,

        -- Rolling sums for volume/fees windows. Coalesced inputs => zero contribution
        -- on quiet days, so trailing sums are exact.
        sum(volume_token0_equiv) OVER (
            PARTITION BY pool ORDER BY date ROWS BETWEEN 0 PRECEDING AND CURRENT ROW
        )                                                                  AS volume_24h_token0_equiv,
        sum(volume_token0_equiv) OVER (
            PARTITION BY pool ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        )                                                                  AS volume_7d_token0_equiv,
        sum(volume_token0_equiv) OVER (
            PARTITION BY pool ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
        )                                                                  AS volume_30d_token0_equiv,
        sum(fees_token0_equiv) OVER (
            PARTITION BY pool ORDER BY date ROWS BETWEEN 0 PRECEDING AND CURRENT ROW
        )                                                                  AS fees_24h_token0_equiv,
        sum(fees_token0_equiv) OVER (
            PARTITION BY pool ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        )                                                                  AS fees_7d_token0_equiv,
        sum(fees_token0_equiv) OVER (
            PARTITION BY pool ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
        )                                                                  AS fees_30d_token0_equiv,

        -- 7d-prior values for change deltas (NULL if not enough history).
        if(
            count() OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 7 PRECEDING AND CURRENT ROW) = 8,
            first_value(tvl_token0_equiv) OVER (
                PARTITION BY pool ORDER BY date ROWS BETWEEN 7 PRECEDING AND CURRENT ROW
            ),
            NULL
        )                                                                  AS tvl_token0_equiv_7d_ago,
        if(
            count() OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 13 PRECEDING AND 7 PRECEDING) = 7,
            sum(volume_token0_equiv) OVER (
                PARTITION BY pool ORDER BY date ROWS BETWEEN 13 PRECEDING AND 7 PRECEDING
            ),
            NULL
        )                                                                  AS volume_7d_prior_token0_equiv,
        if(
            count() OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 13 PRECEDING AND 7 PRECEDING) = 7,
            sum(fees_token0_equiv) OVER (
                PARTITION BY pool ORDER BY date ROWS BETWEEN 13 PRECEDING AND 7 PRECEDING
            ),
            NULL
        )                                                                  AS fees_7d_prior_token0_equiv,

        -- Price returns over fixed look-backs.
        if(
            count() OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 7 PRECEDING AND CURRENT ROW) = 8,
            first_value(close_price) OVER (
                PARTITION BY pool ORDER BY date ROWS BETWEEN 7 PRECEDING AND CURRENT ROW
            ),
            NULL
        )                                                                  AS close_price_7d_ago,
        if(
            count() OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 30 PRECEDING AND CURRENT ROW) = 31,
            first_value(close_price) OVER (
                PARTITION BY pool ORDER BY date ROWS BETWEEN 30 PRECEDING AND CURRENT ROW
            ),
            NULL
        )                                                                  AS close_price_30d_ago,

        -- Trailing N-day high (for window drawdowns).
        max(close_price) OVER (
            PARTITION BY pool ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        )                                                                  AS close_price_high_7d,
        max(close_price) OVER (
            PARTITION BY pool ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
        )                                                                  AS close_price_high_30d
    FROM gated
)

SELECT
    pool                                                                   AS pool_address,
    date,
    chain,
    dex,
    token_pair,
    token0_symbol,
    token1_symbol,
    fee_tier,

    -- ─── State ────────────────────────────────────────────────────────────────
    close_tick                                                             AS current_tick,
    close_price                                                            AS current_price,
    has_swap,

    -- ─── TVL ─────────────────────────────────────────────────────────────────
    tvl_token0_equiv,
    active_tvl_token0,
    greatest(tvl_token0_equiv - active_tvl_token0, 0.0)                    AS out_of_range_tvl_token0,
    capital_utilization,

    -- ─── Volume ──────────────────────────────────────────────────────────────
    volume_24h_token0_equiv,
    volume_7d_token0_equiv,
    volume_30d_token0_equiv,
    swap_count                                                             AS swap_count_24h,

    -- ─── Fees & APR ──────────────────────────────────────────────────────────
    fees_24h_token0_equiv,
    fees_7d_token0_equiv,
    fees_30d_token0_equiv,
    gross_fee_apr_daily,
    gross_fee_apr_7d                                                       AS gross_fee_apr,
    gross_fee_apr_30d,
    gross_fee_apr_90d,
    CAST(NULL AS Nullable(Float64))                                        AS incentive_apr,

    -- ─── Volatility ──────────────────────────────────────────────────────────
    realized_vol_7d,
    realized_vol_30d,

    -- ─── Adverse selection (LVR proxy) ───────────────────────────────────────
    adverse_selection_cost_apr_proxy,
    adverse_selection_cost_apr_proxy_30d,
    lvr_proxy_daily_token0,

    -- ─── Capital efficiency ──────────────────────────────────────────────────
    volume_tvl_ratio,
    if(active_tvl_token0 > 0, fees_24h_token0_equiv / active_tvl_token0, NULL) AS fees_per_active_tvl,

    -- ─── Population ──────────────────────────────────────────────────────────
    open_range_count                                                       AS position_count,
    CAST(NULL AS Nullable(UInt64))                                         AS lp_count,
    lp_concentration_top10_pct,
    -- Raw concentration score for the Python scorer. Larger = more concentrated.
    coalesce(lp_concentration_top10_pct, 0.0)                              AS liquidity_concentration_score_raw,

    -- ─── Range structure ─────────────────────────────────────────────────────
    range_width_median_ticks,
    range_width_p25_ticks,
    range_width_p75_ticks,
    range_overlap_density,

    -- ─── Returns ─────────────────────────────────────────────────────────────
    log_return                                                             AS log_return_daily,
    if(close_price_7d_ago > 0,  close_price / close_price_7d_ago  - 1.0, NULL) AS price_return_7d,
    if(close_price_30d_ago > 0, close_price / close_price_30d_ago - 1.0, NULL) AS price_return_30d,
    if(close_price_high_7d > 0,  close_price / close_price_high_7d  - 1.0, NULL) AS drawdown_7d,
    if(close_price_high_30d > 0, close_price / close_price_high_30d - 1.0, NULL) AS drawdown_30d,

    -- ─── Change deltas (% change over the trailing 7d step) ─────────────────
    if(tvl_token0_equiv_7d_ago > 0, tvl_token0_equiv / tvl_token0_equiv_7d_ago - 1.0, NULL) AS tvl_change_7d,
    if(volume_7d_prior_token0_equiv > 0, volume_7d_token0_equiv / volume_7d_prior_token0_equiv - 1.0, NULL) AS volume_change_7d,
    if(fees_7d_prior_token0_equiv > 0,   fees_7d_token0_equiv   / fees_7d_prior_token0_equiv   - 1.0, NULL) AS fees_change_7d,

    -- ─── Out-of-range penalty (ratio of OOR TVL to total) ───────────────────
    if(tvl_token0_equiv > 0,
       greatest(tvl_token0_equiv - active_tvl_token0, 0.0) / tvl_token0_equiv,
       NULL)                                                               AS out_of_range_penalty_raw,

    -- ─── Estimation flag ─────────────────────────────────────────────────────
    if(adverse_selection_cost_apr_proxy IS NOT NULL,
       toUInt8(1),
       toUInt8(0))                                                         AS is_estimated,

    now()                                                                  AS updated_at
FROM rolled
