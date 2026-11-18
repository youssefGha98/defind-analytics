{% macro is_range_active(tick_expr, tick_lower_expr, tick_upper_expr) -%}
(
    {{ tick_lower_expr }} <= {{ tick_expr }}
    AND {{ tick_expr }} < {{ tick_upper_expr }}
)
{%- endmacro %}

{% macro position_status_from_tick(tick_expr, tick_lower_expr, tick_upper_expr) -%}
multiIf(
    {{ tick_expr }} < {{ tick_lower_expr }}, 'below_range',
    {{ tick_expr }} >= {{ tick_upper_expr }}, 'above_range',
    'in_range'
)
{%- endmacro %}

{% macro position_amount0_at_price(
    liquidity_expr,
    price_expr,
    tick_lower_expr,
    tick_upper_expr,
    token0_decimals_expr,
    token1_decimals_expr
) -%}
{{
    amount0_from_liquidity(
        liquidity_expr,
        clamp_sqrt_price(
            sqrt_price_from_price(price_expr, token0_decimals_expr, token1_decimals_expr),
            tick_lower_expr,
            tick_upper_expr
        ),
        sqrt_price_at_tick(tick_upper_expr),
        token0_decimals_expr
    )
}}
{%- endmacro %}

{% macro position_amount1_at_price(
    liquidity_expr,
    price_expr,
    tick_lower_expr,
    tick_upper_expr,
    token0_decimals_expr,
    token1_decimals_expr
) -%}
{{
    amount1_from_liquidity(
        liquidity_expr,
        clamp_sqrt_price(
            sqrt_price_from_price(price_expr, token0_decimals_expr, token1_decimals_expr),
            tick_lower_expr,
            tick_upper_expr
        ),
        sqrt_price_at_tick(tick_lower_expr),
        token1_decimals_expr
    )
}}
{%- endmacro %}

{% macro position_value_token0_at_price(
    liquidity_expr,
    price_expr,
    tick_lower_expr,
    tick_upper_expr,
    token0_decimals_expr,
    token1_decimals_expr
) -%}
(
    {{
        position_amount0_at_price(
            liquidity_expr,
            price_expr,
            tick_lower_expr,
            tick_upper_expr,
            token0_decimals_expr,
            token1_decimals_expr
        )
    }}
    + {{
        position_amount1_at_price(
            liquidity_expr,
            price_expr,
            tick_lower_expr,
            tick_upper_expr,
            token0_decimals_expr,
            token1_decimals_expr
        )
    }} * toFloat64({{ price_expr }})
)
{%- endmacro %}
