{% set sigma_evc_start_hour = var('sigma_evc_start_hour', none) %}
{% set sigma_evc_end_hour = var('sigma_evc_end_hour', none) %}

{{ config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key=['pool', 'hour', 'tick'],
    order_by=['pool', 'hour', 'tick'],
    partition_by='toYYYYMM(hour)'
) }}

-- Hourly tick-level sigma_evc (implied volatility from LP fee revenue).
--
-- Volume(K) is an hourly flow, annualized by 8760. TickLiquidity is converted
-- to token0 equivalent TVL using V3 position math so that V/L is dimensionally
-- consistent (both in decimalized token0 units).
--
-- GRAIN         : 1 row per (pool, hour, tick)
-- DEPENDS ON    : int_tick_volume_hourly, int_hourly_tick_liquidity_net, stg_pools
-- INCREMENTAL   : refreshes the latest stored hour plus any newer hours
-- CHUNKING      : optional vars sigma_evc_start_hour / sigma_evc_end_hour

WITH incremental_cutoff AS (
    {% if is_incremental() %}
    SELECT addHours(coalesce(max(hour), toDateTime('1970-01-01 00:00:00')), -1) AS hour_cutoff
    FROM {{ this }}
    {% else %}
    SELECT toDateTime('1970-01-01 00:00:00') AS hour_cutoff
    {% endif %}
),

tick_ranges AS (
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
        ))                                                                       AS tick_liquidity_end
    FROM {{ ref('int_hourly_tick_liquidity_net') }}
    WHERE 1 = 1
      {% if sigma_evc_start_hour is not none %}
      AND hour >= toDateTime('{{ sigma_evc_start_hour }}')
      {% elif is_incremental() %}
      AND hour >= (SELECT hour_cutoff FROM incremental_cutoff)
      {% endif %}
      {% if sigma_evc_end_hour is not none %}
      AND hour <= toDateTime('{{ sigma_evc_end_hour }}')
      {% endif %}
),

volume_with_liquidity AS (
    SELECT
        v.pool,
        toDate(v.hour)                                                           AS date,
        v.hour,
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
    FROM {{ ref('int_tick_volume_hourly') }} v
    INNER JOIN tick_ranges r
        ON  v.pool = r.pool
        AND v.hour = r.hour
        AND v.tick >= r.tick_lower
        AND v.tick < r.tick_upper
    WHERE r.tick_upper IS NOT NULL
      AND r.tick_liquidity_end > 0
      {% if sigma_evc_start_hour is not none %}
      AND v.hour >= toDateTime('{{ sigma_evc_start_hour }}')
      {% elif is_incremental() %}
      AND v.hour >= (SELECT hour_cutoff FROM incremental_cutoff)
      {% endif %}
      {% if sigma_evc_end_hour is not none %}
      AND v.hour <= toDateTime('{{ sigma_evc_end_hour }}')
      {% endif %}
),

valued AS (
    SELECT
        vwl.*,
        p.fee_bps / 100.0                                                       AS fee_ratio,
        vwl.volume_token0_equiv * (24.0 * 365.0)                                AS volume_token0_equiv_annualized,
        -- TVL: decimalized token0 equivalent of raw tick liquidity
        {{ amount0_from_liquidity(
               'vwl.tick_liquidity_end',
               clamp_sqrt_price(
                   sqrt_price_at_tick('vwl.tick'),
                   'vwl.tick_lower',
                   'vwl.tick_upper'),
               sqrt_price_at_tick('vwl.tick_upper'),
               'p.token0_decimals'
           ) }}
        + {{ amount1_from_liquidity(
                 'vwl.tick_liquidity_end',
                 clamp_sqrt_price(
                     sqrt_price_at_tick('vwl.tick'),
                     'vwl.tick_lower',
                     'vwl.tick_upper'),
                 sqrt_price_at_tick('vwl.tick_lower'),
                 'p.token1_decimals'
             ) }}
          * pow(
              {{ clamp_sqrt_price(
                     sqrt_price_at_tick('vwl.tick'),
                     'vwl.tick_lower',
                     'vwl.tick_upper') }},
              2)
          * pow(10, toInt16(p.token0_decimals) - toInt16(p.token1_decimals))     AS tick_tvl_token0
    FROM volume_with_liquidity vwl
    INNER JOIN {{ ref('stg_pools') }} p ON vwl.pool = p.pool
)

SELECT
    pool,
    date,
    hour,
    tick,
    tick_lower,
    tick_upper,
    tick_liquidity_end,
    swap_count,
    fallback_after_swap_count,
    volume_token0,
    volume_token1,
    volume_token0_equiv,
    fees_generated_token0,
    fees_generated_token1,
    fees_generated_token0_equiv,
    fee_ratio,
    tick_tvl_token0,
    volume_token0_equiv_annualized,
    if(tick_tvl_token0 > 0,
        volume_token0_equiv_annualized / tick_tvl_token0,
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS volume_per_tick_liquidity_last,
    if(tick_tvl_token0 > 0,
        2.0 * fee_ratio * sqrt(greatest(
            volume_token0_equiv_annualized / tick_tvl_token0, 0.0
        )),
        CAST(NULL, 'Nullable(Float64)')
    )                                                                            AS sigma_evc_last
FROM valued
