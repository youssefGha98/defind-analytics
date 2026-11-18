-- Computes the normalized V3 square root price from a human-readable price.
-- Used in V3 TVL formulas (int_active_tvl_daily, mart_tvl_distribution).
--
-- Formula: sqrt(10^(token1_decimals - token0_decimals) / price_token1_in_token0)
-- Generic: token0_decimals and token1_decimals must be passed explicitly.
-- Previously hardcoded as sqrt(1e12 / price) which was specific to USDC/WETH (6 and 18 decimals).
{% macro sqrt_price_from_price(price_expr, token0_decimals_expr, token1_decimals_expr) -%}
sqrt(
    pow(10, toFloat64({{ token1_decimals_expr }} - {{ token0_decimals_expr }}))
    / toFloat64({{ price_expr }})
)
{%- endmacro %}

{% macro sqrt_price_at_tick(tick_expr) -%}
pow(1.0001, ({{ tick_expr }}) / 2.0)
{%- endmacro %}

{% macro clamp_sqrt_price(sqrt_price_expr, tick_lower_expr, tick_upper_expr) -%}
greatest(
    least({{ sqrt_price_expr }}, {{ sqrt_price_at_tick(tick_upper_expr) }}),
    {{ sqrt_price_at_tick(tick_lower_expr) }}
)
{%- endmacro %}

{% macro amount0_from_liquidity(liquidity_expr, sp_expr, sp_high_expr, decimals_expr) -%}
toFloat64({{ liquidity_expr }})
    * ({{ sp_high_expr }} - {{ sp_expr }})
    / ({{ sp_expr }} * {{ sp_high_expr }})
    / intExp10(toUInt8({{ decimals_expr }}))
{%- endmacro %}

{% macro amount1_from_liquidity(liquidity_expr, sp_expr, sp_low_expr, decimals_expr) -%}
toFloat64({{ liquidity_expr }})
    * ({{ sp_expr }} - {{ sp_low_expr }})
    / intExp10(toUInt8({{ decimals_expr }}))
{%- endmacro %}
