{% macro tvl_snapshot_component_columns(
    total_expr,
    active_expr,
    out_of_range_expr,
    current_bin_alias='cb'
) -%}
coalesce({{ total_expr }}, 0.0)                                                   AS total_tvl_token0,
coalesce({{ active_expr }}, 0.0)                                                  AS active_tvl_token0,
coalesce({{ out_of_range_expr }}, 0.0)                                            AS out_of_range_tvl_token0,
if(
    abs(
        coalesce({{ total_expr }}, 0.0)
        - coalesce({{ active_expr }}, 0.0)
        - coalesce({{ out_of_range_expr }}, 0.0)
    ) < 1e-12,
    0.0,
    coalesce({{ total_expr }}, 0.0)
        - coalesce({{ active_expr }}, 0.0)
        - coalesce({{ out_of_range_expr }}, 0.0)
)                                                                                 AS tvl_reconciliation_gap,
{{ current_bin_alias }}.current_bin_tick_lower,
{{ current_bin_alias }}.current_bin_tick_upper,
coalesce({{ current_bin_alias }}.current_bin_liquidity, 0.0)                      AS current_bin_liquidity,
coalesce({{ current_bin_alias }}.current_bin_token0, 0.0)                         AS current_bin_token0,
coalesce({{ current_bin_alias }}.current_bin_token1, 0.0)                         AS current_bin_token1,
coalesce({{ current_bin_alias }}.current_bin_token0, 0.0)                         AS current_bin_token0_in_token0,
coalesce({{ current_bin_alias }}.current_bin_token1_in_token0, 0.0)               AS current_bin_token1_in_token0,
coalesce({{ current_bin_alias }}.current_bin_tvl_token0, 0.0)                     AS current_bin_tvl_token0
{%- endmacro %}
