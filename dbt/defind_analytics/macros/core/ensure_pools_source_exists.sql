{% macro ensure_pools_source_exists() %}
  {% if execute %}
    {% set pools_relation = adapter.get_relation(
        database='analytics',
        schema='analytics',
        identifier='pools'
    ) %}

    {% if pools_relation is none %}
      {% set pool_address = env_var('POOL_ADDRESS', '<pool_address>') %}
      {% set clickhouse_port = '9001' if target.name == 'local' else '9000' %}
      {% set clickhouse_password = target.password | default('', true) %}
      {% set metadata_cmd -%}
cd /home/gharbi/defind-analytics
CLICKHOUSE_HOST=localhost \
CLICKHOUSE_PORT={{ clickhouse_port }} \
CLICKHOUSE_USER={{ target.user }} \
CLICKHOUSE_PASSWORD={{ clickhouse_password }} \
CLICKHOUSE_DB={{ target.schema }} \
.venv/bin/python onchain/metadata/fetch_pool_metadata.py --pool-address {{ pool_address }}
      {%- endset %}

      {% set local_bootstrap_cmd -%}
cd /home/gharbi/defind-analytics
.venv/bin/python clickhouse/scripts/bootstrap_local_sources.py
      {%- endset %}

      {% set message -%}
Required source table `analytics.pools` is missing for target `{{ target.name }}`.

dbt cannot build `stg_pools` or any downstream staging models until pool metadata exists.
      {%- endset %}

      {% if target.name == 'local' %}
        {% set message = message ~ "\n\nFor the local environment, first prepare the raw source views and detect the pool from Initialize parquet files:\n\n" ~ local_bootstrap_cmd ~ "\n\nIf pool metadata is still missing afterward, run the fetch command printed by that CLI.\n\nManual fallback:\n\n" ~ metadata_cmd %}
      {% else %}
        {% set message = message ~ "\n\nRun the pool metadata CLI first:\n\n" ~ metadata_cmd %}
      {% endif %}

      {% do exceptions.raise_compiler_error(message) %}
    {% endif %}
  {% endif %}
{% endmacro %}
