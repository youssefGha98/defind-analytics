{% set sigma_evc_start_week = var('sigma_evc_start_week', none) %}
{% set sigma_evc_end_week = var('sigma_evc_end_week', none) %}

{{ config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key=['pool', 'week_start', 'tick'],
    order_by=['pool', 'tick', 'week_start'],
    partition_by='toYYYYMM(week_start)'
) }}

-- Weekly liquidityNet state at each LP tick boundary.
--
-- This keeps the last observed daily boundary snapshot of each calendar week.
-- Liquidity is a stock, so we take the latest weekly state instead of summing
-- or averaging boundary deltas across the week.
--
-- GRAIN         : 1 row per (pool, week_start, tick)
-- DEPENDS ON    : int_daily_tick_liquidity_net
-- WEEK SEMANTIC : calendar week starting Monday
-- CHUNKING      : optional vars sigma_evc_start_week / sigma_evc_end_week bound
--                 the rebuild window; otherwise the latest stored week is refreshed

WITH incremental_cutoff AS (
    {% if is_incremental() %}
    SELECT addWeeks(coalesce(max(week_start), toDate('1970-01-05')), -1) AS week_cutoff
    FROM {{ this }}
    {% else %}
    SELECT toDate('1970-01-05') AS week_cutoff
    {% endif %}
)

SELECT
    pool,
    toStartOfWeek(date, 1)                                                     AS week_start,
    tick,
    argMax(liquidity_net, date)                                                AS liquidity_net
FROM {{ ref('int_daily_tick_liquidity_net') }}
WHERE 1 = 1
  {% if sigma_evc_start_week is not none %}
  AND toStartOfWeek(date, 1) >= toDate('{{ sigma_evc_start_week }}')
  {% elif is_incremental() %}
  AND toStartOfWeek(date, 1) >= (SELECT week_cutoff FROM incremental_cutoff)
  {% endif %}
  {% if sigma_evc_end_week is not none %}
  AND toStartOfWeek(date, 1) <= toDate('{{ sigma_evc_end_week }}')
  {% endif %}
GROUP BY pool, toStartOfWeek(date, 1), tick
