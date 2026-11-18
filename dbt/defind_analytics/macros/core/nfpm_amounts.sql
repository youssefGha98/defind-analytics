{% macro scale_raw_token_amount(raw_amount_expr, decimals_expr) -%}
toDecimal256({{ raw_amount_expr }}, 18)
    / toDecimal256(toString(intExp10({{ decimals_expr }})), 0)
{%- endmacro %}
