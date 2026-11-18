{% macro get_fixture_sql(rows, column_name_to_data_types) %}
-- Fixture for {{ model.name }}
{% set default_row = {} %}
{% set column_name_to_quoted = {} %}

{%- if not column_name_to_data_types -%}
{#-- Use defer_relation IFF it is available in the manifest and 'this' is missing from the database --#}
{%-   set this_or_defer_relation = defer_relation if (defer_relation and not load_relation(this)) else this -%}
{%-   set columns_in_relation = adapter.get_columns_in_relation(this_or_defer_relation) -%}

{%-   set column_name_to_data_types = {} -%}
{%-   for column in columns_in_relation -%}
{#-- This needs to be a case-insensitive comparison --#}
{%-     do column_name_to_data_types.update({column.name|lower: column.data_type}) -%}
{%-     do column_name_to_quoted.update({column.name|lower: column.quoted}) -%}
{%-   endfor -%}

{#-- Unit tests may mock a new model before any physical relation exists. --#}
{%-   if not column_name_to_data_types and model.name == 'int_range_liquidity_daily' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'date': 'Date',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'net_liquidity': 'Int128'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_tick_boundary_deltas' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'block_number': 'UInt64',
            'block_time': 'DateTime',
            'tx_hash': 'String',
            'log_index': 'UInt64',
            'tick_boundary': 'Int32',
            'liquidity_net_delta': 'Int128',
            'boundary_side': 'String'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_weekly_tick_liquidity_net' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'week_start': 'Date',
            'tick': 'Int32',
            'liquidity_net': 'Int128'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_daily_close_dense' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'date': 'Date',
            'close_tick': 'Int32',
            'close_price': 'Float64',
            'close_sqrt_price': 'Float64',
            'has_swap': 'UInt8'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_fee_per_100_usd' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'date': 'Date',
            'range_width_ticks': 'Int32',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'close_price': 'Float64',
            'close_tick': 'Int32',
            'active_liquidity': 'Float64',
            'active_tvl_token0': 'Float64',
            'tvl_per_unit_L': 'Float64',
            'fee_per_100_token0_daily': 'Float64',
            'fee_per_100_token0_annual': 'Float64',
            'fee_per_100_token0_7d': 'Float64',
            'fee_per_100_token0_30d': 'Float64',
            'fee_per_100_token0_90d': 'Float64',
            'fee_bps_annual': 'Float64',
            'fee_bps_7d': 'Float64',
            'fee_bps_30d': 'Float64',
            'fee_bps_90d': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_lp_macro_daily' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'date': 'Date',
            'close_price': 'Float64',
            'close_tick': 'Int32',
            'tvl_token0_equiv': 'Float64',
            'active_tvl_token0': 'Float64',
            'active_range_count': 'UInt64',
            'fees_token0_equiv': 'Float64',
            'volume_token0_equiv': 'Float64',
            'swap_count': 'UInt64',
            'capital_utilization': 'Float64',
            'volume_tvl_ratio': 'Float64',
            'active_liquidity_depth': 'Float64',
            'log_return': 'Float64',
            'realized_vol_7d': 'Float64',
            'realized_vol_30d': 'Float64',
            'apr_daily': 'Float64',
            'apr_7d': 'Float64',
            'apr_30d': 'Float64',
            'apr_90d': 'Float64',
            'apr7_vol_ratio': 'Float64',
            'coupon_vol_ratio_500': 'Float64',
            'mint_count': 'UInt64',
            'burn_count': 'UInt64',
            'mint_token0': 'Float64',
            'burn_token0': 'Float64',
            'net_lp_flow_token0': 'Float64',
            'lp_turnover': 'Float64',
            'burns_inrange_count': 'UInt64',
            'burns_outofrange_count': 'UInt64',
            'burns_inrange_token0': 'Float64',
            'burns_outofrange_token0': 'Float64',
            'pct_burns_inrange': 'Float64',
            'open_range_count': 'UInt64',
            'range_width_median_ticks': 'Float64',
            'range_width_p25_ticks': 'Float64',
            'range_width_p75_ticks': 'Float64',
            'lp_concentration_top10_pct': 'Float64',
            'range_overlap_density': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'mart_tick_liquidity_volume_daily' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'date': 'Date',
            'tick': 'Int32',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'tick_liquidity_end': 'Float64',
            'tick_liquidity_twap': 'Float64',
            'tick_liquidity': 'Float64',
            'swap_count': 'UInt64',
            'fallback_after_swap_count': 'UInt64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64',
            'fee_ratio': 'Float64',
            'volume_token0_equiv_annualized': 'Float64',
            'volume_per_tick_liquidity_last': 'Float64',
            'volume_per_tick_liquidity_twap': 'Float64',
            'sigma_evc_last': 'Float64',
            'sigma_evc_twap': 'Float64',
            'sigma_evc_mean': 'Float64',
            'sigma_evc_std': 'Float64',
            'sigma_evc_p95': 'Float64',
            'volume_per_tick_liquidity': 'Float64',
            'sigma_evc': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'mart_tick_sigma_evc_hourly' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'date': 'Date',
            'hour': 'DateTime',
            'tick': 'Int32',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'tick_liquidity_end': 'Float64',
            'swap_count': 'UInt64',
            'fallback_after_swap_count': 'UInt64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64',
            'fee_ratio': 'Float64',
            'volume_token0_equiv_annualized': 'Float64',
            'volume_per_tick_liquidity_last': 'Float64',
            'sigma_evc_last': 'Float64',
            'sigma_evc': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'mart_tick_sigma_evc_weekly' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'week_start': 'Date',
            'tick': 'Int32',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'tick_liquidity_end': 'Float64',
            'tick_liquidity_twap': 'Float64',
            'swap_count': 'UInt64',
            'fallback_after_swap_count': 'UInt64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64',
            'fee_ratio': 'Float64',
            'volume_token0_equiv_annualized': 'Float64',
            'volume_per_tick_liquidity_last': 'Float64',
            'volume_per_tick_liquidity_twap': 'Float64',
            'sigma_evc_last': 'Float64',
            'sigma_evc_twap': 'Float64',
            'sigma_evc_mean': 'Float64',
            'sigma_evc_std': 'Float64',
            'sigma_evc_p95': 'Float64',
            'sigma_evc': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_position_backtest_entry_state' -%}
{%-     set column_name_to_data_types = {
            'scenario_id': 'String',
            'pool': 'String',
            'start_block': 'UInt64',
            'end_block': 'UInt64',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'capital_committed_token0': 'Float64',
            'rebalance_policy': 'String',
            'tick_spacing': 'UInt32',
            'token0_decimals': 'UInt8',
            'token1_decimals': 'UInt8',
            'start_snapshot_block_number': 'UInt64',
            'start_snapshot_log_index': 'UInt64',
            'start_snapshot_block_time': 'DateTime',
            'start_tick': 'Int32',
            'start_price': 'Float64',
            'start_sqrt_price': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_position_backtest_entry_liquidity' -%}
{%-     set column_name_to_data_types = {
            'scenario_id': 'String',
            'pool': 'String',
            'start_block': 'UInt64',
            'end_block': 'UInt64',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'capital_committed_token0': 'Float64',
            'rebalance_policy': 'String',
            'tick_spacing': 'UInt32',
            'token0_decimals': 'UInt8',
            'token1_decimals': 'UInt8',
            'start_snapshot_block_number': 'UInt64',
            'start_snapshot_log_index': 'UInt64',
            'start_snapshot_block_time': 'DateTime',
            'start_tick': 'Int32',
            'start_price': 'Float64',
            'start_sqrt_price': 'Float64',
            'start_position_status': 'String',
            'unit_amount0': 'Float64',
            'unit_amount1': 'Float64',
            'unit_position_value_token0': 'Float64',
            'initial_liquidity': 'Float64',
            'initial_amount0': 'Float64',
            'initial_amount1': 'Float64',
            'initial_principal_value_token0': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_swaps_enriched' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'block_number': 'UInt64',
            'log_index': 'UInt64',
            'block_time': 'DateTime',
            'tick_before': 'Int32',
            'price_before': 'Float64',
            'tick_after': 'Int32',
            'price_after': 'Float64',
            'next_block_time': 'DateTime',
            'active_liquidity_at_swap': 'Float64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'token0_in': 'Float64',
            'token1_in': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_swaps_tick_volume' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'block_number': 'UInt64',
            'log_index': 'UInt64',
            'block_time': 'DateTime',
            'active_tick': 'Int32',
            'fallback_after_swap': 'UInt8',
            'tick_before': 'Int32',
            'tick_after': 'Int32',
            'active_price_token1_in_token0': 'Float64',
            'price_before': 'Float64',
            'price_after': 'Float64',
            'active_liquidity_at_swap': 'Float64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'token0_in': 'Float64',
            'token1_in': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_tick_volume_daily' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'date': 'Date',
            'tick': 'Int32',
            'swap_count': 'UInt64',
            'fallback_after_swap_count': 'UInt64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_tick_volume_5m' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'bucket_5m': 'DateTime',
            'tick': 'Int32',
            'swap_count': 'UInt64',
            'fallback_after_swap_count': 'UInt64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_tick_volume_hourly' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'hour': 'DateTime',
            'tick': 'Int32',
            'swap_count': 'UInt64',
            'fallback_after_swap_count': 'UInt64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_tick_volume_weekly' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'week_start': 'Date',
            'tick': 'Int32',
            'swap_count': 'UInt64',
            'fallback_after_swap_count': 'UInt64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_tick_volume_state_changes' -%}
{%-     set column_name_to_data_types = {
            'pool': 'String',
            'session_id': 'UInt64',
            'tick': 'Int32',
            'start_block': 'UInt64',
            'start_log_index': 'UInt64',
            'start_time': 'DateTime',
            'start_price_token1_in_token0': 'Float64',
            'last_swap_block': 'UInt64',
            'last_swap_log_index': 'UInt64',
            'last_swap_time': 'DateTime',
            'last_price_token1_in_token0': 'Float64',
            'end_block': 'UInt64',
            'end_log_index': 'UInt64',
            'end_time': 'DateTime',
            'duration_seconds': 'UInt64',
            'next_tick': 'Int32',
            'direction': 'String',
            'swap_count': 'UInt64',
            'fallback_after_swap_count': 'UInt64',
            'volume_token0': 'Float64',
            'volume_token1': 'Float64',
            'volume_token0_equiv': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_position_backtest_swap_path' -%}
{%-     set column_name_to_data_types = {
            'scenario_id': 'String',
            'pool': 'String',
            'start_block': 'UInt64',
            'end_block': 'UInt64',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'block_number': 'UInt64',
            'log_index': 'UInt64',
            'block_time': 'DateTime',
            'tick_before': 'Int32',
            'price_before': 'Float64',
            'tick_after': 'Int32',
            'price_after': 'Float64',
            'active_liquidity_at_swap': 'Float64',
            'fees_generated_token0': 'Float64',
            'fees_generated_token1': 'Float64',
            'fees_generated_token0_equiv': 'Float64',
            'initial_liquidity': 'Float64',
            'is_active_before_swap': 'UInt8',
            'position_fee_share': 'Float64',
            'fees_accrued_token0': 'Float64',
            'fees_accrued_token1': 'Float64',
            'fees_accrued_token0_equiv_generated': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_position_backtest_exit_state' -%}
{%-     set column_name_to_data_types = {
            'scenario_id': 'String',
            'pool': 'String',
            'start_block': 'UInt64',
            'end_block': 'UInt64',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'capital_committed_token0': 'Float64',
            'rebalance_policy': 'String',
            'tick_spacing': 'UInt32',
            'token0_decimals': 'UInt8',
            'token1_decimals': 'UInt8',
            'start_snapshot_block_number': 'UInt64',
            'start_snapshot_log_index': 'UInt64',
            'start_snapshot_block_time': 'DateTime',
            'start_tick': 'Int32',
            'start_price': 'Float64',
            'start_sqrt_price': 'Float64',
            'start_position_status': 'String',
            'initial_liquidity': 'Float64',
            'initial_amount0': 'Float64',
            'initial_amount1': 'Float64',
            'end_snapshot_block_number': 'UInt64',
            'end_snapshot_log_index': 'UInt64',
            'end_snapshot_block_time': 'DateTime',
            'end_tick': 'Int32',
            'end_price': 'Float64',
            'end_sqrt_price': 'Float64',
            'end_position_status': 'String',
            'end_amount0': 'Float64',
            'end_amount1': 'Float64',
            'end_principal_value_token0': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'int_position_backtest_time_in_range' -%}
{%-     set column_name_to_data_types = {
            'scenario_id': 'String',
            'pool': 'String',
            'start_block': 'UInt64',
            'end_block': 'UInt64',
            'resolved_start_time': 'DateTime',
            'resolved_end_time': 'DateTime',
            'observed_time_in_range_seconds': 'UInt64',
            'observed_window_seconds': 'UInt64',
            'observed_out_of_range_seconds': 'UInt64',
            'observed_time_in_range_pct': 'Float64',
            'observed_out_of_range_pct': 'Float64'
        } -%}
{%-   elif not column_name_to_data_types and model.name == 'mart_position_backtest_summary' -%}
{%-     set column_name_to_data_types = {
            'scenario_id': 'String',
            'pool': 'String',
            'start_block': 'UInt64',
            'end_block': 'UInt64',
            'tick_lower': 'Int32',
            'tick_upper': 'Int32',
            'capital_committed_token0': 'Float64',
            'rebalance_policy': 'String',
            'start_snapshot_block_number': 'UInt64',
            'start_snapshot_log_index': 'UInt64',
            'start_snapshot_block_time': 'DateTime',
            'start_tick': 'Int32',
            'start_price': 'Float64',
            'start_position_status': 'String',
            'initial_liquidity': 'Float64',
            'initial_amount0': 'Float64',
            'initial_amount1': 'Float64',
            'initial_principal_value_token0': 'Float64',
            'end_snapshot_block_number': 'UInt64',
            'end_snapshot_log_index': 'UInt64',
            'end_snapshot_block_time': 'DateTime',
            'end_tick': 'Int32',
            'end_price': 'Float64',
            'end_position_status': 'String',
            'end_amount0': 'Float64',
            'end_amount1': 'Float64',
            'end_principal_value_token0': 'Float64',
            'swap_count_in_window': 'UInt64',
            'swap_count_while_active': 'UInt64',
            'fees_accrued_token0': 'Float64',
            'fees_accrued_token1': 'Float64',
            'fees_accrued_token0_equiv_generated': 'Float64',
            'resolved_start_time': 'DateTime',
            'resolved_end_time': 'DateTime',
            'observed_time_in_range_seconds': 'UInt64',
            'observed_window_seconds': 'UInt64',
            'observed_out_of_range_seconds': 'UInt64',
            'observed_time_in_range_pct': 'Float64',
            'observed_out_of_range_pct': 'Float64',
            'hodl_end_value_token0': 'Float64',
            'lp_end_value_including_fees_token0': 'Float64',
            'impermanent_loss_token0': 'Float64',
            'impermanent_loss_pct': 'Float64',
            'pnl_vs_initial_token0': 'Float64',
            'pnl_vs_initial_pct': 'Float64',
            'pnl_vs_hodl_token0': 'Float64',
            'pnl_vs_hodl_pct': 'Float64',
            'fee_to_il_ratio': 'Float64'
        } -%}
{%-   endif -%}
{%-     for column_name in column_name_to_data_types.keys() -%}
{%-       do column_name_to_quoted.update({column_name: adapter.quote(column_name)}) -%}
{%-     endfor -%}
{%- else -%}
{%-   for column_name in column_name_to_data_types.keys() -%}
{%-     do column_name_to_quoted.update({column_name: adapter.quote(column_name)}) -%}
{%-   endfor -%}
{%- endif -%}

{%- if not column_name_to_data_types -%}
    {{ exceptions.raise_compiler_error("Not able to get columns for unit test '" ~ model.name ~ "' from relation " ~ this ~ " because the relation doesn't exist") }}
{%- endif -%}

{%- for column_name, column_type in column_name_to_data_types.items() -%}
    {%- do default_row.update({column_name: (safe_cast("null", column_type) | trim )}) -%}
{%- endfor -%}

{{ validate_fixture_rows(rows, row_number) }}

{%- for row in rows -%}
{%-   set formatted_row = format_row(row, column_name_to_data_types) -%}
{%-   set default_row_copy = default_row.copy() -%}
{%-   do default_row_copy.update(formatted_row) -%}
select
{%-   for column_name, column_value in default_row_copy.items() %} {{ column_value }} as {{ column_name_to_quoted[column_name] }}{% if not loop.last -%}, {%- endif %}
{%-   endfor %}
{%-   if not loop.last %}
union all
{%    endif %}
{%- endfor -%}

{%- if (rows | length) == 0 -%}
    select
    {%- for column_name, column_value in default_row.items() %} {{ column_value }} as {{ column_name_to_quoted[column_name] }}{% if not loop.last -%},{%- endif %}
    {%- endfor %}
    limit 0
{%- endif -%}
{% endmacro %}
