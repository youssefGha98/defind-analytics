{% set sigma_evc_start_week = var('sigma_evc_start_week', none) %}
{% set sigma_evc_end_week = var('sigma_evc_end_week', none) %}

{{ config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key=['pool', 'week_start', 'tick'],
    order_by=['pool', 'week_start', 'tick'],
    partition_by='toYYYYMM(week_start)'
) }}

-- Weekly tick-level sigma_evc with week-end and TWAP liquidity denominators.
--
-- Volume(K) is a weekly flow, annualized by 365/7. TickLiquidity is converted
-- to token0 equivalent TVL using V3 position math. Distribution statistics
-- (sigma_evc_mean / std / p95) are aggregated inline from the daily mart, so
-- the lineage stays mart→mart and we don't need an int that reads from a mart.
--
-- GRAIN         : 1 row per (pool, week_start, tick)
-- DEPENDS ON    : int_tick_volume_weekly, int_weekly_tick_liquidity_net,
--                 int_daily_tick_liquidity_net, mart_tick_liquidity_volume_daily, stg_pools
-- INCREMENTAL   : refreshes the latest stored week plus any newer weeks
-- CHUNKING      : optional vars sigma_evc_start_week / sigma_evc_end_week

{% set week_filter %}
    {% if sigma_evc_start_week is not none %}
    AND week_start >= toDate('{{ sigma_evc_start_week }}')
    {% elif is_incremental() %}
    AND week_start >= (SELECT week_cutoff FROM incremental_cutoff)
    {% endif %}
    {% if sigma_evc_end_week is not none %}
    AND week_start <= toDate('{{ sigma_evc_end_week }}')
    {% endif %}
{% endset %}

{% set week_filter_v %}
    {% if sigma_evc_start_week is not none %}
    AND v.week_start >= toDate('{{ sigma_evc_start_week }}')
    {% elif is_incremental() %}
    AND v.week_start >= (SELECT week_cutoff FROM incremental_cutoff)
    {% endif %}
    {% if sigma_evc_end_week is not none %}
    AND v.week_start <= toDate('{{ sigma_evc_end_week }}')
    {% endif %}
{% endset %}

{% set daily_filter %}
    {% if sigma_evc_start_week is not none %}
    AND toStartOfWeek(date, 1) >= toDate('{{ sigma_evc_start_week }}')
    {% elif is_incremental() %}
    AND toStartOfWeek(date, 1) >= (SELECT week_cutoff FROM incremental_cutoff)
    {% endif %}
    {% if sigma_evc_end_week is not none %}
    AND toStartOfWeek(date, 1) <= toDate('{{ sigma_evc_end_week }}')
    {% endif %}
{% endset %}

WITH incremental_cutoff AS (
    {% if is_incremental() %}
    SELECT addWeeks(coalesce(max(week_start), toDate('1970-01-05')), -1) AS week_cutoff
    FROM {{ this }}
    {% else %}
    SELECT toDate('1970-01-05') AS week_cutoff
    {% endif %}
),

tick_ranges AS (
    SELECT
        pool,
        week_start,
        tick                                                                     AS tick_lower,
        LEAD(tick) OVER (PARTITION BY pool, week_start ORDER BY tick)            AS tick_upper,
        toFloat64(greatest(
            sum(liquidity_net) OVER (
                PARTITION BY pool, week_start
                ORDER BY tick
                ROWS UNBOUNDED PRECEDING
            ),
            0
        ))                                                                       AS tick_liquidity_end
    FROM {{ ref('int_weekly_tick_liquidity_net') }}
    WHERE 1 = 1
      {{ week_filter }}
),

daily_tick_ranges AS (
    SELECT
        pool,
        date,
        tick                                                                     AS tick_lower,
        LEAD(tick) OVER (PARTITION BY pool, date ORDER BY tick)                  AS tick_upper,
        toFloat64(greatest(
            sum(liquidity_net) OVER (
                PARTITION BY pool, date
                ORDER BY tick
                ROWS UNBOUNDED PRECEDING
            ),
            0
        ))                                                                       AS tick_liquidity_daily
    FROM {{ ref('int_daily_tick_liquidity_net') }}
    WHERE 1 = 1
      {{ daily_filter }}
),

volume_with_liquidity AS (
    SELECT
        v.pool,
        v.week_start,
        v.tick,
        r.tick_lower,
        r.tick_upper,
        r.tick_liquidity_end,
        v.swap_count,
        v.fallback_after_swap_count,
        v.volume_token0,
        v.volume_token1,
        v.volume_token0_equiv,
        v.fees_generated_token0,
        v.fees_generated_token1,
        v.fees_generated_token0_equiv
    FROM {{ ref('int_tick_volume_weekly') }} v
    INNER JOIN tick_ranges r
        ON  v.pool = r.pool
        AND v.week_start = r.week_start
        AND v.tick >= r.tick_lower
        AND v.tick < r.tick_upper
    WHERE r.tick_upper IS NOT NULL
      AND r.tick_liquidity_end > 0
      {{ week_filter_v }}
),

daily_liquidity_twap AS (
    SELECT
        v.pool,
        v.week_start,
        v.tick,
        avg(r.tick_liquidity_daily)                                              AS tick_liquidity_twap
    FROM {{ ref('int_tick_volume_weekly') }} v
    INNER JOIN daily_tick_ranges r
        ON  v.pool = r.pool
        AND toStartOfWeek(r.date, 1) = v.week_start
        AND v.tick >= r.tick_lower
        AND v.tick < r.tick_upper
    WHERE r.tick_upper IS NOT NULL
      AND r.tick_liquidity_daily > 0
      {{ week_filter_v }}
    GROUP BY v.pool, v.week_start, v.tick
),

-- TVL computation: only 2-table JOIN (vwl + stg_pools)
-- ClickHouse 26.x cannot resolve columns from CTEs with 3+ table JOINs
{% set sp_clamped %}
    {{ clamp_sqrt_price(sqrt_price_at_tick('vwl.tick'), 'vwl.tick_lower', 'vwl.tick_upper') }}
{% endset %}

{% set price_t1_in_t0 %}
    pow({{ sp_clamped }}, 2) * pow(10, toInt16(p.token0_decimals) - toInt16(p.token1_decimals))
{% endset %}

valued AS (
    SELECT
        vwl.pool,
        vwl.week_start,
        vwl.tick,
        vwl.tick_lower,
        vwl.tick_upper,
        vwl.tick_liquidity_end,
        vwl.swap_count,
        vwl.fallback_after_swap_count,
        vwl.volume_token0,
        vwl.volume_token1,
        vwl.volume_token0_equiv,
        vwl.fees_generated_token0,
        vwl.fees_generated_token1,
        vwl.fees_generated_token0_equiv,
        p.fee_bps / 100.0                                                       AS fee_ratio,
        vwl.volume_token0_equiv * (365.0 / 7.0)                                 AS volume_token0_equiv_annualized,
        -- TVL from week-end liquidity snapshot
        {{ amount0_from_liquidity('vwl.tick_liquidity_end', sp_clamped,
               sqrt_price_at_tick('vwl.tick_upper'), 'p.token0_decimals') }}
        + {{ amount1_from_liquidity('vwl.tick_liquidity_end', sp_clamped,
                 sqrt_price_at_tick('vwl.tick_lower'), 'p.token1_decimals') }}
          * {{ price_t1_in_t0 }}                                                 AS tick_tvl_token0_last
    FROM volume_with_liquidity vwl
    INNER JOIN {{ ref('stg_pools') }} p ON vwl.pool = p.pool
)

-- Final SELECT: outer JOINs for TWAP liquidity and daily sigma stats
-- Kept outside valued CTE to avoid ClickHouse 26.x multi-join CTE bug
SELECT
    val.pool                                                                     AS pool,
    val.week_start                                                               AS week_start,
    val.tick                                                                     AS tick,
    val.tick_lower,
    val.tick_upper,
    val.tick_liquidity_end,
    dlt.tick_liquidity_twap,
    val.tick_tvl_token0_last,
    if(dlt.tick_liquidity_twap > 0 AND val.tick_liquidity_end > 0,
        val.tick_tvl_token0_last * (dlt.tick_liquidity_twap / val.tick_liquidity_end),
        0.0
    )                                                                            AS tick_tvl_token0_twap,
    val.swap_count,
    val.fallback_after_swap_count,
    val.volume_token0,
    val.volume_token1,
    val.volume_token0_equiv,
    val.fees_generated_token0,
    val.fees_generated_token1,
    val.fees_generated_token0_equiv,
    val.fee_ratio,
    val.volume_token0_equiv_annualized,
    if(val.tick_tvl_token0_last > 0,
        val.volume_token0_equiv_annualized / val.tick_tvl_token0_last,
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS volume_per_tick_liquidity_last,
    if(dlt.tick_liquidity_twap > 0
       AND val.tick_tvl_token0_last > 0
       AND val.tick_liquidity_end > 0,
        val.volume_token0_equiv_annualized
            / (val.tick_tvl_token0_last * (dlt.tick_liquidity_twap / val.tick_liquidity_end)),
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS volume_per_tick_liquidity_twap,
    if(val.tick_tvl_token0_last > 0,
        2.0 * val.fee_ratio * sqrt(greatest(
            val.volume_token0_equiv_annualized / val.tick_tvl_token0_last, 0.0)),
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS sigma_evc_last,
    if(dlt.tick_liquidity_twap > 0
       AND val.tick_tvl_token0_last > 0
       AND val.tick_liquidity_end > 0,
        2.0 * val.fee_ratio * sqrt(greatest(
            val.volume_token0_equiv_annualized
                / (val.tick_tvl_token0_last * (dlt.tick_liquidity_twap / val.tick_liquidity_end)),
            0.0)),
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS sigma_evc_twap,
    ds.sigma_evc_mean,
    ds.sigma_evc_std,
    ds.sigma_evc_p95
FROM valued val
LEFT JOIN daily_liquidity_twap dlt
    ON  val.pool = dlt.pool
    AND val.week_start = dlt.week_start
    AND val.tick = dlt.tick
LEFT JOIN (
    -- Inlined: weekly distribution stats over daily sigma_evc_last.
    -- Previously lived in int_tick_sigma_evc_daily_stats_weekly, but that
    -- intermediate read from a mart (mart_tick_liquidity_volume_daily),
    -- which violates dbt's int→mart layering. Folded into this mart so the
    -- dependency stays mart→mart.
    SELECT
        pool,
        toStartOfWeek(date, 1)                                              AS week_start,
        tick,
        avg(sigma_evc_last)                                                 AS sigma_evc_mean,
        if(
            count() > 1,
            stddevSamp(sigma_evc_last),
            CAST(NULL, 'Nullable(Float64)')
        )                                                                   AS sigma_evc_std,
        quantile(0.95)(sigma_evc_last)                                      AS sigma_evc_p95
    FROM {{ ref('mart_tick_liquidity_volume_daily') }}
    WHERE sigma_evc_last IS NOT NULL
      {{ daily_filter }}
    GROUP BY pool, toStartOfWeek(date, 1), tick
) ds
    ON  val.pool = ds.pool
    AND val.week_start = ds.week_start
    AND val.tick = ds.tick
