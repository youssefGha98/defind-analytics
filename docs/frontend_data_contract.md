# Frontend Data Contract

> **Status**: stable. Frozen for the v1 frontend.
> **Owner**: data team.
> **Updated**: 2026-05-05.

This document defines the **public surface** of `defind-analytics` for the frontend and API. It is the only authoritative list of tables the UI is allowed to read.

If a feature needs data outside this list, the answer is **never** "query an `int_*` directly". The answer is either:

1. promote the missing field into one of the public marts listed below, or
2. add a Python API endpoint that consumes the internal model and returns the decision.

---

## Architecture rule

```
dbt                       → reconstructs and materializes quantitative state/features
Python engines (engines/) → compute decisions / scores / recommendations
Frontend / API            → consumes ONLY the public marts and Python API endpoints
```

The frontend **never** consumes `int_*` models directly. The frontend **never** runs business logic that should live in a Python engine.

---

## §1 Public dbt marts

### Pool-level (per-pool-per-day or current)

| Table | Granularity | Purpose |
|---|---|---|
| `mart_pool_screener_daily` | per-pool × day | **Hub mart**. 50+ KPIs per pool/day: TVL, volume, fees, APR (daily/7d/30d/90d), realized vol, adverse selection / LVR proxies, range structure, drawdown, change %. Use this for any pool timeline view. |
| `mart_pool_analytics_snapshot` | per-pool, current | Same shape as `mart_pool_screener_daily` but 1 row per pool with the latest day's values. Use for "live" pool cards. |
| `mart_volume_daily` | per-pool × day | Raw daily volume + fees per token + token0_equiv. Lighter than the screener; use when only volume/fees are needed. |
| `mart_price_analytics_daily` | per-pool × day | Daily close, log return, realized vol (7d/30d), rolling high, drawdown. |
| `mart_price_intraday` | per-pool × hour | Hourly OHLCV + log_return_hourly + realized_vol_intraday. |
| `mart_tvl_current` | per-pool, current | Total / active / out-of-range TVL + current-bin breakdown. Built on **pool-level Mint/Burn liquidity** (not NFPM). |
| `mart_tvl_daily` | per-pool × day | Daily TVL token0 / token1 / token0_equiv. |

### TVL distribution (chart-ready)

| Table | Granularity | Purpose |
|---|---|---|
| `mart_tvl_distribution_daily_centered` | per-pool × bin × day | Bin-by-bin liquidity distribution, centered on the current tick. |
| `mart_tvl_distribution_daily_metrics` | per-pool × day | Aggregated distribution metrics (current_bin_share, share_overlapping_50/100/250/500_ticks, weighted_*relative_tick). |
| `mart_tvl_distribution_hourly_centered` | per-pool × bin × hour | Same as daily_centered but hourly grain. |
| `mart_tvl_distribution_hourly_metrics` | per-pool × hour | Same as daily_metrics but hourly grain. |

The 4 marts are kept distinct because the frontend liquidity-distribution charts directly consume the bin-by-bin centered tables, while metrics pages use the aggregated metrics tables.

### Tick microstructure

| Table | Granularity | Purpose |
|---|---|---|
| `mart_tick_liquidity_volume_daily` | per-pool × tick × day | **Main public daily tick mart**: tick liquidity (end + TWAP), volume, fees generated, sigma_evc (last/twap/mean/std/p95). |
| `mart_tick_sigma_evc_hourly` | per-pool × tick × hour | Hourly sigma EVC (only if hourly granularity needed in UI). |

`mart_tick_sigma_evc_weekly` is technically public but typically only used by analytics. Frontend should default to the daily mart unless there's a specific weekly view.

### Range analytics

| Table | Granularity | Purpose |
|---|---|---|
| `mart_range_apr` | parametrized view (1 row per call) | **Gross fee APR for an arbitrary tick range over an arbitrary date window.** Call it like a table function: `SELECT * FROM mart_range_apr(pool=…, tick_lower=…, tick_upper=…, start_date=…, end_date=…)`. Computed on demand from per-tick fees + TVL. |
| `mart_range_candidates_features` | per-pool × candidate × day | Candidate range geometry. ⚠️ Its APR / in-range-probability columns are unreliable (pool-level proxy copied across ranges, broken units) — do NOT use them. For per-range APR use `mart_range_apr`. |
| `mart_range_heatmap_features` | per-pool × (lower_tick × upper_tick) | Heatmap grid geometry. Same APR-column caveat as above. |

### Position-level (NFPM)

| Table | Granularity | Purpose |
|---|---|---|
| `mart_position_cards_current` | per-token_id, open only | Position card view. PnL, IL, fees, time-in-range, distance-to-bounds. |
| `mart_position_features_current` | per-token_id, open only | **Materialized as VIEW**. ML/scoring feature subset of `mart_position_cards_current`. Stable contract for the Python scoring engine. |
| `mart_nfpm_position_pnl_current` | per-token_id, all | Full PnL decomposition: principal / fees / IL / hodl. |
| `mart_nfpm_position_lifecycle` | per-token_id, all | Event timeline (mints, burns, increases, decreases, collects, transfers). |

NFPM marts cover **NFT-position analytics**: lifecycle, ownership, fees, wallet-level views, PnL decomposition. They are NOT a substitute for pool-level state (see §3).

### Wallet view

| Table | Granularity | Purpose |
|---|---|---|
| `mart_tracked_lp_wallet_overview_current` | per-wallet, current | Total LP value, PnL, fees, position counts, capital utilization. Hub for wallet pages. |
| `mart_tracked_lp_wallet_exposure_current` | per-wallet × dimension | Long-format breakdown of exposure (by pool, by token, by fee tier...). |
| `mart_tracked_lp_wallet_activity_recent` | per-wallet × event | Recent activity feed (mints, burns, collects, transfers...). |
| `mart_tracked_lp_wallet_pnl_attribution_current` | per-wallet × component | Long-format PnL attribution (waterfall). |

### Backtest

| Table | Granularity | Purpose |
|---|---|---|
| `mart_position_backtest_summary` | per-scenario | dbt-side backtest summary (1 row). Use for the static dbt scenario; for Python-driven backtests, prefer `py_backtest_*`. |

---

## §2 Public Python marts (`py_*`)

### Stable (used in production frontend)

| Table | Engine | Purpose |
|---|---|---|
| `py_lvr_daily` | `engines/lvr_engine.py` | Daily LVR + fee/LVR ratio + swap count. |
| `py_pool_gamma_features_daily` | `engines/gamma_framework.py` | Layer A: break-even vol, realized vol, vol edge, FGY pool. |
| `py_pool_gsr_daily` | `engines/gsr_engine.py` | σ\* (break-even) + σ_realized + edge + IL heuristics. |
| `py_subjacent_vol_features_daily` | `engines/gamma_framework.py` | RV, BV, RQ, jump intensity, HAR-RV forecasts (1d, 7d). |
| `py_position_performance_daily` | `engines/perf_engine.py` | Daily timeline per position: PnL, IL, fees, TIR, share of pool, LVR cumul. |
| `py_backtest_results` | `engines/backtest_engine.py` | Daily backtest timeline. |
| `py_backtest_summary` | `engines/backtest_engine.py` | Backtest terminal summary. |

### Experimental — DO NOT EXPOSE in v1

| Table | Why experimental |
|---|---|
| `py_vol_surface_daily` | POC-level (71 rows). Surface model not validated for production. |
| `py_position_gamma_features_daily` | Currently covers only synthetic positions, not exhaustive real positions. Wait until backfill. |

These tables MAY be queried by analytics/research notebooks, but the API/frontend SHOULD NOT depend on them yet. Promotion to "stable" requires (a) production-grade backfill, (b) reliability budget, (c) explicit signoff.

---

## §3 Critical domain rule — Pool TVL is NOT NFPM-derived

Pool-level liquidity / TVL / tick distribution / EVC denominators MUST be reconstructed from **pool Mint/Burn events**, not from NFPM positions.

NFPM (`mart_nfpm_*`) is non-exhaustive:
- a position can be minted directly on the pool by a non-NFPM caller
- custom managers / ALMs (Arrakis, Bunni, Gamma, Maverick wrappers) mint on the pool without going through the NFPM ERC-721

Using NFPM as the source of pool TVL would undercount active liquidity.

The canonical pool-level state lives in `int_pool_open_positions_current` (intermediate), built directly from `int_lp_events`. `mart_tvl_current` consumes it.

NFPM marts cover the orthogonal use case: NFT position analytics, lifecycle, ownership, fees, wallet-level views, PnL decomposition. They are correct for those use cases but are NOT a substitute for pool-level state.

---

## §4 Conventions the frontend can rely on

1. **Token denomination**: `*_token0` / `*_token0_equiv` columns are denominated in token0 and equal USD only when token0 is a known stablecoin (e.g. USDC). The frontend should NOT re-convert unless exposing a non-stablecoin pool.
2. **`updated_at`** is present on most current/snapshot marts. Use it as "last refreshed" in the UI.
3. **Quality flags**: `is_estimated`, `is_lot_benchmark_valid`, `entry_state_missing`, `tvl_reconciliation_gap` should be surfaced as a "data quality" badge or warning when non-trivial. Do NOT silently drop them.
4. **Pool scoping**: always join via `dim_indexed_pools` or filter on a pool_address that exists there. Pools outside `dim_indexed_pools` are not guaranteed to be backfilled.
5. **Current vs daily**: `_current` / `_snapshot` = 1 row per entity right now ; `_daily` = timeline. Pick the right one for state vs evolution UIs.

---

## §5 What the frontend MUST NOT do

- ❌ Read from any `int_*` model.
- ❌ Read from any `stg_*` model.
- ❌ Read from `mart_fee_yield_daily` (DEPRECATED — use `mart_pool_screener_daily`).
- ❌ Compute scores, recommendations, or ranking logic in SQL/UI. That belongs in Python engines.
- ❌ Reconstruct pool TVL by summing NFPM positions (see §3).
- ❌ Cache aggregations of `mart_tick_*` or `mart_tvl_distribution_*_centered` directly without checking row counts — these are large.

---

## §6 What the frontend MAY do

- ✅ Read any table listed in §1 (public dbt marts) or §2 stable (public Python marts).
- ✅ Filter, aggregate, sort, paginate over them.
- ✅ Join two public marts on `(pool_address, date)` or `(token_id)` as appropriate.
- ✅ Cache server-side responses keyed on `updated_at`.
- ✅ Flag quality-warning fields visibly.

---

## §7 Lifecycle of this contract

This file is the source of truth. To add or remove a public mart:

1. Open a PR that updates this file with the rationale.
2. Get sign-off from data + frontend.
3. Land the dbt change with the agreed-upon column shape.
4. Frontend migrates only after the new column shape is shipped to ClickHouse.

Breaking changes to public marts (column drop / rename / type change) must be:
- announced in this file as deprecated for at least one frontend release before removal,
- tracked in a `# Deprecations` section of the PR description.
