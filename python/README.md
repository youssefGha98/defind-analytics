# Analytics Python Layer

Python compute layer on top of the canonical dbt warehouse. Handles path-dependent, parametric, and statistical analytics that don't fit in SQL.

The implementation spec lives in [`python_analytics_layer_spec.md`](../python_analytics_layer_spec.md).

## Structure

- `core/` — V3 math, ClickHouse client, shared types
- `engines/` — perf (mark-to-market), backtest (static LP simulation), LVR (swap-by-swap)
- `analytics/` — vol surface (EVC moneyness bucketing + smoothing)
- `runners/` — CLI entry points (typer)
- `tests/` — pytest suite (25 tests)

## Install

```bash
cd /home/gharbi/defind-analytics
./.venv/bin/pip install -r python/requirements.txt
```

## Environment

All runners expect ClickHouse connection via env vars:

```bash
export CLICKHOUSE_HOST=localhost
export CLICKHOUSE_PORT=8124
export CLICKHOUSE_DATABASE=analytics
export CLICKHOUSE_USER=default
export CLICKHOUSE_PASSWORD=1234
```

## Runners

```bash
# Performance engine (NFPM mark-to-market)
./.venv/bin/python python/runners/run_perf.py \
  --pool 0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640 \
  --start-date 2026-04-01 --end-date 2026-04-14 \
  --write --validate-terminal

# Backtest engine (static, no rebalance)
./.venv/bin/python python/runners/run_backtest.py \
  --pool 0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640 \
  --start-block 24800000 --end-block 24820333 \
  --tick-lower 198000 --tick-upper 201000 \
  --capital-committed-token0 100.0 --validate-summary

# LVR engine (swap-by-swap loss vs rebalancing)
./.venv/bin/python python/runners/run_lvr.py \
  --pool 0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640 \
  --start-date 2026-04-01 --end-date 2026-04-14 \
  --write --validate-range

# Vol surface (EVC moneyness surface + smoothing)
./.venv/bin/python python/runners/run_vol_surface.py \
  --pool 0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640 \
  --start-date 2026-04-01 --end-date 2026-04-14 \
  --write
```

## Tests

```bash
./.venv/bin/python -m pytest python/tests -q
```

## Output Tables

All written to ClickHouse with `py_` prefix:

| Table | Grain | Engine |
|---|---|---|
| `py_position_performance_daily` | (token_id, day) | perf |
| `py_backtest_results` | (scenario_id, block) | backtest |
| `py_backtest_summary` | (scenario_id) | backtest |
| `py_lvr_per_swap` | (pool, tx_hash, log_index) | LVR |
| `py_lvr_daily` | (pool, day) | LVR |
| `py_vol_surface_daily` | (pool, day, moneyness_bucket) | vol surface |
