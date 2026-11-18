# defind-analytics — Interview Audit

> Senior data-eng / ML platform engineer audit, prepared for a Quantitative Researcher
> interview. Code-backed, deliberately honest about what is **implemented vs partial vs
> planned vs missing**. All paths are absolute within the repo root.

---

## A. Executive summary (10 bullets)

1. **What it is**: a reproducible local + remote ClickHouse + dbt stack that turns
   raw Uniswap v3 on-chain events (Swap/Mint/Burn/NFPM) into 88 models of pool,
   liquidity, fee, position and gamma/LVR features consumed by Python research,
   notebooks, a backtest engine and (now) a Streamlit dashboard.
2. **Source of truth**: Parquet snapshots on local FS for dev, Cloudflare R2
   (S3-compat) for the remote environment, surfaced as ClickHouse external
   views (`clickhouse/scripts/bootstrap_local_sources.py`, `clickhouse/ddl/*.sql`).
3. **Layering is real**: 8 staging models, 47 intermediates, 33 marts + 1 dim,
   defaults `view/table/table`, 13 explicit `incremental`. ~640 schema-test
   declarations + 74 custom SQL tests + 63 unit tests.
4. **Point-in-time discipline is a strength**: state reconstruction always
   `argMax(value, (block_number, log_index))` via the `latest_state` macro;
   intermediates carry `snapshot_block_number/log_index/block_time`; staging
   incremental uses `WHERE block_number > max(this.block_number)` on the source.
5. **Built-in invariants**: a reconciliation test
   (`tests/lp_analytics/test_mart_volume_daily_reconciles_int_swaps_enriched.sql`)
   and a temporal-consistency test
   (`tests/core/test_int_swaps_enriched_prev_next_state_matches_swap_order.sql`)
   that compares the materialized prev/next state to `lagInFrame`/`lead` over
   the source — exactly the kind of invariant a trading-data eng cares about.
6. **ClickHouse engines are conservative**: every model is plain `MergeTree`.
   The big distribution / tick marts have proper `partition_by toYYYYMM(...)`
   and meaningful `order_by (pool, date|hour, tick)`. The smaller pool-level
   marts (e.g. `mart_volume_daily`, `mart_pool_screener_daily`) lack explicit
   sorting/partitioning — a real weakness.
7. **Docker Compose is dev infrastructure, not prod**: two CH containers, named
   volumes, a mounted read-only datalake, no healthchecks, no `depends_on`,
   no restart policy, no orchestrator. Strong for parity & onboarding,
   not deployable as-is.
8. **Operability is minimal**: no CI/CD, no scheduled orchestration, no
   metrics/alerts. Backfill is shell scripts under `dbt/.../scripts/`
   (`chunked_full_refresh.sh`, `backfill_nfpm_metrics_*.sh`) — engineered but
   manually triggered.
9. **Python integration is clean**: `python/core/db.py` (typed Settings,
   timeouts now wired up), `python/engines/*.py` (GSR / LVR / perf / backtest /
   gamma framework) that read marts and write `py_*` outputs back into the same
   ClickHouse — closes the loop research → production-adjacent.
10. **Honest classification**: this is a **production-adjacent research
    platform**, not a production system. The data layer is reproducible and
    self-validating; the operational layer (orchestration, observability,
    secrets, CI/CD, schema migration) is not in place.

---

## B. Miro mind map (indented)

```
defind-analytics
├── Sources (raw on-chain events)
│   ├── Local Parquet via clickhouse_local
│   │   └── /home/gharbi/Defind/data/uniswap/usdc_weth_alchemy_full_c32/{Event}/*.parquet
│   └── Remote Cloudflare R2 (S3) via storage_policy r2_policy
│       └── clickhouse/config/remote/r2-storage.xml
├── Ingestion bootstrap (Python)
│   ├── clickhouse/scripts/bootstrap_local_sources.py
│   ├── clickhouse/scripts/bootstrap_local_nfpm_sources.py
│   └── clickhouse/ddl/uniswap_usdc_weth{,_local}.sql  (raw view DDLs)
├── dbt project (defind_analytics)
│   ├── sources/
│   │   └── models/staging/sources.yml  (9 raw tables under source analytics.analytics)
│   ├── staging (view default, 8 SQL files, but mostly incremental for cost)
│   │   ├── stg_swaps, stg_mints, stg_burns
│   │   └── stg_nfpm_{transfers,collects,increase_liquidity,decrease_liquidity}, stg_pools
│   ├── intermediate (table default, 47 files)
│   │   ├── core_state/   (int_lp_events, int_swaps_enriched, int_current_state, int_daily_close_dense, int_tick_changes)
│   │   ├── tvl/          (int_active_liquidity_daily, int_active_tvl_daily, int_range_liquidity_daily)
│   │   ├── distribution/ (int_hourly/daily/weekly_tick_liquidity_net, int_hourly/daily_snapshot_blocks, int_tick_boundary_deltas)
│   │   ├── tick_volume/  (int_swaps_tick_volume, int_tick_volume_hourly/daily/weekly)
│   │   ├── nfpm/         (16 models for fees, lots, TIR, collect decomposition, lifecycle, lot benchmarks)
│   │   ├── fees/         (int_fee_per_100_usd, int_lp_macro_daily)
│   │   ├── pool_state/   (int_pool_open_positions_current — canonical pool TVL state)
│   │   ├── backtest/     (entry liquidity, entry state, exit state, swap path, time in range, inputs)
│   │   └── product/      (int_adverse_selection_proxy_daily, int_range_candidates_grid)
│   ├── marts (table default; ~36 files)
│   │   ├── dim/                  (dim_indexed_pools — canonical scoped universe)
│   │   ├── price/                (mart_price_intraday, mart_price_analytics_daily, mart_tick_daily, mart_tick_liquidity_volume_daily, mart_tick_sigma_evc_hourly/weekly)
│   │   ├── tvl/                  (mart_tvl_current, mart_tvl_block_snapshot, mart_tvl_daily, mart_tvl_distribution[_*_centered, _*_metrics])
│   │   ├── nfpm/                 (positions_current, position_lifecycle, position_pnl_current, open_positions_current)
│   │   ├── lp_analytics/         (mart_volume_daily, mart_fee_yield_daily [view, deprecated])
│   │   ├── product/              (mart_pool_screener_daily, mart_pool_analytics_snapshot, mart_pool_distribution_snapshot, mart_position_cards_current, mart_position_features_current [view], mart_range_candidates_features, mart_range_heatmap_features, mart_range_apr [parametrized view], mart_tracked_lp_wallet_*)
│   │   └── backtest/             (mart_position_backtest_summary)
│   ├── macros/
│   │   ├── core/   (latest_state.sql, nfpm_amounts.sql, tvl_snapshot.sql, ensure_pools_source_exists.sql)
│   │   ├── math/   (uniswap_math.sql — sqrt_price_at_tick, amount0/1_from_liquidity, …)
│   │   ├── backtest/ (position_backtest.sql)
│   │   └── testing/ (unit_test_fixtures.sql)
│   ├── tests/ (74 custom SQL tests across distribution/, core/, lp_analytics/, intermediate/, backtest/)
│   ├── schema.yml constraints (≈640 entries: 32 not_null, 21 accepted_values, 7 relationships, 5 unique + descriptions)
│   ├── unit_tests.yml (63 fixture-based tests in intermediate/ and marts/)
│   ├── scripts/   (chunked_full_refresh.sh, backfill_nfpm_metrics_weekly.sh, backfill_nfpm_metrics_monthly.sh)
│   ├── profiles.yml (remote = port 8123, local = 8124, custom_settings spill-to-disk + partial_merge join)
│   └── dbt_project.yml (on-run-start ensure_pools_source_exists)
├── Python layer (python/)
│   ├── core/db.py    (ClickHouseSettings via pydantic-settings, ClickHouseDB wrapper with timeouts)
│   ├── core/position_math.py, core/types.py
│   ├── engines/      (gsr_engine, gamma_framework, gamma_risk_engine, lvr_engine, perf_engine, backtest_engine)
│   ├── runners/      (typer CLIs: run_gsr, run_gamma_framework, run_lvr, run_perf, run_backtest, run_vol_surface)
│   └── notebooks/    (01-09 QA, 10-13 POC: GSR, gamma framework, remediation v0.2)
├── docs/
│   ├── frontend_data_contract.md (public mart whitelist for frontend)
│   ├── streamlit_dashboard_handoff.md (per-section briefing for the Streamlit agent)
│   └── interview_audit.md (this file)
├── FEATURES.md (column-by-column inventory)
├── docker-compose.yml (clickhouse remote 8123 + clickhouse_local 8124, no healthchecks/depends_on/restart)
└── .env / .env.example (R2, RPC URL, CH creds — committed to FS, not safe for repo prod)
```

---

## C. Architecture diagram (plain text)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Raw on-chain event Parquet                                                  │
│  ├── local FS:  /home/gharbi/Defind/data/.../{Mint,Burn,Swap,NFPM*}/*.parquet │
│  └── remote R2: cloudflare bucket via storage_policy r2_policy               │
└──────────────────────────────────────────────────────────────────────────────┘
                              │
                              │  bootstrap_local_sources.py  (or DDLs)
                              ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  source('analytics', 'uniswap_*')   ← raw views in ClickHouse                │
│  (S3-engine on remote / file()-view on local)                                │
└──────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼   dbt staging  (incremental on block_number)
┌──────────────────────────────────────────────────────────────────────────────┐
│  stg_swaps, stg_mints, stg_burns, stg_pools, stg_nfpm_*                      │
│  - decimals applied, sqrtPriceX96 → price_token1_in_token0                   │
│  - PARTITION BY toYYYYMM(block_time), ORDER BY (pool, block_number, log_idx) │
│  - WHERE block_number > max(this.block_number)  on incremental runs          │
└──────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼   dbt intermediate
┌──────────────────────────────────────────────────────────────────────────────┐
│  int_lp_events (signed mint+burn), int_swaps_enriched (prev/next state),    │
│  int_current_state, int_daily_close_dense (spine), int_tick_changes,        │
│  int_active_liquidity_daily / int_active_tvl_daily / int_range_liquidity_d  │
│  int_hourly/daily/weekly_tick_liquidity_net (running cumulants of net liq),  │
│  int_nfpm_* (lifecycle, fees daily/summary, lots, TIR, collect),            │
│  int_fee_per_100_usd, int_lp_macro_daily, int_pool_open_positions_current,   │
│  int_position_backtest_* (entry liquidity, swap path, time-in-range, exit) │
└──────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼   dbt marts (analyst- + Python-facing)
┌──────────────────────────────────────────────────────────────────────────────┐
│  Pool view   : mart_pool_screener_daily, mart_pool_analytics_snapshot,      │
│                mart_volume_daily, mart_price_analytics_daily,               │
│                mart_price_intraday, mart_tvl_current / daily / distribution │
│  Tick µstr   : mart_tick_liquidity_volume_daily (incremental), sigma EVC    │
│                hourly/weekly (incremental)                                  │
│  Position    : mart_nfpm_position_pnl_current, mart_position_cards_current  │
│  Range       : mart_range_apr (parametrized view, NEW),                     │
│                mart_range_candidates_features (legacy proxy — flagged)      │
│  Wallet      : mart_tracked_lp_wallet_*  (overview, exposure, pnl, activity)│
│  Backtest    : mart_position_backtest_summary                               │
└──────────────────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────────────────┐
        ▼                     ▼                                 ▼
  py_* engines           Streamlit              QA + POC notebooks (1-13)
  (GSR, gamma,           dashboard              backtests, gamma framework
   LVR, perf,            (handoff doc)          remediation reports
   backtest)
        │
        └── write back into ClickHouse as py_*_daily / py_*_per_swap
            (loop closes: marts → Python decisions → py_* analytic marts)
```

---

## D. Strongest engineering decisions (ranked)

1. **Point-in-time correctness as a first-class discipline.**
   `macros/core/latest_state.sql` exposes `latest_swap_state_tuple(...)` and
   `latest_by_block_log(...)` that aggregate state via `argMax(value, (block_number, log_index))`,
   so every "what was the state at this row" join is unambiguous. The intermediate
   models carry `snapshot_block_number / snapshot_log_index / snapshot_block_time`
   so downstream code can verify it joined at the right point. Reinforced by the
   test `test_int_swaps_enriched_prev_next_state_matches_swap_order.sql` which
   asserts the materialized prev/next state equals `lagInFrame/lead` over the
   source ordered by `(block_number, log_index)`. This is exactly what a trading
   data engineer should see.

2. **Cross-layer reconciliation as a test, not a comment.**
   `tests/lp_analytics/test_mart_volume_daily_reconciles_int_swaps_enriched.sql`
   re-aggregates `int_swaps_enriched` and FULL OUTER JOINs against
   `mart_volume_daily`, failing on any mismatch beyond tight tolerances
   (`abs(volume_token1 - expected) > 1e-8`, swap_count exact, etc.). This catches
   any drift between the raw layer and the published mart.

3. **Generic, decimal-aware V3 math centralised in macros.**
   `macros/math/uniswap_math.sql` exposes `sqrt_price_from_price(price_expr, d0, d1)`,
   `sqrt_price_at_tick`, `clamp_sqrt_price`, `amount0_from_liquidity`,
   `amount1_from_liquidity`. The docstring explicitly notes a previous bug
   (hardcoded `10^12` for USDC/WETH) and that the macros now take decimals as
   args — so a future ETH/USDT pool wouldn't require touching every model.

4. **Two-target dbt + two-disk CH ≈ environment parity with cost separation.**
   `profiles.yml` defines `local` (port 8124, dev) and `remote` (port 8123, R2-backed
   storage_policy). Staging models in `stg_swaps` apply `settings={'storage_policy': 'r2_policy'}`
   only when `target.name == 'remote'`. Same models, same logic, different storage.
   That is a real "dev parity" feature, not just two unrelated CHs.

5. **Bounded heavy models via `+settings` discovery, not container bumping.**
   When the recent rebuild OOMed on memory-pig joins, the fix went into
   `profiles.yml` `custom_settings` (spill-to-disk + `join_algorithm: partial_merge`)
   so all queries inherit it, plus a model-level bound for the recent-window
   distribution mart (`mart_tvl_distribution_hourly_centered` now defaults to a
   14-day lookback). This is the right place to fix it.

6. **Connection settings declared explicitly in code.**
   `python/core/db.py` sets `connect_timeout=10` and `send_receive_timeout=180`
   on the ClickHouse client and exposes a typed `ClickHouseSettings` via
   `pydantic-settings`. Without those timeouts the Jupyter kernels were
   blocking forever in `epoll_wait` on stale `CLOSE_WAIT` sockets. The fix is
   small but it shows operational instinct.

7. **Frontend data contract authored before the dashboard ships.**
   `docs/frontend_data_contract.md` whitelists exactly which marts are public,
   declares `int_*`/`stg_*` off-limits, calls out `mart_fee_yield_daily` as
   deprecated, and codifies the rule "decision logic lives in Python engines,
   not in the dashboard SQL." That's an architectural rule a senior would
   want to see.

---

## E. Weaknesses and limitations (honest)

1. **No CI/CD.** No `.github`, `.gitlab-ci.yml`, `.circleci/`, nothing.
   `dbt build` is run manually. A `pull_request` workflow that runs
   `dbt build --select state:modified+` on a fresh CH would be the obvious
   next step.

2. **No orchestrator.** Backfill is shell scripts
   (`scripts/chunked_full_refresh.sh`, `backfill_nfpm_metrics_*.sh`), no
   Airflow / Dagster / Prefect / cron. For a research stack that's fine; for
   anything closer to production it's the next ceiling.

3. **No observability.** Zero logging structure, no Prometheus / OpenTelemetry,
   no `dbt run-results.json` published anywhere, no freshness alerting. The
   `logs/dbt.log` file is the only audit trail and it's grown to 100k+ lines
   without rotation.

4. **Docker Compose is dev-only.** No `healthcheck`, no `depends_on`, no
   `restart: unless-stopped`, no resource reservations besides one `memory:
   limit`, no read-only secrets — the `.env` file is on disk and contains R2
   keys and an RPC URL in plain text. The two CH containers are also entirely
   independent (no replication / failover). It's a parity-friendly dev
   environment, not deployable infrastructure.

5. **Pool-level marts lack sorting / partitioning.** Quick `system.tables`
   check: `mart_pool_screener_daily`, `mart_volume_daily`, `int_lp_events`,
   `int_swaps_enriched` are all plain `MergeTree` with **empty** `sorting_key`
   and `partition_key`. They are small today (~1800 rows, 1 pool) so this
   doesn't bite, but it's a latent scaling issue and a real anti-pattern that
   contradicts the tick-level marts which do have proper keys.

6. **Engines are conservative.** Everything is plain `MergeTree`. No
   `ReplacingMergeTree` for the staging tables that *could* deduplicate
   on `(tx_hash, log_index)`. No `AggregatingMergeTree` materialized view to
   incrementally maintain pool daily aggregates. The current `Replacing`
   instances are dbt's own infrastructure tables, not modelled choices.

7. **`mart_range_candidates_features` is a known liar.** As surfaced during
   this very audit: `expected_fee_apr_proxy` is a pool-level value copied
   across candidates 96 % of the time, `gross_fee_apr_inside_range_proxy` has
   broken units (~10^6 %), `is_estimated = 1` on every row, and the
   in-range-probability is constant per date. The replacement
   (`mart_range_apr`, parametrized view) is good but the legacy mart still
   ships, only its docstring warns the reader.

8. **Late-arriving data is not handled.** The staging incremental predicate is
   `WHERE block_number > max(this.block_number)`. If a parquet chunk gets a
   late-arriving row at an older block, it is silently skipped. There is no
   `merge`-strategy incremental and no `--full-refresh` ritual documented for
   this scenario.

9. **No reorg / fork handling.** The pipeline assumes chain finality on the
   source. There is no equivalent of "drop rows where block_number > finalized_block".
   This is fine for Ethereum mainnet historical (block 12,369,000+ deep) but
   would matter on any low-finality chain.

10. **Notebook-to-prod boundary is informal.** The Python engines
    (`gsr_engine`, `gamma_framework`, etc.) write back into ClickHouse via
    `core/db.py` and the runners are typer CLIs — that's good — but there's
    no scheduler, no idempotency wrapper, no contract test that asserts the
    `py_*` outputs match a regression fixture. Runners are reproducible by
    args alone, not by a versioned config.

---

## F. JD mapping table

| JD requirement | Project evidence | Strength | Limitation |
|---|---|---|---|
| Advanced Python | `python/engines/gamma_framework.py` (HAR-RV rolling forecast, jump decomposition, per-position v3 amount math via decimal-aware solve in `core/position_math.py`), `python/runners/*` typer CLIs, `python/core/db.py` typed settings | **Strong** | No type hints in some legacy engines; no async / multiprocessing for backtests |
| Advanced SQL | 88 dbt models, `int_swaps_enriched` (window-function prev/next state), point-in-time `argMax` macros, parametrized view `mart_range_apr`, reconciliation test using FULL OUTER JOIN | **Strong** | Pool-level marts have no `order_by`/`partition_by` |
| Efficient handling of large time series | Per-tick × hour mart with 158 M rows, sigma-EVC hourly mart with 2.3 M rows, partition by `toYYYYMM(date|hour)`, incremental with date cutoffs, spill-to-disk + `partial_merge` join settings | **Strong** | The OOM episode shows the platform's edges; production would need sharding/replication |
| Time-series stores (QuestDB / equivalent) | ClickHouse is the equivalent. MergeTree with date partitioning, incremental refresh, per-tick TWAP/last variants for sigma_evc | **Strong** | Single-node, no replication |
| Relational + object storage | ClickHouse on remote env reads from **R2 (S3-compat)** via `r2_policy` and a `<r2_cache>` disk; local env reads from a host-mounted Parquet datalake via `file()` views | **Strong** | Secrets are in the XML config file, plain text |
| Reproducible research pipelines | `dbt build` is one command. `docker compose up -d clickhouse_local` boots the stack. Notebooks are versioned with the engines. Engine outputs are written back to CH so each notebook re-run reads the same view. | **Strong** | No data versioning (no `dvc`, no `dbt snapshots`, no LakeFS) |
| Backtesting infrastructure | `python/engines/backtest_engine.py` (entry-liquidity, swap-path, time-in-range, exit-state builders) + `int_position_backtest_*` intermediates + `mart_position_backtest_summary` dbt model + `py_backtest_results`/`_summary` Python outputs | **Strong** | One scenario at a time, no parameter sweep, no stochastic resample |
| Move models from notebooks to production-adjacent | Each notebook engine has an `engines/*.py` + a `runners/run_*.py` typer CLI that writes to a `py_*` mart. The handoff doc declares which `py_*` are production-stable vs experimental. | **Strong** | No CI, no scheduler — they still need a human to run them |
| Collaboration with trading + engineering | Frontend data contract (`docs/frontend_data_contract.md`), Streamlit handoff (`docs/streamlit_dashboard_handoff.md`), per-mart `_schema.yml` descriptions, custom invariant tests | **Strong** | No PR template, no review checklist, no runbook beyond the audit |
| Decision-ready analysis | NB 12 + 13 (Gamma Framework + Remediation v0.2) end with explicit verdicts and limitations. The repo separates "features" (dbt marts) from "decisions" (Python engines) by rule. | **Strong** | Decisions today are notebooks, not API endpoints |

---

## G. 3-minute interview presentation

> **Problem.** I was given a few hundred million raw Uniswap v3 events
> (Swaps / Mints / Burns / NFPM transfers) on Parquet and asked to produce
> trading-quality features: pool TVL, per-tick fees, position PnL with IL,
> backtest-ready time series, and gamma / LVR analytics. Pandas-on-notebook
> didn't scale — a single intraday volatility surface joined 158 million
> tick-rows. Raw Parquet wasn't queryable enough — I needed
> point-in-time joins across events, swaps and price.
>
> **Stack.** ClickHouse for the storage and compute engine — columnar, partitioned,
> incremental — and dbt for SQL discipline: lineage, tests, macros for the v3
> math, and a clean staging → intermediate → marts layering. Two CH targets:
> a local one that reads Parquet from the host via `file()` views, and a remote
> one that reads from Cloudflare R2 via the S3 storage policy. Same models,
> same tests, two backends. Compose brings up either with one command.
>
> **What I built.** 88 dbt models. Eight staging models that apply token
> decimals and convert `sqrtPriceX96` to a human-readable price. ~50
> intermediates that reconstruct state — most importantly `int_swaps_enriched`,
> where the prev/next swap state is derived by `lagInFrame/lead` ordered by
> `(block_number, log_index)`, and a custom test asserts that materialization
> exactly matches the source ordering. On top of that, ~35 marts:
> the pool screener, tick microstructure (sigma EVC), the TVL distribution
> over hourly bins, NFPM position lifecycle + PnL decomposition, and a
> parametrized view `mart_range_apr(pool, tick_lower, tick_upper, start_date,
> end_date)` that returns the gross fee APR of an arbitrary range over an
> arbitrary window — built on per-tick fees and per-tick TVL.
>
> **Three engineering decisions I'm proud of.** First, **point-in-time
> correctness as a discipline**: every state reconstruction goes through
> `argMax(value, (block_number, log_index))` via the `latest_state` macro, and
> a custom test verifies the prev/next ordering. Second, **cross-layer
> reconciliation as a test**: `mart_volume_daily` is FULL OUTER JOINed against
> a re-aggregation of `int_swaps_enriched` and any drift > 1e-8 token1 fails
> the build. Third, **moving notebook research into production-adjacent
> systems**: each notebook engine has a `python/engines/*.py` library and a
> typer-CLI runner that writes back into ClickHouse as a `py_*` mart, so the
> next research iteration reads the previous run's output as a real mart.
>
> **One hard problem.** A heavy distribution mart joined a 158 M row tick
> table twice. With our 6 GiB CH container, that OOMed both as a hash join
> and as grace_hash. I diagnosed it as "the model was a recent-window snapshot
> being run over five years of history". The fix was a default `lookback_days=14`
> bound applied to both joins, plus a profile-level `join_algorithm:
> partial_merge` and external-spill settings. Time dropped from `> 100 s + OOM`
> to **1 s**.
>
> **Limits.** No CI, no scheduler, no observability. Docker Compose is
> reproducible local infrastructure, not a production deployment. I'd ship
> a `dbt build --select state:modified+` GitHub action and an Airflow DAG
> next.
>
> **Transfer to Limitless.** Prediction-market data is the same shape:
> event-sourced state, point-in-time correctness or you lie to the strategy,
> and dashboards that want to ask "what was the APR on this market between
> these two times". The dbt + ClickHouse pattern and the parametrized-view
> trick map directly.

---

## H. 25 likely interview questions

### ClickHouse (5)

1. **"You used plain MergeTree everywhere. Why not ReplacingMergeTree on staging
   to deduplicate by (tx_hash, log_index)?"**
   *Why asked*: probes engine choice.
   *Strong answer*: deduplication is happening upstream at the Parquet level and
   the incremental predicate `block_number > max(this.block_number)` makes
   re-insertion of the same row impossible by construction; if duplicates ever
   started leaking I'd switch the four event-staging tables to ReplacingMergeTree
   with `version = block_number` and the ordering key `(pool, block_number, log_index, tx_hash)`.
   *Weakness not to overstate*: I currently rely on the source being idempotent;
   I have no explicit dedup test.

2. **"Some of your marts have no partition key and no sorting key. Walk me
   through `mart_volume_daily`."**
   *Why asked*: tests whether I can defend my own SQL.
   *Strong answer*: it's a real weakness. The table is tiny today (1798 rows,
   one pool) so the absence of `ORDER BY (pool, date)` doesn't materially hurt,
   but at multi-pool scale it would — point lookups would scan the whole table.
   I would add `ORDER BY (pool, date)` + `PARTITION BY toYYYYMM(date)` in a
   PR.
   *Don't overstate*: the tick-level marts are correctly tuned.

3. **"Why partition by month (`toYYYYMM(hour)`) and not by day?"**
   *Why asked*: probes partitioning sense.
   *Strong answer*: ClickHouse recommends keeping the number of active parts
   per table low. `toYYYYMM(hour)` on a 5-year hourly dataset gives ~60 active
   parts; `toYYYYMMDD` would give ~1825. The query patterns are date-range
   filters on the order of weeks-to-months, so monthly partitions still let
   ClickHouse skip irrelevant parts.

4. **"Walk me through how you'd debug `MEMORY_LIMIT_EXCEEDED` on a join."**
   *Strong answer*: (i) check `system.processes` and the exception text — the
   transform name (`FillingRightJoinSide` vs `MergeSortingTransform`) tells me
   what spilled; (ii) `EXPLAIN ESTIMATE` and `EXPLAIN PIPELINE` for the heavy
   query; (iii) check the build-side row count; (iv) set
   `join_algorithm = 'partial_merge'`, `max_bytes_before_external_group_by`
   and `max_bytes_in_join` at the connection / query level; (v) if the model
   shouldn't process all history, bound it (the
   `mart_tvl_distribution_hourly_centered` story).

5. **"How do you handle ClickHouse external storage for raw event data?"**
   *Strong answer*: remote env uses a `storage_policy r2_policy` with an
   `<r2_cache>` disk that wraps an `s3`-type disk pointing to Cloudflare R2.
   Staging models opt into it via `settings={'storage_policy': 'r2_policy'}`
   only when `target.name == 'remote'`. Local dev mounts the host Parquet
   datalake read-only and reads it via `file()` views.

### dbt (5)

6. **"Why dbt? Why not raw SQL files orchestrated by Make?"**
   *Strong answer*: lineage (`ref()`), reproducibility (`dbt build` rebuilds
   only what changed), tests collocated with models, macros for DRY math
   (`uniswap_math.sql`), schema yml as documentation, environment-aware
   `target.name` switching, and the unit-test framework. The reconciliation
   test alone — `mart_volume_daily` vs re-aggregated `int_swaps_enriched` —
   would have been awkward to maintain in Make + raw SQL.

7. **"Show me an interesting macro."**
   *Strong answer*: `latest_state.sql` — `latest_by_block_log(value, block, log)`
   wraps `argMax(value, tuple(block, log))`, which is the v3 point-in-time
   pattern. It's used in `int_current_state` and `int_swaps_enriched`. The
   reason it's worth a macro: the moment you write `argMax(value, block)` instead
   of `(block, log)`, you get the wrong row for same-block events. Centralizing
   the tuple prevents that.

8. **"How do you avoid duplicated logic across marts?"**
   *Strong answer*: macros for v3 amount math, the `latest_state` macro for
   point-in-time, and the matriochka cleanup I did in the recent audit
   (reclassified `mart_fee_per_100_usd` and `mart_lp_macro_daily` as
   intermediates because they were only consumed by `mart_pool_screener_daily`,
   eliminating four-level mart chains).

9. **"Where do you draw the line between dbt and Python?"**
   *Strong answer*: dbt materializes quantitative state and features; Python
   engines compute decisions, scores and recommendations. The
   `frontend_data_contract.md` codifies the rule "decision logic must live in
   a Python engine, not in a dashboard SQL".

10. **"How do you handle late-arriving data?"**
    *Honest answer*: I don't, today. The staging incremental predicate is
    `WHERE block_number > max(this.block_number)`; a row arriving at an older
    block is silently skipped. The remediation would be (a) a periodic
    `--full-refresh` on staging, or (b) switching to a `merge` strategy with a
    unique key of `(tx_hash, log_index)`.

### SQL and data modeling (3)

11. **"Walk through `int_swaps_enriched`."**
    *Strong answer*: it carries each swap row plus the previous and next state
    via `lagInFrame(tick) OVER (PARTITION BY pool ORDER BY block_number, log_index)`,
    and `lead(block_time)` for time-to-next-swap. The custom test re-derives
    those windows from `stg_swaps` and FULL-JOINs them against the materialized
    version; any drift fails the build. That's the row that downstream
    intermediates rely on for "what was the state right before this event".

12. **"Why a parametrized view for `mart_range_apr` and not a regular mart?"**
    *Strong answer*: the range is `(tick_lower, tick_upper)` and the window is
    `(start_date, end_date)` — both user inputs with infinite combinations,
    so nothing pre-materializable. ClickHouse parametrized views compile to
    a SELECT statement with placeholder substitution at query time; dbt is
    happy because single braces aren't Jinja delimiters. The driver fills the
    placeholders via the `parameters=` kwarg, which also defends against
    injection.

13. **"How do you compute the APR of a given range from per-tick data?"**
    *Strong answer*: `mart_tick_liquidity_volume_daily` has, per pool × tick ×
    day, `fees_generated_token0_equiv` and `tick_tvl_token0_twap`. APR =
    `Σ fees(tick, day) for (tick in [lo,hi], day in window) / n_days * 365 / avg(daily Σ tvl(tick in [lo,hi]))`.
    The `mart_range_apr` view encapsulates exactly that. The numerator
    reconciles against pool fees from `mart_volume_daily` (I verified this
    explicitly during the audit).

### Docker / reproducibility (3)

14. **"Is your stack production-ready?"**
    *Honest answer*: No. It is **reproducible local infrastructure**.
    `docker compose up -d clickhouse_local && dbt build --target local` boots
    everything from zero, parity with the remote target via `target.name`
    switching, but there are no healthchecks, no `depends_on`, no `restart:`
    policy, no replication, no secret management. Secrets are in `.env` on
    disk.

15. **"Walk me through reproducing your environment."**
    *Strong answer*: clone, copy `.env.example` to `.env`, populate R2 keys,
    `docker compose up -d clickhouse_local`, run `python clickhouse/scripts/bootstrap_local_sources.py`
    to create the raw views, `cd dbt/defind_analytics && dbt build --target local`.
    The whole thing comes up in a few minutes.

16. **"How would you turn this into a production system?"**
    *Strong answer*: (i) GitHub Actions running `dbt build --select state:modified+`
    against a fresh CH on PR; (ii) Airflow / Dagster DAG that schedules
    `bootstrap_sources` → `dbt build` → `runners/run_*.py`; (iii) Docker Compose
    becomes a single-node target; the real deploy is two CH replicas behind
    `chproxy`; (iv) secrets go to a vault and CH config reads them at startup;
    (v) `dbt run-results.json` published to a metadata store + Slack/Grafana
    alerts on freshness, fail counts, and reconciliation deltas.

### Point-in-time / temporal consistency (3)

17. **"How do you prevent look-ahead bias in your features?"**
    *Strong answer*: every state lookup is `argMax(value, (block_number, log_index))`
    via `latest_state` macros, so a feature row carries the *exact* on-chain
    state at its own `(block, log)`. Daily marts that need same-day rolling
    windows use `rolling_sum(window_size=N, min_samples=1)` over the
    chronological order; the HAR-RV engine specifically uses
    `pandas.Series.shift(1).rolling(30).quantile(0.75)` to guarantee the
    threshold for day `t` only sees days `t-31 … t-1`. (This was an explicit
    audit during the gamma framework remediation.)

18. **"What happens if two events share the same block_number?"**
    *Strong answer*: they get tie-broken by `log_index`. The reason
    `latest_by_block_log` passes the tuple `(block, log)` to `argMax` instead
    of just `block` is exactly to handle this — within a single block, the
    log_index gives the within-block ordering of events.

19. **"How would chain reorganizations affect your tables?"**
    *Honest answer*: today the pipeline assumes the source is final. For
    Ethereum mainnet at the indexing depth this is safe; for a reorg-prone
    chain I'd need (a) a `finalized_block` column on the source, (b)
    staging-level WHERE `block_number <= finalized_block`, and (c) periodic
    refresh of the last N blocks via `--full-refresh` on a thin tail.

### Incremental processing (2)

20. **"Walk me through one of your incremental models."**
    *Strong answer*: `mart_tick_liquidity_volume_daily` uses
    `materialized='incremental'`, `incremental_strategy='delete_insert'`,
    `unique_key=['pool', 'date', 'tick']`, `partition_by='toYYYYMM(date)'`,
    and a `date >= (SELECT date_cutoff FROM incremental_cutoff)` predicate.
    Optional vars (`sigma_evc_start_date`, `sigma_evc_end_date`) override the
    incremental window so a backfill script can target a specific month. The
    chunked backfill (`scripts/chunked_full_refresh.sh`) uses exactly those
    vars to rebuild in 6-month slices without OOMing.

21. **"What about full refresh — does incremental match the rebuild?"**
    *Honest answer*: yes for the date-bounded incremental models, because the
    `delete_insert` strategy deletes the partition before re-inserting. For
    the staging models with `WHERE block_number > max(this.block_number)`, the
    initial full refresh and subsequent incrementals produce identical output
    *only if* the source is monotonic in `block_number` — late rows would
    cause divergence, which is the limitation I called out earlier.

### Testing (2)

22. **"Show me your most interesting custom test."**
    *Strong answer*: the reconciliation test
    `test_mart_volume_daily_reconciles_int_swaps_enriched.sql` — it FULL OUTER
    JOINs the published mart against a re-aggregation of the intermediate and
    fails on any token1 mismatch > 1e-8 or swap-count delta. This is the
    invariant a trading desk cares about, and it cost essentially nothing to
    write.

23. **"What's missing in your test coverage?"**
    *Honest answer*: (i) no freshness tests on the staging sources, (ii) no
    sentinel test for "every day in the date range has a row in the daily
    marts" (would catch silent gaps), (iii) no negative-balance / liquidity
    conservation invariant on `int_lp_events`, (iv) no `dbt source freshness`
    on the upstream Parquet, (v) no determinism test (rebuild twice, compare
    row hashes).

### Architecture trade-offs (2)

24. **"What's the weakest piece of the architecture?"**
    *Strong answer*: the operational layer. The data layer has lineage, tests,
    point-in-time discipline. There is no scheduler, no CI, no
    observability, no rollback. For a research stack that's fine; for a
    Limitless-style trading-adjacent system it's the next ceiling.

25. **"If you had two weeks, what would you fix?"**
    *Strong answer*: week one — a GitHub Action that runs `dbt build --select
    state:modified+` and the unit tests on PR against a fresh CH spun up in
    the runner; a `dbt source freshness` on the staging sources with Slack
    alerts; rotate the dbt log file and ship `run-results.json` to S3. Week two
    — an Airflow DAG that orchestrates bootstrap → dbt build → engines, with
    SLA monitoring; rename `mart_range_candidates_features` to
    `_legacy_range_candidates_features` and replace its consumers with
    `mart_range_apr` + range-conditioning logic in Python.

---

## I. Files to show during the interview

| # | Path | What it demonstrates | What I'd explain | Risk to flag |
|---|---|---|---|---|
| 1 | `dbt/defind_analytics/macros/core/latest_state.sql` | Point-in-time correctness as a discipline | `argMax(value, (block_number, log_index))` is the v3-correct point-in-time pattern; tie-breaking by `log_index` is non-negotiable. | Easy follow-up: "what if you had multiple chains?" — I'd add `chain_id` to the ordering tuple. |
| 2 | `dbt/defind_analytics/models/intermediate/core_state/int_swaps_enriched.sql` | Strong, real-world intermediate model | Per-swap row carrying previous and next swap state via `lagInFrame(tick) OVER (PARTITION BY pool ORDER BY block_number, log_index)`. Foundation for every downstream feature that asks "what was the state right before this event". | "What if two events share the same block_number?" → log_index tie-break, covered. |
| 3 | `dbt/defind_analytics/tests/core/test_int_swaps_enriched_prev_next_state_matches_swap_order.sql` | Invariant test — temporal-consistency | Re-derives prev/next via `lagInFrame`/`lead` directly from `stg_swaps`, FULL-JOINs against the materialized intermediate, fails on any drift. | None — this is unambiguously a strength. |
| 4 | `dbt/defind_analytics/tests/lp_analytics/test_mart_volume_daily_reconciles_int_swaps_enriched.sql` | Cross-layer reconciliation as a test | Re-aggregates intermediate, FULL OUTER JOIN against published mart, fails on > 1e-8 token1 delta or swap-count mismatch. | None. |
| 5 | `dbt/defind_analytics/models/marts/price/mart_tick_liquidity_volume_daily.sql` | Strong incremental model | `delete_insert`, `unique_key=['pool','date','tick']`, `partition_by='toYYYYMM(date)'`, optional vars for backfill chunking — the patterns I'd defend in a partition-key discussion. | Easy follow-up: "why not ReplacingMergeTree" — partition-aware delete_insert is functionally equivalent for our key and integrates with dbt's vars. |
| 6 | `dbt/defind_analytics/models/marts/product/mart_range_apr.sql` | Parametrized view = API-like interface to per-range APR | Returns the gross fee APR for an arbitrary `[tick_lower, tick_upper]` over an arbitrary `[start_date, end_date]`, sourced from per-tick fees and TVL. Single CH RT call. | "What about IL?" — gross fee only, by design; IL belongs to a Python engine. |
| 7 | `docker-compose.yml` + `clickhouse/config/local/docker_related_config.xml` | Compose-level dev parity and explicit dependency on CH config (memory ratio) | Two CH targets, R2 storage policy on remote, host-mounted Parquet on local, explicit memory ratio + container limit. | Be honest: no healthcheck, no depends_on, no restart policy → dev infrastructure. |
| 8 | `docs/frontend_data_contract.md` + `docs/streamlit_dashboard_handoff.md` | Engineering hygiene for collaboration | Public-mart whitelist, rule "decision logic belongs in a Python engine", per-mart column inventory for the downstream agent. | None — this is collaboration evidence. |

(Bonus, if time: `python/engines/gamma_framework.py` — the HAR-RV rolling
forecast + jump decomposition. It's the cleanest example of "moved from
notebook into a reusable engine and wrote results back to a `py_*` mart".)

---

## J. Improvements I would make today

1. **CI**: a GitHub Action that boots a CH container in the runner and runs
   `dbt build --select state:modified+ --target local` + the custom tests + the
   unit tests on every PR. ~50 lines of YAML.
2. **Add `dbt source freshness`** on the four upstream Parquet sources with a
   Slack webhook for staleness > 24 h.
3. **Fix the pool-level marts**: `ORDER BY (pool_address, date)` + `PARTITION
   BY toYYYYMM(date)` on `mart_pool_screener_daily`, `mart_volume_daily`,
   `int_swaps_enriched`, `int_lp_events`.
4. **Retire `mart_range_candidates_features`** (rename it
   `_legacy_range_candidates_features` so consumers break loudly) and replace
   its callers with `mart_range_apr` + Python-side range-conditioning.
5. **`dbt build` in containers**: a `Dockerfile.dbt` so dbt itself runs in a
   pinned-version container — eliminates "works on my venv" drift.
6. **Secrets out of `.env`**: move the R2 keys and RPC URL to a vault, render
   the CH XML config at container start from an env-driven template.
7. **Healthchecks on the CH containers** + `depends_on: service_healthy` on
   anything that talks to them. `restart: unless-stopped`.
8. **Determinism test**: rebuild a single representative date partition twice,
   compare row hashes — caught silently broken aggregates in past projects.
9. **`mart_pool_snapshot_block` parameterised view** (block instead of date)
   — `mart_range_apr` at block precision would require the per-block tick
   liquidity, but the API shape is the same.
10. **Lineage-aware backtest replay**: store a versioned scenario config
    (`scenario_id, git_sha, mart_versions`) per backtest run so a backtest can
    be replayed deterministically months later.

---

## Appendix — what the audit confirmed by inspection

- **Materializations** (`grep -rE "materialized="`): 13 incremental, 28 explicit `table`,
  4 explicit `view`. Remaining models use the dbt_project.yml defaults
  (staging=view in fact mostly overridden to incremental, intermediate=table,
  marts=table).
- **ClickHouse engines in `analytics`**: 171 `MergeTree`, 58 `View`,
  13 `ReplacingMergeTree` (dbt infra, not modelled choices).
- **Custom SQL tests** (`tests/`): 74 across `distribution/`, `core/`,
  `lp_analytics/`, `intermediate/`, `backtest/`.
- **`schema.yml` test declarations**: 32 `not_null`, 21 `accepted_values`,
  7 `relationships`, 5 `unique` + descriptions on most columns.
- **Unit tests** (`unit_tests.yml`): 35 in `intermediate`, 28 in `marts`.
- **Macros** (`macros/`): 7 SQL files in `core/`, `math/`, `backtest/`,
  `testing/`. The two that matter most are `latest_state.sql` and `uniswap_math.sql`.
- **Sources** (`sources.yml`): 9 raw tables under `analytics.analytics` —
  3 pool events (Swap/Mint/Burn), 4 NFPM events
  (Transfer/Increase/Decrease/Collect), pools metadata.
- **Docker Compose**: 2 services, 2 named volumes, no healthcheck, no
  `depends_on`, no restart policy. One mount: host Parquet datalake
  read-only.
- **CI/CD**: none found.
- **.env**: R2 keys, RPC URL, CH creds in plain text on disk.
