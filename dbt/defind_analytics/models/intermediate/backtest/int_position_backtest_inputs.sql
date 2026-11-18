-- Canonical scenario inputs for simulated LP position backtests.
--
-- Scenarios are supplied via dbt var position_backtest_scenarios, a list of dicts:
--   - scenario_id (optional)
--   - pool
--   - start_block
--   - end_block
--   - tick_lower
--   - tick_upper
--   - capital_committed_token0
--   - rebalance_policy (optional, default = 'none')
--
-- When no scenarios are supplied, the model builds as an empty relation so the
-- rest of the project can still build cleanly.

{% set raw_scenarios = var('position_backtest_scenarios', []) %}
{% if raw_scenarios is mapping %}
    {% set raw_scenarios = [raw_scenarios] %}
{% endif %}
{% set scenarios = [] %}
{% set scenario_ids = [] %}

{% for scenario in raw_scenarios %}
    {% set pool = scenario.get('pool') %}
    {% set start_block = scenario.get('start_block') %}
    {% set end_block = scenario.get('end_block') %}
    {% set tick_lower = scenario.get('tick_lower') %}
    {% set tick_upper = scenario.get('tick_upper') %}
    {% set capital = scenario.get('capital_committed_token0') %}
    {% set rebalance_policy = scenario.get('rebalance_policy', 'none') %}
    {% set default_id = pool ~ '__' ~ start_block ~ '__' ~ end_block ~ '__' ~ tick_lower ~ '__' ~ tick_upper ~ '__' ~ capital %}
    {% set scenario_id = scenario.get('scenario_id', default_id) %}

    {% if pool is none or start_block is none or end_block is none or tick_lower is none or tick_upper is none or capital is none %}
        {{ exceptions.raise_compiler_error("Each backtest scenario must define pool, start_block, end_block, tick_lower, tick_upper, and capital_committed_token0.") }}
    {% endif %}
    {% if end_block < start_block %}
        {{ exceptions.raise_compiler_error("Backtest scenario '" ~ scenario_id ~ "' has end_block < start_block.") }}
    {% endif %}
    {% if tick_lower >= tick_upper %}
        {{ exceptions.raise_compiler_error("Backtest scenario '" ~ scenario_id ~ "' has tick_lower >= tick_upper.") }}
    {% endif %}
    {% if capital <= 0 %}
        {{ exceptions.raise_compiler_error("Backtest scenario '" ~ scenario_id ~ "' must have capital_committed_token0 > 0.") }}
    {% endif %}
    {% if scenario_id in scenario_ids %}
        {{ exceptions.raise_compiler_error("Duplicate backtest scenario_id '" ~ scenario_id ~ "'.") }}
    {% endif %}

    {% do scenario_ids.append(scenario_id) %}
    {% do scenarios.append({
        'scenario_id': scenario_id,
        'pool': pool,
        'start_block': start_block,
        'end_block': end_block,
        'tick_lower': tick_lower,
        'tick_upper': tick_upper,
        'capital_committed_token0': capital,
        'rebalance_policy': rebalance_policy
    }) %}
{% endfor %}

{% if scenarios | length == 0 %}
SELECT
    CAST(NULL AS Nullable(String))  AS scenario_id,
    CAST(NULL AS Nullable(String))  AS pool,
    CAST(NULL AS Nullable(UInt64))  AS start_block,
    CAST(NULL AS Nullable(UInt64))  AS end_block,
    CAST(NULL AS Nullable(Int32))   AS tick_lower,
    CAST(NULL AS Nullable(Int32))   AS tick_upper,
    CAST(NULL AS Nullable(Float64)) AS capital_committed_token0,
    CAST(NULL AS Nullable(String))  AS rebalance_policy
LIMIT 0
{% else %}
{% for scenario in scenarios %}
SELECT
    CAST('{{ scenario['scenario_id'] }}' AS String)                 AS scenario_id,
    CAST('{{ scenario['pool'] }}' AS String)                        AS pool,
    toUInt64({{ scenario['start_block'] }})                         AS start_block,
    toUInt64({{ scenario['end_block'] }})                           AS end_block,
    toInt32({{ scenario['tick_lower'] }})                           AS tick_lower,
    toInt32({{ scenario['tick_upper'] }})                           AS tick_upper,
    toFloat64({{ scenario['capital_committed_token0'] }})           AS capital_committed_token0,
    CAST('{{ scenario['rebalance_policy'] }}' AS String)            AS rebalance_policy
{% if not loop.last %}
UNION ALL
{% endif %}
{% endfor %}
{% endif %}
