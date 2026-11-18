# Tier 1 Mart Specs — LP Analytics Stack — v2

This document is the authoritative implementation spec for the Tier 1 LP analytics marts.
It reflects the decisions that were locked during review and the final semantics implemented
in the dbt project.

## Context and Constraints

- Storage engine: ClickHouse
- dbt layering: staging -> intermediate -> mart
- All models partition logically by `pool`
- Price convention is always `USDC per WETH`
- Repo sqrt-price convention is always `sp = sqrt(1e12 / close_price)`
- Daily close ordering is deterministic via `(block_number, log_index)`
- Rolling windows are calendar-day dense, not sparse swap-day windows
- `active_range_count` is range-based, not NFT-position-based
- On quiet days, activity metrics like fees and volume default to `0`, not `NULL`
- Ratios remain `NULL` when their denominator is `0`

## Build Order

1. `int_daily_close_dense`
2. `mart_price_analytics_daily`
3. `mart_fee_per_100_usd`
4. `mart_lp_macro_daily`
5. `mart_lvr_daily` remains blocked and out of scope for this batch

## 0. `int_daily_close_dense`

Purpose:
- Dense daily close helper per pool
- Fills swap-date gaps so downstream windows run on contiguous daily rows

Grain:
- One row per `(pool, date)` from first observed swap date to last observed swap date

Source:
- `int_daily_close`

Output:
- `pool`
- `date`
- `close_price`
- `close_tick`
- `close_sqrt_price`
- `has_swap`

Rules:
- Generate a dense date spine per pool between `min(date)` and `max(date)` in `int_daily_close`
- Carry forward only `close_price` and `close_tick`
- Recompute `close_sqrt_price` from `close_price` in the final `SELECT`
- `has_swap = 1` when an observed `int_daily_close` row exists for the day, else `0`

## 1. `mart_price_analytics_daily`

Purpose:
- Daily close-to-close price analytics

Grain:
- One row per `(pool, date)`

Source:
- `int_daily_close_dense`

Outputs:
- `pool`
- `date`
- `close_tick`
- `close_price`
- `has_swap`
- `log_return`
- `realized_vol_7d`
- `realized_vol_30d`
- `rolling_high`
- `drawdown`

Rules:
- `log_return = log(close_price / lag(close_price))`
- First row per pool has `log_return = NULL`
- Carry-forward days have `has_swap = 0` and `log_return = 0`
- `realized_vol_7d` uses a trailing dense 7-row window and is only populated when the window has 7 dense rows
- `realized_vol_30d` uses the same pattern over 30 dense rows
- Use explicit row-count guards so early windows remain `NULL`
- `rolling_high` is the running max of `close_price`
- `drawdown = close_price / rolling_high - 1`

## 2. `mart_fee_per_100_usd`

Purpose:
- Bond-equivalent LP coupon for a hypothetical $100 position at different symmetric widths

Grain:
- One row per `(pool, date, range_width_ticks)`

Sources:
- `int_daily_close_dense`
- `int_active_liquidity_daily`
- `int_active_tvl_daily`
- `mart_volume_daily`
- `stg_pools`

Widths:
- `[50, 100, 200, 500, 1000, 2000]`

Outputs:
- `pool`
- `date`
- `range_width_ticks`
- `tick_lower`
- `tick_upper`
- `close_price`
- `close_tick`
- `active_liquidity`
- `active_tvl_usd`
- `tvl_per_unit_L`
- `fee_per_100_usd_daily`
- `fee_per_100_usd_annual`
- `fee_per_100_usd_7d`
- `fee_per_100_usd_30d`
- `fee_per_100_usd_90d`
- `fee_bps_annual`
- `fee_bps_7d`
- `fee_bps_30d`
- `fee_bps_90d`

Rules:
- Generate widths with `ARRAY JOIN`
- Snap bounds with:
  - `tick_lower = floor((close_tick - W/2) / tick_spacing) * tick_spacing`
  - `tick_upper = ceil((close_tick + W/2) / tick_spacing) * tick_spacing`
- Use repo-consistent V3 formulas with `sp = sqrt(1e12 / close_price)`
- `fee_per_100_usd_daily = (100 / tvl_per_unit_L) / active_liquidity * fees_usdc_equiv`
- Left join sparse daily fees and coalesce `fees_usdc_equiv` to `0`
- If `active_liquidity <= 0`, `tvl_per_unit_L <= 0`, or snapped bounds are invalid, coupon columns are `NULL`
- Rolling windows are computed as average of the daily coupon, then annualized once with `* 365`
- Use `count(metric) OVER ... = N` guards so `_7d/_30d/_90d` are only populated when all N daily values are valid

## 3. `mart_lp_macro_daily`

Purpose:
- Dense pool-level LP macro mart covering capital efficiency, regime, LP flow, burn timing, and range structure

Grain:
- One row per `(pool, date)`

Driver:
- `mart_tvl_daily`

Sources:
- `mart_tvl_daily`
- `int_daily_close_dense`
- `int_active_tvl_daily`
- `mart_volume_daily`
- `mart_price_analytics_daily`
- `mart_fee_per_100_usd` filtered to `range_width_ticks = 500`
- `int_lp_events`
- `int_range_liquidity_daily`
- `stg_pools`

Outputs:
- Dense market context:
  - `close_price`
  - `close_tick`
  - `tvl_usd`
  - `active_tvl_usd`
  - `active_range_count`
  - `fees_usdc_equiv`
  - `volume_usdc_equiv`
  - `swap_count`
- Capital efficiency:
  - `capital_utilization`
  - `volume_tvl_ratio`
  - `active_liquidity_depth`
- Regime:
  - `log_return`
  - `realized_vol_7d`
  - `realized_vol_30d`
  - `apr_daily`
  - `apr_7d`
  - `apr_30d`
  - `apr_90d`
  - `apr7_vol_ratio`
  - `coupon_vol_ratio_500`
- LP flow:
  - `mint_count`
  - `burn_count`
  - `mint_usd`
  - `burn_usd`
  - `net_lp_flow_usd`
  - `lp_turnover`
- Exit timing:
  - `burns_inrange_count`
  - `burns_outofrange_count`
  - `burns_inrange_usd`
  - `burns_outofrange_usd`
  - `pct_burns_inrange`
- Range structure:
  - `open_range_count`
  - `range_width_median_ticks`
  - `range_width_p25_ticks`
  - `range_width_p75_ticks`
  - `lp_concentration_top10_pct`
  - `range_overlap_density`

Rules:
- Use `mart_tvl_daily` as the dense date driver
- Left join sparse daily activity sources and coalesce “no activity” metrics to `0`
- Keep ratios `NULL` when their denominator is `0`
- `apr_daily = fees_usdc_equiv / active_tvl_usd * 365`
- `apr_7d/30d/90d` are trailing averages of `apr_daily`, not re-annualized ratios
- `apr7_vol_ratio = apr_7d / realized_vol_7d`
- `coupon_vol_ratio_500 = mart_fee_per_100_usd.fee_per_100_usd_7d / realized_vol_7d` for `range_width_ticks = 500`
- LP flows use `int_lp_events` amounts valued at the day’s close price
- Burn timing uses `tick_lower <= close_tick < tick_upper` at the burn date’s daily close
- `lp_concentration_top10_pct` ranks open ranges by exact V3 mark-to-market TVL at the day close
- `range_overlap_density` uses the compact overlap-length approximation on `[close_tick - 100, close_tick + 100)`
- Weighted range-width quantiles use `quantileExactWeighted` with `net_liquidity` cast to a supported integer weight when needed

## 4. `mart_lvr_daily`

Status:
- Blocked
- Spec reserved, no SQL in this batch

Future constraints:
- Source is `stg_swaps` at swap grain
- `price_before` must be the immediately preceding swap price by `(block_number, log_index)` within pool
- Incremental mode must seed the last already-processed swap per pool so the first new swap has access to `price_before`
- No approximation should be implemented until the exact formula is signed off

## Cross-Mart Conventions

- Price is always `USDC per WETH`
- `sp = sqrt(1e12 / close_price)` everywhere
- In-range means `tick_lower <= close_tick < tick_upper`
- `NULL` means insufficient data or mathematically undefined; `0` means true zero activity/value
- Quiet days remain in dense marts
- Daily activity metrics default to `0` on quiet days
- Rolling windows are trailing, dense, and inclusive of the current day
- Annualize once only
