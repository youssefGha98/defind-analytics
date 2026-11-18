-- Pool analytics snapshot — 1 row per indexed pool, latest state.
--
-- Powers the Pool Analytics page (header, capital efficiency block, microstructure
-- block, pool context). Builds on mart_pool_screener_daily for everything that is
-- already a daily aggregate, then overrides current_tick/current_price with the
-- truly latest swap state from int_current_state and counts open positions/owners
-- from mart_nfpm_open_positions_current.
--
-- No score, no decision label, no recommendation text — Python owns those.
--
-- GRAIN         : 1 row per pool
-- DEPENDS ON    : mart_pool_screener_daily, dim_indexed_pools, int_current_state,
--                 mart_nfpm_open_positions_current
-- KEY DECISIONS :
--   - We pick the latest screener row by (date) per pool. Daily-grain change deltas
--     are passed through as-is.
--   - lp_count = unique current_owner across open NFPM positions on the pool.
--     position_count = number of open NFPM tokenIds on the pool.
--     These are NFPM-only — the pool may also have non-NFPM ranges, which are
--     covered by position_count_open_ranges (= screener.position_count).
--   - snapshot_time = now() at build time.

{{ config(materialized='table') }}

WITH

-- Latest screener row per pool. The (pool, max_date) IN ... pattern is used
-- here instead of `SELECT *, row_number() OVER (...) WHERE rn=1` because
-- ClickHouse 26.x analyzer leaks internal column suffixes (.null, .size)
-- through that pattern when downstream re-aliases the result.
latest_dates AS (
    SELECT pool_address, max(date) AS max_date
    FROM {{ ref('mart_pool_screener_daily') }}
    GROUP BY pool_address
),

latest_screener AS (
    SELECT s.*
    FROM {{ ref('mart_pool_screener_daily') }} s
    INNER JOIN latest_dates ld
        ON  s.pool_address = ld.pool_address
        AND s.date         = ld.max_date
),

live_state AS (
    SELECT
        pool                       AS pool_address,
        current_tick               AS live_current_tick,
        price_token1_in_token0     AS live_current_price
    FROM {{ ref('int_current_state') }}
),

nfpm_population AS (
    SELECT
        pool                       AS pool_address,
        countDistinct(current_owner) AS lp_count_nfpm,
        count()                      AS position_count_nfpm
    FROM {{ ref('mart_nfpm_open_positions_current') }}
    GROUP BY pool
)

SELECT
    s.pool_address                                                         AS pool_address,
    now()                                                                  AS snapshot_time,
    s.chain                                                                AS chain,
    s.dex                                                                  AS dex,
    s.token_pair                                                           AS token_pair,
    s.token0_symbol                                                        AS token0_symbol,
    s.token1_symbol                                                        AS token1_symbol,
    s.fee_tier                                                             AS fee_tier,

    -- ─── Live state (not daily close) ───────────────────────────────────────
    coalesce(ls.live_current_tick,  s.current_tick)                        AS current_tick,
    coalesce(ls.live_current_price, s.current_price)                       AS current_price,

    -- ─── TVL ────────────────────────────────────────────────────────────────
    s.tvl_token0_equiv                                                     AS tvl_token0_equiv,
    s.active_tvl_token0                                                    AS active_tvl_token0,
    s.out_of_range_tvl_token0                                              AS out_of_range_tvl_token0,
    s.capital_utilization                                                  AS capital_utilization,

    -- ─── Volume / Fees ──────────────────────────────────────────────────────
    s.volume_24h_token0_equiv                                              AS volume_24h_token0_equiv,
    s.volume_7d_token0_equiv                                               AS volume_7d_token0_equiv,
    s.volume_30d_token0_equiv                                              AS volume_30d_token0_equiv,
    s.fees_24h_token0_equiv                                                AS fees_24h_token0_equiv,
    s.fees_7d_token0_equiv                                                 AS fees_7d_token0_equiv,
    s.fees_30d_token0_equiv                                                AS fees_30d_token0_equiv,
    s.swap_count_24h                                                       AS swap_count_24h,

    -- ─── APR ────────────────────────────────────────────────────────────────
    s.gross_fee_apr                                                        AS gross_fee_apr,
    s.gross_fee_apr_30d                                                    AS gross_fee_apr_30d,
    s.gross_fee_apr_90d                                                    AS gross_fee_apr_90d,
    s.incentive_apr                                                        AS incentive_apr,

    -- ─── Volatility / Adverse selection ─────────────────────────────────────
    s.realized_vol_7d                                                      AS realized_vol_7d,
    s.realized_vol_30d                                                     AS realized_vol_30d,
    s.adverse_selection_cost_apr_proxy                                     AS adverse_selection_cost_apr_proxy,
    s.adverse_selection_cost_apr_proxy_30d                                 AS adverse_selection_cost_apr_proxy_30d,
    s.lvr_proxy_daily_token0                                               AS lvr_proxy_daily_token0,
    CAST(NULL AS Nullable(Float64))                                        AS gas_cost_apr_proxy,

    -- ─── Capital efficiency ─────────────────────────────────────────────────
    s.volume_tvl_ratio                                                     AS volume_tvl_ratio,
    s.fees_per_active_tvl                                                  AS fees_per_active_tvl,

    -- ─── Population ─────────────────────────────────────────────────────────
    coalesce(np.lp_count_nfpm, 0)                                          AS lp_count,
    coalesce(np.position_count_nfpm, 0)                                    AS position_count,
    s.position_count                                                       AS open_range_count,
    s.lp_concentration_top10_pct                                           AS lp_concentration_top10_pct,
    s.liquidity_concentration_score_raw                                    AS liquidity_concentration_score_raw,

    -- ─── Range structure ────────────────────────────────────────────────────
    s.range_width_median_ticks                                             AS range_width_median_ticks,
    s.range_width_p25_ticks                                                AS range_width_p25_ticks,
    s.range_width_p75_ticks                                                AS range_width_p75_ticks,
    s.range_overlap_density                                                AS range_overlap_density,

    -- ─── Returns / change deltas ────────────────────────────────────────────
    s.price_return_7d                                                      AS price_return_7d,
    s.price_return_30d                                                     AS price_return_30d,
    s.drawdown_7d                                                          AS drawdown_7d,
    s.drawdown_30d                                                         AS drawdown_30d,
    s.tvl_change_7d                                                        AS tvl_change_7d,
    s.volume_change_7d                                                     AS volume_change_7d,
    s.fees_change_7d                                                       AS fees_change_7d,
    s.out_of_range_penalty_raw                                             AS out_of_range_penalty_raw,

    -- ─── Estimation flag ────────────────────────────────────────────────────
    s.is_estimated                                                         AS is_estimated,

    now()                                                                  AS updated_at
FROM latest_screener s
LEFT JOIN live_state ls       ON ls.pool_address = s.pool_address
LEFT JOIN nfpm_population np  ON np.pool_address = s.pool_address
