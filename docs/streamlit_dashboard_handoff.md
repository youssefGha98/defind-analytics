# Handoff — Streamlit dashboard data access

> For the agent building the new Streamlit project.
> Covers 3 sections: **Pool Overview**, **Price & Volatility**, **Fees & Yield**.
> Source of truth for the full mart catalog: `defind-analytics/docs/frontend_data_contract.md` and `defind-analytics/FEATURES.md`.

---

## 0. TL;DR

- Data lives in a **ClickHouse** database `analytics`. The Streamlit app reads it directly (no API layer yet).
- Read **only public marts** (`mart_*`, `py_*` listed below). Never query `int_*` or `stg_*` — those are internal.
- Only **one pool is indexed**: USDC/WETH 0.05%, address `0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640`. Build pool-agnostic but expect 1 pool of data.
- `token0 = USDC`, so every `*_token0` / `*_token0_equiv` column ≈ **USD**. No conversion needed.

---

## 1. Connecting to ClickHouse

ClickHouse runs in Docker (see `defind-analytics/docker-compose.yml`). Two instances:

| Instance | Host port | When to use |
|---|---|---|
| `clickhouse_local` | **8124** | Default for dev — this is the one that's normally running. |
| `clickhouse` (remote) | 8123 | Production remote; usually not running locally. |

Credentials (from `defind-analytics/.env`):

```
host     = localhost
port     = 8124          # local instance
database = analytics
user     = default
password = 1234
```

### Recommended Streamlit connection pattern

Use `clickhouse-connect`. **Always set timeouts** — without them a stale socket hangs the whole app forever (this bit us repeatedly):

```python
import clickhouse_connect
import streamlit as st

@st.cache_resource
def get_client():
    return clickhouse_connect.get_client(
        host="localhost",
        port=8124,
        database="analytics",
        username="default",
        password="1234",
        connect_timeout=10,         # TCP handshake
        send_receive_timeout=180,   # max query duration before it raises
    )

@st.cache_data(ttl=300)
def run_query(sql: str):
    # query_df returns a pandas DataFrame
    return get_client().query_df(sql)
```

- `@st.cache_resource` keeps a single shared client (don't open one per rerun).
- `@st.cache_data(ttl=300)` caches query results 5 min — the marts refresh on a dbt schedule, not live.

---

## 2. Important conventions & gotchas

1. **Column name for pool differs between marts**:
   - `mart_pool_screener_daily` / `mart_pool_analytics_snapshot` → `pool_address`
   - `mart_volume_daily` / `mart_price_analytics_daily` / `mart_price_intraday` → `pool`
   Filter accordingly. Always lower-case compare: `WHERE lower(pool) = lower('0x88e6…')`.

2. **`_token0` / `_token0_equiv`** = denominated in token0. For this pool token0 is USDC → treat as USD.

3. **Quality flags**: `is_estimated`, `has_swap` exist on several marts. Surface `is_estimated = 1` as a small "estimated" badge.

4. **`updated_at`** column = last dbt refresh time. Show it as "data as of …".

5. **Date span**: daily marts currently cover roughly 2021-05 → 2026-04 (1798 daily rows). Intraday covers ~43k hours.

6. **Don't `SELECT *` on large marts.** The ones below are all small/medium (≤ 45k rows) so it's fine here, but always filter by pool + date range.

---

## 3. Section A — Pool Overview

**Primary marts:**
- `mart_pool_screener_daily` — per-pool × day timeline (1798 rows). The hub: 52 columns.
- `mart_pool_analytics_snapshot` — 1 row per pool, latest values. Use for the "current state" header cards.

### `mart_pool_screener_daily` — full column list

```
pool_address, date, chain, dex, token_pair, token0_symbol, token1_symbol, fee_tier,
current_tick, current_price, has_swap,
tvl_token0_equiv, active_tvl_token0, out_of_range_tvl_token0, capital_utilization,
volume_24h_token0_equiv, volume_7d_token0_equiv, volume_30d_token0_equiv, swap_count_24h,
fees_24h_token0_equiv, fees_7d_token0_equiv, fees_30d_token0_equiv,
gross_fee_apr_daily, gross_fee_apr, gross_fee_apr_30d, gross_fee_apr_90d, incentive_apr,
realized_vol_7d, realized_vol_30d,
adverse_selection_cost_apr_proxy, adverse_selection_cost_apr_proxy_30d, lvr_proxy_daily_token0,
volume_tvl_ratio, fees_per_active_tvl,
position_count, lp_count, lp_concentration_top10_pct, liquidity_concentration_score_raw,
range_width_median_ticks, range_width_p25_ticks, range_width_p75_ticks, range_overlap_density,
log_return_daily, price_return_7d, price_return_30d, drawdown_7d, drawdown_30d,
tvl_change_7d, volume_change_7d, fees_change_7d,
out_of_range_penalty_raw, is_estimated, updated_at
```

### Suggested UI cards → columns

| Card | Columns |
|---|---|
| Header | `token_pair`, `token0_symbol`, `token1_symbol`, `fee_tier`, `current_price`, `current_tick` |
| TVL | `tvl_token0_equiv`, `active_tvl_token0`, `out_of_range_tvl_token0`, `capital_utilization` |
| Volume | `volume_24h_token0_equiv`, `volume_7d_token0_equiv`, `volume_30d_token0_equiv`, `volume_tvl_ratio` |
| Fees & APR | `fees_24h_token0_equiv`, `gross_fee_apr`, `gross_fee_apr_30d`, `fees_per_active_tvl` |
| Volatility | `realized_vol_7d`, `realized_vol_30d` |
| LP structure | `lp_count`, `position_count`, `lp_concentration_top10_pct`, `range_width_median_ticks` |
| Returns / risk | `price_return_7d`, `price_return_30d`, `drawdown_7d`, `drawdown_30d` |
| 7d deltas | `tvl_change_7d`, `volume_change_7d`, `fees_change_7d` |

### Sample queries

```sql
-- Current-state header cards (1 row)
SELECT *
FROM mart_pool_analytics_snapshot
WHERE lower(pool_address) = lower('0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640');

-- Timeline for charts (TVL / volume / fees over time)
SELECT date, tvl_token0_equiv, active_tvl_token0,
       volume_24h_token0_equiv, fees_24h_token0_equiv,
       gross_fee_apr, realized_vol_7d
FROM mart_pool_screener_daily
WHERE lower(pool_address) = lower('0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640')
  AND date >= today() - 180
ORDER BY date;
```

---

## 4. Section B — Price & Volatility

**Primary marts:**
- `mart_price_analytics_daily` — per-pool × day. Daily close, returns, realized vol, drawdown.
- `mart_price_intraday` — per-pool × hour. Hourly OHLCV (43k rows).

### Columns

```
mart_price_analytics_daily:
  pool, date, close_tick, close_price, has_swap,
  log_return, realized_vol_7d, realized_vol_30d, rolling_high, drawdown

mart_price_intraday:
  pool, date, hour, open_tick, close_tick,
  open_price, high_price, low_price, close_price,
  volume_token0, volume_token1, volume_token0_equiv,
  swap_count, log_return_hourly, realized_vol_intraday
```

### Suggested UI

| Chart | Source | Columns |
|---|---|---|
| Price line (daily) | `mart_price_analytics_daily` | `date`, `close_price` |
| Candlestick (hourly) | `mart_price_intraday` | `hour`, `open/high/low/close_price` |
| Realized vol 7d/30d | `mart_price_analytics_daily` | `date`, `realized_vol_7d`, `realized_vol_30d` |
| Drawdown | `mart_price_analytics_daily` | `date`, `drawdown` |
| Intraday vol | `mart_price_intraday` | `hour`, `realized_vol_intraday` |

### Optional — advanced volatility decomposition

`py_subjacent_vol_features_daily` (181 rows) adds RV / BV / jump intensity / HAR forecasts:

```
asset, date, realized_variance_daily, realized_quarticity_daily, bipower_variation_daily,
jump_intensity_daily, realized_volatility_annual_garman_klass, cv_realized_il,
sigma_har_forecast_1d_annual, sigma_har_forecast_7d_annual
```

⚠️ Note: this mart is keyed by **`asset`** (e.g. `'ETH'`), not by `pool`. It's a stable public `py_*` mart. Use it only if the dashboard has a dedicated "advanced volatility" panel; otherwise `mart_price_analytics_daily` is enough.

### Sample queries

```sql
-- Daily price + volatility
SELECT date, close_price, log_return, realized_vol_7d, realized_vol_30d, drawdown
FROM mart_price_analytics_daily
WHERE lower(pool) = lower('0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640')
  AND date >= today() - 180
ORDER BY date;

-- Hourly candlesticks (last 14 days)
SELECT hour, open_price, high_price, low_price, close_price, volume_token0_equiv
FROM mart_price_intraday
WHERE lower(pool) = lower('0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640')
  AND date >= today() - 14
ORDER BY hour;
```

---

## 5. Section C — Fees & Yield

**Primary marts:**
- `mart_volume_daily` — raw daily volume + fees per token.
- `mart_pool_screener_daily` — APR fields (`gross_fee_apr_*`, `fees_per_active_tvl`).

### Columns

```
mart_volume_daily:
  pool, date, volume_token0, volume_token1, volume_token0_equiv,
  swap_count, fees_token0, fees_token1, fees_token0_equiv

APR fields (from mart_pool_screener_daily):
  date, fees_24h_token0_equiv, fees_7d_token0_equiv, fees_30d_token0_equiv,
  gross_fee_apr_daily, gross_fee_apr, gross_fee_apr_30d, gross_fee_apr_90d,
  fees_per_active_tvl, incentive_apr
```

### Suggested UI

| Element | Source | Columns |
|---|---|---|
| Fees over time | `mart_volume_daily` | `date`, `fees_token0_equiv` |
| Volume over time | `mart_volume_daily` | `date`, `volume_token0_equiv`, `swap_count` |
| APR curve | `mart_pool_screener_daily` | `date`, `gross_fee_apr_daily`, `gross_fee_apr` (7d), `gross_fee_apr_30d`, `gross_fee_apr_90d` |
| Fee efficiency | `mart_pool_screener_daily` | `fees_per_active_tvl`, `volume_tvl_ratio` |

### Sample queries

```sql
-- Daily fees & volume
SELECT date, volume_token0_equiv, fees_token0_equiv, swap_count
FROM mart_volume_daily
WHERE lower(pool) = lower('0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640')
  AND date >= today() - 180
ORDER BY date;

-- APR term structure
SELECT date, gross_fee_apr_daily, gross_fee_apr, gross_fee_apr_30d, gross_fee_apr_90d,
       fees_per_active_tvl
FROM mart_pool_screener_daily
WHERE lower(pool_address) = lower('0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640')
  AND date >= today() - 180
ORDER BY date;
```

### ⚠️ Known gaps for Fees & Yield

- `mart_fee_yield_daily` exists but is **DEPRECATED** (a thin view). Do not use it — use `mart_pool_screener_daily` for APR.
- **Fee-per-100-USD yield curves by range width** (the "bond coupon curve" chart in the old QA notebook 04) live in `int_fee_per_100_usd`, which is an **internal model the frontend must NOT read directly**. If the Streamlit dashboard needs that chart, request it be promoted to a public mart (`mart_fee_per_100_usd`) — flag it back to the defind-analytics data team.

---

## 5b. Section D — APR of a given range

**Question this answers:** "if I provide liquidity in the range [tick_lower, tick_upper]
between two dates, what fee APR would I earn?"

### Use `mart_range_apr` — a parametrized view

`mart_range_apr` is a **parametrized view**: it behaves like a table function. You
pass the pool, the tick range, and the date window, and it returns one row with
the gross fee APR for that exact range. It is computed on demand from per-tick
fees + per-tick TVL (`mart_tick_liquidity_volume_daily`), so any arbitrary range
works — not just precomputed ones.

```sql
SELECT * FROM mart_range_apr(
    pool       = '0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640',
    tick_lower = 199987,
    tick_upper = 200107,
    start_date = '2026-03-28',
    end_date   = '2026-04-03'
);
```

Returns:

| column | meaning |
|---|---|
| `pool`, `tick_lower`, `tick_upper`, `start_date`, `end_date` | echo of the parameters |
| `n_days` | number of days in the window that the range had liquidity |
| `total_fees_token0` | total fees earned inside the range over the window (token0 ≈ USD) |
| `mean_daily_fees_token0` | `total_fees_token0 / n_days` |
| `avg_tvl_token0` | average daily TVL sitting inside the range |
| `gross_fee_apr_pct` | **the answer** — gross fee APR, in percent |

Parameter types (ClickHouse requires them): `pool:String`, `tick_lower:Int32`,
`tick_upper:Int32`, `start_date:Date`, `end_date:Date`. `tick_upper` is
**exclusive** (`tick >= lower AND tick < upper`), matching Uniswap v3.

### Streamlit integration

The user picks a price range in the UI → convert price bounds to ticks
(`tick = log(price) / log(1.0001)`, then snap to `tick_spacing`) → call the view:

```python
@st.cache_data(ttl=300)
def range_apr(pool, tick_lower, tick_upper, start_date, end_date):
    sql = """
        SELECT * FROM mart_range_apr(
            pool={pool:String}, tick_lower={lo:Int32}, tick_upper={hi:Int32},
            start_date={sd:Date}, end_date={ed:Date})
    """
    return get_client().query_df(sql, parameters={
        "pool": pool, "lo": tick_lower, "hi": tick_upper,
        "sd": start_date, "ed": end_date,
    })
```

Pass the parameters via `clickhouse-connect`'s `parameters=` argument — do **not**
f-string them into the SQL (the view's `{name:Type}` placeholders are filled by
the driver).

### What it is / is not

- ✅ Works for **any** tick range, not a fixed candidate set.
- ⚠️ **GROSS** fee APR — fees only, before impermanent loss, gas, adverse selection.
  Label it "gross fee APR" in the UI, not "net APR".
- ⚠️ It is the yield on the days the range had liquidity (`n_days`). If the price
  spent whole days outside the range, those days are not in the denominator — so
  it reads as in-range yield, not calendar-time-weighted. Show `n_days` next to
  the APR so the user sees the basis.
- ⚠️ Date-grain (not block-grain). `start_date` / `end_date` are dates.
- ❌ Do **not** use `mart_range_candidates_features` for per-range APR — its
  `expected_fee_apr_proxy` is a pool-level number copied across candidates and
  `gross_fee_apr_inside_range_proxy` has broken units. That mart is not reliable
  for this; `mart_range_apr` supersedes it.

---

## 6. Rules of engagement

- ✅ Read: `mart_pool_screener_daily`, `mart_pool_analytics_snapshot`, `mart_volume_daily`, `mart_price_analytics_daily`, `mart_price_intraday`, `py_subjacent_vol_features_daily`, `mart_range_apr`.
- ❌ Avoid `mart_range_candidates_features` / `mart_range_heatmap_features` for per-range APR — their APR columns are unreliable (pool-level proxy copied across ranges, broken units). Use `mart_range_apr`.
- ❌ Never read `int_*` or `stg_*` models — they are internal and may change shape without notice.
- ❌ Never read `mart_fee_yield_daily` (deprecated).
- ❌ Don't compute scores / recommendations / rankings in the dashboard. The dashboard renders quantitative state; decision logic belongs in a Python engine, not in the UI.
- 🔁 If a needed field isn't in a public mart, ask the defind-analytics team to expose it — don't reach into an internal model.

Full catalog & contract: `defind-analytics/docs/frontend_data_contract.md`.
