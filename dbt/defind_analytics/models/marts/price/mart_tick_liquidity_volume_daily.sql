{% set sigma_evc_start_date = var('sigma_evc_start_date', none) %}
{% set sigma_evc_end_date = var('sigma_evc_end_date', none) %}

{{ config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key=['pool', 'date', 'tick'],
    order_by=['pool', 'date', 'tick'],
    partition_by='toYYYYMM(date)'
) }}

-- Daily tick-level flow aligned with daily tick liquidity.
--
-- Volume(K) comes from swaps attributed to the active tick before execution.
-- TickLiquidity is converted to token0 equivalent TVL using V3 position math.
-- Daily sigma_evc variants:
--
--   - sigma_evc_last : day-end liquidity TVL
--   - sigma_evc_twap : mean hourly liquidity TVL over the day
--   - sigma_evc_mean/std/p95 : distribution of hourly sigma_evc_last values
--
-- GRAIN         : 1 row per (pool, date, tick)
-- DEPENDS ON    : int_tick_volume_daily, int_daily_tick_liquidity_net,
--                 int_hourly_tick_liquidity_net, mart_tick_sigma_evc_hourly, stg_pools
-- INCREMENTAL   : refreshes the latest stored day plus any newer days
-- CHUNKING      : optional vars sigma_evc_start_date / sigma_evc_end_date

{% set date_filter_daily %}
    {% if sigma_evc_start_date is not none %}
    AND date >= toDate('{{ sigma_evc_start_date }}')
    {% elif is_incremental() %}
    AND date >= (SELECT date_cutoff FROM incremental_cutoff)
    {% endif %}
    {% if sigma_evc_end_date is not none %}
    AND date <= toDate('{{ sigma_evc_end_date }}')
    {% endif %}
{% endset %}

{% set date_filter_daily_v %}
    {% if sigma_evc_start_date is not none %}
    AND v.date >= toDate('{{ sigma_evc_start_date }}')
    {% elif is_incremental() %}
    AND v.date >= (SELECT date_cutoff FROM incremental_cutoff)
    {% endif %}
    {% if sigma_evc_end_date is not none %}
    AND v.date <= toDate('{{ sigma_evc_end_date }}')
    {% endif %}
{% endset %}

{% set date_filter_hourly %}
    {% if sigma_evc_start_date is not none %}
    AND toDate(hour) >= toDate('{{ sigma_evc_start_date }}')
    {% elif is_incremental() %}
    AND toDate(hour) >= (SELECT date_cutoff FROM incremental_cutoff)
    {% endif %}
    {% if sigma_evc_end_date is not none %}
    AND toDate(hour) <= toDate('{{ sigma_evc_end_date }}')
    {% endif %}
{% endset %}

WITH incremental_cutoff AS (
    {% if is_incremental() %}
    SELECT addDays(coalesce(max(date), toDate('1970-01-01')), -1) AS date_cutoff
    FROM {{ this }}
    {% else %}
    SELECT toDate('1970-01-01') AS date_cutoff
    {% endif %}
),

tick_ranges AS (
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
        ))                                                                       AS tick_liquidity
    FROM {{ ref('int_daily_tick_liquidity_net') }}
    WHERE 1 = 1
      {{ date_filter_daily }}
),

hourly_tick_ranges AS (
    SELECT
        pool,
        hour,
        tick                                                                     AS tick_lower,
        LEAD(tick) OVER (PARTITION BY pool, hour ORDER BY tick)                  AS tick_upper,
        toFloat64(greatest(
            sum(liquidity_net) OVER (
                PARTITION BY pool, hour
                ORDER BY tick
                ROWS UNBOUNDED PRECEDING
            ),
            0
        ))                                                                       AS tick_liquidity_hourly
    FROM {{ ref('int_hourly_tick_liquidity_net') }}
    WHERE 1 = 1
      {{ date_filter_hourly }}
),

volume_with_liquidity AS (
    SELECT
        v.pool,
        v.date,
        v.tick,
        r.tick_lower,
        r.tick_upper,
        r.tick_liquidity,
        v.swap_count,
        v.fallback_after_swap_count,
        v.volume_token0,
        v.volume_token1,
        v.volume_token0_equiv,
        v.fees_generated_token0,
        v.fees_generated_token1,
        v.fees_generated_token0_equiv
    FROM {{ ref('int_tick_volume_daily') }} v
    INNER JOIN tick_ranges r
        ON  v.pool = r.pool
        AND v.date = r.date
        AND v.tick >= r.tick_lower
        AND v.tick < r.tick_upper
    WHERE r.tick_upper IS NOT NULL
      AND r.tick_liquidity > 0
      {{ date_filter_daily_v }}
),

hourly_liquidity_twap AS (
    SELECT
        v.pool,
        v.date,
        v.tick,
        avg(r.tick_liquidity_hourly)                                             AS tick_liquidity_twap
    FROM {{ ref('int_tick_volume_daily') }} v
    INNER JOIN hourly_tick_ranges r
        ON  v.pool = r.pool
        AND v.date = toDate(r.hour)
        AND v.tick >= r.tick_lower
        AND v.tick < r.tick_upper
    WHERE r.tick_upper IS NOT NULL
      AND r.tick_liquidity_hourly > 0
      {{ date_filter_daily_v }}
    GROUP BY v.pool, v.date, v.tick
),

hourly_sigma AS (
    SELECT
        pool,
        toDate(hour)                                                             AS date,
        tick,
        avg(sigma_evc_last)                                                      AS sigma_evc_mean,
        if(count() > 1,
            stddevSamp(sigma_evc_last),
            CAST(NULL, 'Nullable(Float64)')
        )                                                                        AS sigma_evc_std,
        quantile(0.95)(sigma_evc_last)                                           AS sigma_evc_p95
    FROM {{ ref('mart_tick_sigma_evc_hourly') }}
    WHERE sigma_evc_last IS NOT NULL
      {{ date_filter_hourly }}
    GROUP BY pool, toDate(hour), tick
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
        vwl.date,
        vwl.tick,
        vwl.tick_lower,
        vwl.tick_upper,
        vwl.tick_liquidity,
        vwl.swap_count,
        vwl.fallback_after_swap_count,
        vwl.volume_token0,
        vwl.volume_token1,
        vwl.volume_token0_equiv,
        vwl.fees_generated_token0,
        vwl.fees_generated_token1,
        vwl.fees_generated_token0_equiv,
        p.fee_bps / 100.0                                                       AS fee_ratio,
        vwl.volume_token0_equiv * 365.0                                          AS volume_token0_equiv_annualized,
        -- TVL from day-end liquidity snapshot
        {{ amount0_from_liquidity('vwl.tick_liquidity', sp_clamped,
               sqrt_price_at_tick('vwl.tick_upper'), 'p.token0_decimals') }}
        + {{ amount1_from_liquidity('vwl.tick_liquidity', sp_clamped,
                 sqrt_price_at_tick('vwl.tick_lower'), 'p.token1_decimals') }}
          * {{ price_t1_in_t0 }}                                                 AS tick_tvl_token0_last
    FROM volume_with_liquidity vwl
    INNER JOIN {{ ref('stg_pools') }} p ON vwl.pool = p.pool
)

-- Final SELECT: outer JOINs for TWAP liquidity and hourly sigma stats
SELECT
    val.pool                                                                     AS pool,
    val.date                                                                     AS date,
    val.tick                                                                     AS tick,
    val.tick_lower,
    val.tick_upper,
    val.tick_liquidity                                                           AS tick_liquidity_end,
    hlt.tick_liquidity_twap,
    val.tick_tvl_token0_last,
    if(hlt.tick_liquidity_twap > 0,
        val.tick_tvl_token0_last * (hlt.tick_liquidity_twap / val.tick_liquidity),
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
    if(hlt.tick_liquidity_twap > 0
       AND val.tick_tvl_token0_last > 0
       AND val.tick_liquidity > 0,
        val.volume_token0_equiv_annualized
            / (val.tick_tvl_token0_last * (hlt.tick_liquidity_twap / val.tick_liquidity)),
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS volume_per_tick_liquidity_twap,
    if(val.tick_tvl_token0_last > 0,
        2.0 * val.fee_ratio * sqrt(greatest(
            val.volume_token0_equiv_annualized / val.tick_tvl_token0_last, 0.0)),
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS sigma_evc_last,
    if(hlt.tick_liquidity_twap > 0
       AND val.tick_tvl_token0_last > 0
       AND val.tick_liquidity > 0,
        2.0 * val.fee_ratio * sqrt(greatest(
            val.volume_token0_equiv_annualized
                / (val.tick_tvl_token0_last * (hlt.tick_liquidity_twap / val.tick_liquidity)),
            0.0)),
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS sigma_evc_twap,
    hs.sigma_evc_mean,
    hs.sigma_evc_std,
    hs.sigma_evc_p95
FROM valued val
LEFT JOIN hourly_liquidity_twap hlt
    ON  val.pool = hlt.pool
    AND val.date = hlt.date
    AND val.tick = hlt.tick
LEFT JOIN hourly_sigma hs
    ON  val.pool = hs.pool
    AND val.date = hs.date
    AND val.tick = hs.tick
