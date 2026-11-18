{% macro latest_swap_state_tuple(
    tick_expr='tick',
    price_expr='eth_price_usdc',
    block_expr='block_number',
    log_expr='log_index'
) -%}
argMax(
    tuple({{ tick_expr }}, {{ price_expr }}),
    tuple({{ block_expr }}, {{ log_expr }})
)
{%- endmacro %}

{% macro latest_by_block_log(
    value_expr,
    block_expr='block_number',
    log_expr='log_index'
) -%}
argMax(
    {{ value_expr }},
    tuple({{ block_expr }}, {{ log_expr }})
)
{%- endmacro %}

{% macro latest_swap_state_columns(
    source_alias='s',
    include_snapshot_keys=true,
    block_alias='snapshot_block_number',
    log_alias='snapshot_log_index',
    time_alias='snapshot_block_time',
    tick_alias='current_tick',
    price_alias='price_token1_in_token0',
    block_column='block_number',
    log_column='log_index',
    time_column='block_time',
    tick_column='tick',
    price_column='price_token1_in_token0'
) -%}
{%- set block_expr = source_alias ~ '.' ~ block_column -%}
{%- set log_expr = source_alias ~ '.' ~ log_column -%}
{%- if include_snapshot_keys %}
{{ latest_by_block_log(block_expr, block_expr, log_expr) }} AS {{ block_alias }},
{{ latest_by_block_log(log_expr, block_expr, log_expr) }} AS {{ log_alias }},
{{ latest_by_block_log(source_alias ~ '.' ~ time_column, block_expr, log_expr) }} AS {{ time_alias }},
{%- endif %}
{{ latest_by_block_log(source_alias ~ '.' ~ tick_column, block_expr, log_expr) }} AS {{ tick_alias }},
{{ latest_by_block_log(source_alias ~ '.' ~ price_column, block_expr, log_expr) }} AS {{ price_alias }}
{%- endmacro %}
