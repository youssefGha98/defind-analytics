# Feature Inventory and Lineage

This document is meant to be handed to another LLM or engineer to extend the current dbt project.

## 1. Scope and Current Coverage

- Current raw coverage is a Uniswap V3 USDC/WETH 0.05% pool, plus the Ethereum mainnet NonfungiblePositionManager (NFPM) for tokenId-level position lifecycles.
- The SQL is written with `pool` partitions and is multi-pool ready, but the current source tables are named specifically for the USDC/WETH pool.
- Storage engine is ClickHouse.
- Naming convention: pool values are denominated in `token0`, `token1`, or `token0_equiv` (mixed flow converted to token0 at swap-time price). They equal USD only when `token0` is a known stablecoin (e.g. USDC).
- Main analytical themes currently covered:
  - price and pool state (close, intraday OHLCV, returns, realized vol, drawdown)
  - LP event normalization (mint, burn, NFPM increase / decrease / collect / transfer)
  - daily and current TVL (total, active, distribution, target-block snapshots)
  - daily / hourly / weekly tick-level liquidity reconstruction (boundary deltas)
  - daily swap volume, generated fees, fee APR
  - tick session analytics, active-tick volume at multiple resolutions
  - sigma_evc tick-level capital efficiency (hourly / daily / weekly)
  - bond-equivalent LP coupon by hypothetical width (`mart_fee_per_100_usd`)
  - dense pool-level LP macro mart
  - open owner-range exposure
  - NFPM tokenId-level position state, fees, time-in-range, lifecycle, PnL vs HODL
  - simulated LP position backtests (scenario-driven)

## 2. Layer-by-Layer Inventory

### 2.1 Sources, Staging

| Layer | Model | Grain | Purpose |
|---|---|---|---|
| source | `analytics.uniswap_usdc_weth_swap` | 1 row per swap event | Raw swap events |
| source | `analytics.uniswap_usdc_weth_mint` | 1 row per pool mint event | Raw LP mint events (pool side) |
| source | `analytics.uniswap_usdc_weth_burn` | 1 row per pool burn event | Raw LP burn events (pool side) |
| source | `analytics.pools` | 1 row per pool | Raw pool metadata |
| source | `analytics.uniswap_v3_nfpm_transfer` | 1 row per ERC721 Transfer | Raw NFPM ownership transfers |
| source | `analytics.uniswap_v3_nfpm_increase_liquidity` | 1 row per IncreaseLiquidity event | Raw NFPM liquidity increases |
| source | `analytics.uniswap_v3_nfpm_decrease_liquidity` | 1 row per DecreaseLiquidity event | Raw NFPM liquidity decreases |
| source | `analytics.uniswap_v3_nfpm_collect` | 1 row per Collect event | Raw NFPM collect events |
| staging | `stg_pools` | 1 row per pool | Typed pool metadata (view) |
| staging | `stg_swaps` | 1 row per swap | Typed swap events with normalized amounts and derived `price_token1_in_token0` |
| staging | `stg_mints` | 1 row per pool mint | Typed pool-side mint events |
| staging | `stg_burns` | 1 row per pool burn | Typed pool-side burn events |
| staging | `stg_nfpm_transfers` | 1 row per NFPM transfer | Typed ERC721 transfers in raw token-id space |
| staging | `stg_nfpm_increase_liquidity` | 1 row per NFPM increase | Typed NFPM increases (raw integer amounts) |
| staging | `stg_nfpm_decrease_liquidity` | 1 row per NFPM decrease | Typed NFPM decreases (raw integer amounts) |
| staging | `stg_nfpm_collects` | 1 row per NFPM collect | Typed NFPM collects (raw integer amounts) |

### 2.2 Intermediate

| Sub-folder | Model | Grain | Purpose |
|---|---|---|---|
| core_state | `int_lp_events` | 1 row per LP event | Pool-side mint/burn union with signed deltas |
| core_state | `int_current_state` | 1 row per pool | Latest pool tick and price |
| core_state | `int_daily_close` | 1 row per pool/day | Daily close tick and price (sparse) |
| core_state | `int_daily_close_dense` | 1 row per pool/day | Dense daily close helper with carry-forwarded price/tick |
| core_state | `int_swaps_enriched` | 1 row per swap | Lagged pre-swap state, next-swap interval, per-swap generated fees |
| core_state | `int_tick_changes` | 1 row per constant-tick session | Compressed tick sessions from swaps |
| distribution | `int_tick_boundary_deltas` | 2 rows per LP event | Lower/upper boundary `liquidityNet` deltas (cumsum-ready) |
| distribution | `int_hourly_snapshot_blocks` | 1 row per pool/hour | Dense hourly swap-state spine, carry-forward through LP-only hours |
| distribution | `int_hourly_tick_liquidity_net` | 1 row per pool/hour/tick | Hourly boundary-level liquidityNet state |
| distribution | `int_daily_snapshot_blocks` | 1 row per pool/day | Dense daily swap-state spine |
| distribution | `int_daily_tick_liquidity_net` | 1 row per pool/day/tick | Daily boundary-level liquidityNet state |
| distribution | `int_weekly_tick_liquidity_net` | 1 row per pool/week/tick | Weekly liquidityNet state (last daily snapshot of the week) |
| tvl | `int_range_liquidity_daily` | 1 row per pool/day/range | Dense daily net liquidity per range |
| tvl | `int_active_liquidity_daily` | 1 row per pool/day | In-range liquidity at daily close |
| tvl | `int_active_tvl_daily` | 1 row per pool/day | Exact in-range TVL at daily close (token0) |
| tick_volume | `int_swaps_tick_volume` | 1 row per swap | Volume attributed to the active tick before each swap |
| tick_volume | `int_tick_volume_state_changes` | 1 row per active-tick session | Compressed active-tick volume sessions |
| tick_volume | `int_tick_volume_5m` | 1 row per pool/5m/tick | 5-minute active-tick volume buckets |
| tick_volume | `int_tick_volume_hourly` | 1 row per pool/hour/tick | Hourly active-tick volume |
| tick_volume | `int_tick_volume_daily` | 1 row per pool/day/tick | Daily active-tick volume |
| tick_volume | `int_tick_volume_weekly` | 1 row per pool/week/tick | Weekly active-tick volume (Monday-start) |
| tick_volume | `int_tick_sigma_evc_daily_stats_weekly` | 1 row per pool/week/tick | Weekly distribution stats of daily `sigma_evc_last` |
| nfpm | `int_nfpm_pool_mints` | 1 row per pool-side NFPM Mint | Pool-side Mint signatures attributable to NFPM |
| nfpm | `int_nfpm_token_mint_actions` | 1 row per NFPM mint action | First-Increase Transfer + matched pool Mint per tokenId |
| nfpm | `int_nfpm_positions` | 1 row per tokenId | Immutable NFPM position definition (pool, range, initial owner) |
| nfpm | `int_nfpm_position_liquidity_events` | 1 row per liquidity event | Signed lifecycle deltas per tokenId |
| nfpm | `int_nfpm_position_liquidity_summary` | 1 row per tokenId | Current signed liquidity + lifetime deposit/withdraw totals |
| nfpm | `int_nfpm_position_liquidity_spans` | 1 row per positive-liquidity span | Constant-liquidity intervals between liquidity events |
| nfpm | `int_nfpm_position_collect_events` | 1 row per Collect event | Scaled per-event NFPM collects |
| nfpm | `int_nfpm_position_collect_decomposition` | 1 row per Collect event | Principal-first split between principal returned and residual fees |
| nfpm | `int_nfpm_position_collect_rollup` | 1 row per tokenId | Collect totals + principal/fees decomposition |
| nfpm | `int_nfpm_position_transfer_rollup` | 1 row per tokenId | Current owner, transfer lifecycle, burn-transfer stats |
| nfpm | `int_nfpm_position_entry_state` | 1 row per tokenId | Last observed swap-derived pool state at or before mint |
| nfpm | `int_nfpm_position_increase_lots` | 1 row per Increase event | Capital lots with entry-time benchmark anchors |
| nfpm | `int_nfpm_position_lot_benchmark_summary` | 1 row per tokenId | Aggregate lot-based HODL benchmark state |
| nfpm | `int_nfpm_position_fee_daily` | 1 row per tokenId/day | Chunkable daily generated-fee facts (swap-attribution) |
| nfpm | `int_nfpm_position_fee_summary` | 1 row per tokenId | Lifetime generated-fee summary (aggregated from daily) |
| nfpm | `int_nfpm_position_time_in_range_daily` | 1 row per tokenId/day | Chunkable daily observed time-in-range on swap-state timeline |
| nfpm | `int_nfpm_position_time_in_range_summary` | 1 row per tokenId | Lifetime observed time-in-range summary |
| backtest | `int_position_backtest_inputs` | 1 row per scenario | Canonical scenario inputs (capital, range, block window) from dbt vars |
| backtest | `int_position_backtest_entry_state` | 1 row per scenario | End-of-block entry pool state at `start_block` |
| backtest | `int_position_backtest_entry_liquidity` | 1 row per scenario | Initial composition + liquidity from committed capital |
| backtest | `int_position_backtest_swap_path` | 1 row per scenario/swap | Per-swap accrued-fee path (active position only) |
| backtest | `int_position_backtest_exit_state` | 1 row per scenario | End-of-block exit state and principal mark-to-market |
| backtest | `int_position_backtest_time_in_range` | 1 row per scenario | Observed time-in-range on the swap-state timeline |

### 2.3 Marts

| Sub-folder | Model | Grain | Purpose |
|---|---|---|---|
| tvl | `mart_tvl_daily` | 1 row per pool/day | Exact total pool TVL (token0, token1, token0_equiv) |
| tvl | `mart_tvl_current` | 1 row per pool | Current total/active/out-of-range TVL + current-bin breakdown |
| tvl | `mart_tvl_block_snapshot` | 1 row per pool/`target_block` | Exact end-of-block TVL snapshot for parameterized `target_block` |
| tvl | `mart_tvl_distribution` | 1 row per pool/tick-bin | Current or target-block TVL/liquidity distribution |
| tvl | `mart_tvl_distribution_hourly_centered` | 1 row per pool/hour/tick-bin | Hourly centered local TVL/liquidity distribution |
| tvl | `mart_tvl_distribution_hourly_metrics` | 1 row per pool/hour | Hourly concentration / recentering metrics |
| tvl | `mart_tvl_distribution_daily_centered` | 1 row per pool/day/tick-bin | Daily centered local TVL/liquidity distribution |
| tvl | `mart_tvl_distribution_daily_metrics` | 1 row per pool/day | Daily concentration / recentering metrics |
| lp_analytics | `mart_volume_daily` | 1 row per pool/day | Daily swap volumes and generated fees |
| lp_analytics | `mart_fee_yield_daily` | 1 row per pool/day | Daily fee APR on active TVL |
| lp_analytics | `mart_fee_per_100_usd` | 1 row per pool/day/width | Bond-equivalent LP coupon by hypothetical width |
| lp_analytics | `mart_lp_macro_daily` | 1 row per pool/day | Dense LP macro analytics across regime, flow, range structure |
| lp_analytics | `mart_open_positions` | 1 row per pool/owner/range | Current owner-range exposure with V3 mark-to-market |
| price | `mart_price_analytics_daily` | 1 row per pool/day | Daily price returns, rolling vol, drawdown |
| price | `mart_price_intraday` | 1 row per pool/hour | Hourly OHLCV + within-day intraday volatility |
| price | `mart_tick_daily` | 1 row per pool/day/tick | Time and volume spent at each tick (closed sessions) |
| price | `mart_tick_liquidity_volume_daily` | 1 row per pool/day/tick | Daily tick-level flow aligned with daily tick liquidity |
| price | `mart_tick_sigma_evc_hourly` | 1 row per pool/hour/tick | Hourly tick-level `sigma_evc` capital efficiency |
| price | `mart_tick_sigma_evc_weekly` | 1 row per pool/week/tick | Weekly tick-level `sigma_evc` (with daily distribution stats) |
| nfpm | `mart_nfpm_positions_current` | 1 row per tokenId | Current state per NFPM tokenId (owner, liquidity, collects, MTM) |
| nfpm | `mart_nfpm_open_positions_current` | 1 row per open tokenId | Open subset of `mart_nfpm_positions_current` |
| nfpm | `mart_nfpm_position_lifecycle` | 1 row per tokenId | Lifecycle summary (status, transfers, collect/liquidity timing) |
| nfpm | `mart_nfpm_position_pnl_current` | 1 row per tokenId | Current token0-denominated PnL (principal, fees, HODL benchmark, IL) |
| backtest | `mart_position_backtest_summary` | 1 row per scenario | Summary mart for simulated LP position backtests |

## 3. Source Models

### `analytics.uniswap_usdc_weth_swap`

Raw swap source. Main raw inputs used downstream: `tx_hash`, `block_number`, `log_index`, `block_timestamp`, `contract`, `sender`, `recipient`, `amount0`, `amount1`, `liquidity`, `sqrtPriceX96`, `tick`.

### `analytics.uniswap_usdc_weth_mint` / `analytics.uniswap_usdc_weth_burn`

Raw pool-side LP events. Main raw inputs: `tx_hash`, `block_number`, `log_index`, `block_timestamp`, `contract`, `owner`, (`sender` for mints), `amount`, `amount0`, `amount1`, `tickLower`, `tickUpper`.

### `analytics.pools`

Raw pool metadata. Main fields: `pool`, `fee_bps`, `tick_spacing`, `token0_address`, `token0_symbol`, `token0_decimals`, `token1_address`, `token1_symbol`, `token1_decimals`, `deployment_block`, `deployment_ts`.

### `analytics.uniswap_v3_nfpm_*`

Four NFPM event sources (transfer, increase_liquidity, decrease_liquidity, collect) keyed on the NFPM contract address (`0xC36442…CB88`). Each row carries `tx_hash`, `block_number`, `log_index`, `block_time`, `tokenId`, plus event-specific payload (raw integer amounts, liquidity delta, recipient, from/to addresses).

## 4. Staging Models

### `stg_pools`

Centralized cast point for pool metadata. Outputs all pool columns with `Float64` for `fee_bps`, integer types for decimals. Materialized as `view` (tiny, quasi-static).

### `stg_swaps`

Normalized swap event table.

Outputs: `tx_hash`, `block_number`, `log_index`, `block_time`, `pool`, `token0_symbol`, `token1_symbol`, `sender`, `recipient`, scaled `amount0` / `amount1`, `liquidity`, `tick`, `sqrt_price_x96`, derived `price_token1_in_token0`.

Derivation notes:

- Joins raw swap source to `stg_pools` to fetch decimals and symbols
- Converts raw token amounts into human-readable token units using pool decimals
- Derives `price_token1_in_token0 = 2^192 * 10^(d0 - d1) / sqrtPriceX96^2` using actual pool decimals (no hard-coded `10^12`)
- Incremental on `block_number`

### `stg_mints` / `stg_burns`

Pool-side normalized mint / burn event tables.

Outputs: event keys + `pool`, `token0_symbol`, `token1_symbol`, `owner`, (`sender` for mints), `liquidity_delta`, scaled `amount0` / `amount1`, `tick_lower`, `tick_upper`.

Derivation notes:

- Built through the shared `stg_lp_event(...)` macro
- Uses pool metadata to scale `amount0` / `amount1`
- `stg_burns` does not expose `sender`
- Both incremental on `block_number`

### `stg_nfpm_transfers` / `stg_nfpm_increase_liquidity` / `stg_nfpm_decrease_liquidity` / `stg_nfpm_collects`

Staged NFPM events keyed in raw token-id space (no pool mapping yet). Raw integer amounts and liquidity deltas are kept as-is and only scaled later inside the `nfpm` intermediate layer once each tokenId has been mapped to a pool.

Outputs share `tx_hash`, `block_number`, `log_index`, `block_time`, `token_id`. Event-specific:

- `stg_nfpm_transfers`: `from_address`, `to_address`
- `stg_nfpm_increase_liquidity`: `liquidity_delta_raw`, `amount0_raw`, `amount1_raw`
- `stg_nfpm_decrease_liquidity`: `liquidity_delta_raw`, `amount0_raw`, `amount1_raw`
- `stg_nfpm_collects`: `recipient`, `amount0_raw`, `amount1_raw`

## 5. Intermediate Models

### 5.1 Core State

#### `int_lp_events`

Canonical pool-side LP event table for any state reconstruction. Mints kept positive, burns flipped negative. Cumulative sums on this table reconstruct LP state. Outputs event keys, range keys, signed `liquidity_delta` / `amount0` / `amount1`, `event_type`.

#### `int_current_state`

Latest pool state. Uses `argMax(..., tuple(block_number, log_index))` so ordering is block-aware AND log-aware. Outputs `pool`, `current_tick`, `sqrt_price_current`, `price_token1_in_token0_latest`.

#### `int_daily_close` / `int_daily_close_dense`

Sparse and dense daily close per pool. Sparse uses last swap of the day by `(block_number, log_index)`. Dense builds a calendar-day spine between the first and last swap date per pool, carries `close_price` / `close_tick` forward, and flags `has_swap`. `close_sqrt_price` is recomputed from the carried `close_price` so both stay consistent.

#### `int_swaps_enriched`

Swap-level helper for backtests and per-swap fee math. For each swap, attaches:

- lagged pre-swap state: `tick_before`, `price_before`, `sqrt_price_before`, `liquidity_before`
- post-swap state: `tick_after`, `price_after`, `liquidity_after`
- intervals to the next swap: `next_block_number`, `next_block_time`, `interval_seconds`
- per-swap generated fees in token0 and token1

This is the canonical path table for scenario backtests and tokenId fee attribution.

#### `int_tick_changes`

Compresses swaps into sessions of constant tick. A new session opens whenever the tick changes (multiple swaps in the same block can still open distinct sessions if `log_index` changes the tick). Outputs `session_id`, `tick`, `price_token1_in_token0`, session bounds (`start_block`/`start_time`, `end_block`/`end_time`), `duration_seconds`, `next_tick`, `direction`, `swap_count`, `volume_token0_equiv`. The last open session has `NULL` duration.

### 5.2 Distribution

#### `int_tick_boundary_deltas`

Distribution-oriented LP helper with one lower-boundary row and one upper-boundary row per LP event. Summing `liquidity_net_delta` over `tick_boundary` then cumsumming over ticks reconstructs active liquidity by bin. `boundary_side` is preserved for auditability.

#### `int_hourly_snapshot_blocks` / `int_daily_snapshot_blocks`

Dense hourly / daily pool-state spines. Preserve LP-only hours/days and carry forward the latest swap-derived state, so downstream distribution models can revalue the pool when composition changes without a new swap.

#### `int_hourly_tick_liquidity_net` / `int_daily_tick_liquidity_net` / `int_weekly_tick_liquidity_net`

Time-cumulative `liquidityNet` state at each LP boundary tick, at hourly / daily / weekly resolution. A cumsum over `tick` turns these into full bin liquidity. The weekly snapshot keeps the last observed daily boundary snapshot of the week (stock value, not summed).

### 5.3 TVL

#### `int_range_liquidity_daily`

Dense daily range state. First aggregates LP deltas per `pool/day/range`, then builds a daily spine from the range's first day up to the pool's max activity date and carries net liquidity forward. Filters `net_liquidity > 0`. Spining is done independently per pool and range — a range disappears automatically once cumulative net liquidity falls to zero.

#### `int_active_liquidity_daily`

In-range liquidity per pool/day. Joins `int_daily_close` to `int_range_liquidity_daily`, keeps ranges where `tick_lower <= close_tick < tick_upper`, sums `net_liquidity`. Used as the fee-earned denominator (`share_of_liquidity = position_liquidity / active_liquidity`).

#### `int_active_tvl_daily`

Exact V3 mark-to-market TVL held by in-range positions per pool/day, denominated in `token0`. Out-of-range positions contribute 0. `active_range_count` counts active ranges after aggregation, not distinct NFT positions. Key formulas:

- `sp_low = pow(1.0001, tick_lower / 2.0)`
- `sp_high = pow(1.0001, tick_upper / 2.0)`
- `sp = sqrt(price_token1_in_token0_via_decimals)`
- `amount0 = L * (sp_high - sp) / (sp * sp_high) / 10^token0_decimals`
- `amount1 = L * (sp - sp_low) / 10^token1_decimals`
- `active_tvl_token0 = sum(amount0 + amount1 * price_token1_in_token0)`

### 5.4 Tick Volume

#### `int_swaps_tick_volume`

Swap-level volume attributed to the active tick **immediately before** execution. The first observed swap per pool falls back to `tick_after` and is flagged via `fallback_after_swap`. Outputs swap keys, `active_tick`, `active_price_token1_in_token0`, `volume_token0`, `volume_token1`, `volume_token0_equiv`. Canonical bridge between swap flow and tick-level liquidity studies.

#### `int_tick_volume_state_changes`

Compressed active-tick volume sessions: one row per session where `active_tick` stays constant across consecutive swaps. Preserves `volume_token0`, `volume_token1`, and `volume_token0_equiv` instead of collapsing immediately to a single numeraire.

#### `int_tick_volume_5m` / `int_tick_volume_hourly` / `int_tick_volume_daily` / `int_tick_volume_weekly`

Active-tick volume aggregated to fixed time buckets:

- `_5m`: finest resolution, grain `(pool, bucket_5m, tick)`
- `_hourly`: exact hourly flow, grain `(pool, hour, tick)` — source of truth used to roll up to daily and weekly
- `_daily`: derived from hourly
- `_weekly`: derived from hourly using Monday-start calendar weeks

All four expose `swap_count`, `volume_token0`, `volume_token1`, `volume_token0_equiv`.

#### `int_tick_sigma_evc_daily_stats_weekly`

Weekly distribution stats (mean, p25/p50/p75, etc.) of the daily `sigma_evc_last` series per `(pool, tick)`. Feeds the weekly sigma_evc mart with intra-week dispersion context.

### 5.5 NFPM

The NFPM intermediate layer maps every NFPM `tokenId` to a pool-side Mint and then rebuilds its full lifecycle (liquidity, collects, transfers, fees, time-in-range, lot-based HODL benchmark).

#### `int_nfpm_pool_mints`

Pool-side Mint signatures attributable to NFPM on the tracked pool. Shared truth used to map pool mint events to NFPM tokenIds. Includes `tx_match_ordinal` to disambiguate multiple NFPM mints in the same transaction.

#### `int_nfpm_token_mint_actions`

Canonical NFPM mint actions: mint-like ERC721 transfers (`from = 0x0`) joined to the first IncreaseLiquidity event of the same tokenId in the same transaction, then matched to the exact pool Mint signature.

#### `int_nfpm_positions`

Immutable NFPM position definition per `tokenId`: `pool`, `tick_lower`, `tick_upper`, `initial_owner`, mint tx context, raw `liquidity_delta_raw` of the mint. Mapping from NFPM action to pool Mint uses tx_hash + raw amounts/liquidity + transaction-local ordinal.

#### `int_nfpm_position_liquidity_events`

Signed liquidity lifecycle per mapped tokenId: NFPM Increase rows kept positive, NFPM Decrease rows negated. Source for current liquidity state.

#### `int_nfpm_position_liquidity_summary`

Aggregates `int_nfpm_position_liquidity_events` to one row per tokenId: `current_liquidity_raw`, `total_increase_liquidity_raw`, `total_decrease_liquidity_raw`, `liquidity_event_count`.

#### `int_nfpm_position_liquidity_spans`

Positive-liquidity spans per tokenId: each row is an interval where deployed liquidity stays constant between two consecutive liquidity events. Canonical helper for exact fee-accrual and time-in-range work.

#### `int_nfpm_position_collect_events`

Per-event NFPM collects scaled to human-readable token units, joined to `int_nfpm_positions` for pool decimals.

#### `int_nfpm_position_collect_decomposition`

Event-level decomposition of each Collect into:

- `principal_collected_amount0/1` — principal returned from prior decreases
- `fees_collected_amount0/1` — residual fees

Uses a deterministic principal-first accounting convention within each token leg (decreases create principal liability that is consumed first by subsequent collects).

#### `int_nfpm_position_collect_rollup`

One row per tokenId: `total_collected_amount0/1` plus the principal-first split (`total_principal_collected_amount0/1`, `total_fees_collected_amount0/1`).

#### `int_nfpm_position_transfer_rollup`

Consolidated transfer rollup per tokenId: `current_owner`, ownership timing, `transfer_count`, `burn_transfer_count` (transfers to known burn addresses), last-transfer fields.

#### `int_nfpm_position_entry_state`

Last observed swap-derived pool state at or before each tokenId's pool Mint. This is the entry price/tick anchor for current PnL views. Positions minted before the first observed swap are kept with `entry_state_missing = 1`.

#### `int_nfpm_position_increase_lots`

Capital-lot facts per tokenId: every IncreaseLiquidity (mint and subsequent increases) is treated as a new lot with its own entry-time benchmark anchor. Each lot stores `lot_liquidity_added_raw`, `lot_amount0`, `lot_amount1`, plus the lot's entry pool state.

#### `int_nfpm_position_lot_benchmark_summary`

Aggregates lot-level totals into one row per tokenId: `total_contribution_amount0/1`, `total_hodl_value_token0_current` (HODL benchmark valued at current price), validity flags, lot counts. Downstream PnL percentages are derived from these aggregates, never from arithmetic averages of lot-level percentages.

#### `int_nfpm_position_fee_daily` / `int_nfpm_position_fee_summary`

Generated-fee facts computed swap-by-swap from each tokenId's `liquidity / active_pool_liquidity` share at swap time:

- `_fee_daily`: chunkable, grain `(token_id, date)` — backfillable swap-attribution layer
- `_fee_summary`: aggregated 1-row-per-tokenId contract for downstream marts

Outputs `total_fees_accrued_amount0/1`, `total_fees_accrued_token0_equiv_generated`, `active_swap_count`.

#### `int_nfpm_position_time_in_range_daily` / `int_nfpm_position_time_in_range_summary`

Observed time-in-range on the swap-state timeline. Daily layer splits intervals across day boundaries exactly. Lifetime summary aggregates the daily layer, so quiet periods after the last observed swap are not extrapolated. Outputs `observed_time_in_range_seconds`, `observed_window_seconds`, `observed_out_of_range_seconds`.

### 5.6 Backtest

Scenario-driven LP position simulator. Inputs are passed via dbt vars (`scenario_id`, `pool`, `start_block`, `end_block`, `tick_lower`, `tick_upper`, `capital_committed_token0`).

- `int_position_backtest_inputs` — canonical scenario row from vars.
- `int_position_backtest_entry_state` — end-of-block entry pool state at `start_block` (last observed swap with `block_number <= start_block`).
- `int_position_backtest_entry_liquidity` — initial composition + liquidity derived from `capital_committed_token0` using V3 unit-liquidity math at the entry state.
- `int_position_backtest_swap_path` — per-swap accrued-fee path on `int_swaps_enriched`. Fees accrue only when the simulated position is active before the swap.
- `int_position_backtest_exit_state` — end-of-block exit state and principal mark-to-market at `end_block`.
- `int_position_backtest_time_in_range` — observed time-in-range on the swap-state timeline (exposed as `observed_*` because exact quiet-block timing is not yet modeled).

## 6. Mart Models

### 6.1 TVL marts

#### `mart_tvl_daily`

Exact total pool TVL per day. Outputs `pool`, `date`, `tvl_token0`, `tvl_token1`, `tvl_token0_equiv`, `price_token1_in_token0` (close).

Derivation notes:

- Builds a dense pool/day spine from LP activity dates plus swap dates
- Carries the latest known close price forward across quiet days
- Joins all open ranges from `int_range_liquidity_daily` and values each at the day's close with the exact V3 formula (handles below-range, in-range, above-range via sqrt-price clamping)
- `tvl_token0_equiv = tvl_token0 + tvl_token1 * price_token1_in_token0`

#### `mart_tvl_current`

Current 1-row-per-pool TVL snapshot for dashboarding. Outputs pool state (`current_tick`, `price_token1_in_token0`), TVL decomposition (`total_tvl_token0`, `active_tvl_token0`, `out_of_range_tvl_token0`), `tvl_reconciliation_gap`, current-bin breakdown (`current_bin_tick_lower/upper`, `current_bin_liquidity`, `current_bin_token0/1`, `current_bin_token0_in_token0`, `current_bin_token1_in_token0`, `current_bin_tvl_token0`).

Derivation: `total/active/out_of_range_tvl_token0` are aggregated from `mart_open_positions`. Current-bin metrics come from `mart_tvl_distribution` filtered to `is_active_bin = 1`. `tvl_reconciliation_gap = total - active - out_of_range`.

#### `mart_tvl_block_snapshot`

Exact 1-row-per-pool TVL snapshot at a requested `target_block`, with end-of-block semantics. Same column shape as `mart_tvl_current` plus `target_block`, `snapshot_log_index`, `snapshot_block_time`.

- `target_block` is passed via dbt vars; if omitted, defaults to the latest swap block
- LP state rebuilt from `int_lp_events` filtered to `block_number <= target_block`
- End-of-block pool state from the last swap with `block_number <= target_block`
- `total_tvl_token0` and current-bin metrics reused from `mart_tvl_distribution` (which already supports `target_block`)
- Active and out-of-range TVL recomputed exactly from open ranges and end-of-block price

#### `mart_tvl_distribution`

Current or `target_block` TVL/liquidity distribution across tick bins.

Outputs: bin keys (`tick_lower`, `tick_upper`, `tick_mid`), state (`tick_spacing`, `liquidity`, `is_active_bin`, `current_tick`), market context (`price_token1_in_token0`, `token0_symbol`, `token1_symbol`), bin valuation (`amount0`, `amount1`, `tvl_token0`), normalized share (`pct_liquidity`), charting helpers (`price_lower_token1_in_token0`, `price_upper_token1_in_token0`).

Uses the tick-delta method: `+liquidity_delta` at `tick_lower`, `-liquidity_delta` at `tick_upper`, then cumulative sum over tick. Default mode uses the latest built state from `int_current_state`. `target_block` mode recomputes both swap state and LP state up to the requested block from raw event history.

#### `mart_tvl_distribution_hourly_centered` / `_hourly_metrics`

Hourly local TVL/liquidity distribution centered around the current tick, plus hourly recentering metrics.

`_hourly_centered` outputs snapshot keys (`pool`, `date`, `hour`, `snapshot_block_number`, `snapshot_log_index`, `snapshot_block_time`), market state (`current_tick`, `price_token1_in_token0`, `has_swap_hour`), bin keys, centered coordinates (`relative_tick_lower/upper/mid`), local window context (`overlap_ticks_with_window`, `pct_visible_liquidity`, `pct_visible_tvl`), bin valuation (`liquidity`, `amount0`, `amount1`, `tvl_token0`).

Built from `int_hourly_snapshot_blocks` (dense time spine) and `int_hourly_tick_liquidity_net` (boundary state). Cumsum over tick reconstructs hourly bin liquidity exactly. The model keeps only bins overlapping a configurable centered window.

`_hourly_metrics` is a one-row-per-hour summary derived from the centered distribution: `visible_tvl_token0`, `current_bin_*`, concentration shares (`current_bin_share_visible`, `share_overlapping_50/100/250/500_ticks`), shape metrics (`weighted_mean_relative_tick`, `weighted_abs_relative_tick`, `weighted_std_relative_tick`). Shares are normalized inside the visible centered window only. Designed to measure how fast liquidity recenters after price moves.

#### `mart_tvl_distribution_daily_centered` / `_daily_metrics`

Daily equivalents of the hourly pair, built on the daily spines (`int_daily_snapshot_blocks`, `int_daily_tick_liquidity_net`). Intended as the efficient source of truth for daily/weekly dashboards.

### 6.2 LP analytics marts

#### `mart_volume_daily`

Daily swap volumes and generated fees per pool.

Outputs: keys (`pool`, `date`), raw sides (`volume_token0`, `volume_token1`), normalized notional (`volume_token0_equiv`), counts (`swap_count`), fee splits (`fees_token0`, `fees_token1`), normalized fee total (`fees_token0_equiv`).

Derivation notes:

- Built directly from `stg_swaps` plus `stg_pools.fee_bps`
- Input-side swap direction: `token0_in = max(amount0, 0)`, `token1_in = max(amount1, 0)`
- Fees generated on the input token of each swap
- Token1 fees converted to token0 at the swap's own price, not at a daily average

Key formulas:

- `volume_token0_equiv = sum(token0_in + token1_in * price_token1_in_token0)`
- `fees_token0 = sum(token0_in * fee_bps / 100)`
- `fees_token1 = sum(token1_in * fee_bps / 100)`
- `fees_token0_equiv = sum(fees_token0 + fees_token1 * price_token1_in_token0)`

#### `mart_fee_yield_daily`

Daily fee APR on active TVL. Outputs `pool`, `date`, `tvl_total_token0`, `tvl_active_token0`, `tvl_outofrange_token0`, `fees_token0_equiv`, `apr`.

- `apr = fees_token0_equiv * 365 / tvl_active_token0`
- `tvl_outofrange_token0 = tvl_total_token0 - tvl_active_token0`
- Uses `mart_tvl_daily` as the dense daily spine and keeps dates with no swaps or no active positions

#### `mart_fee_per_100_usd`

Bond-equivalent LP coupon for a hypothetical 100-token0 deployment at discrete symmetric widths. (Name kept for backwards compat; values are token0 unless token0 is USDC.)

Outputs: keys (`pool`, `date`, `range_width_ticks`), snapped range (`tick_lower`, `tick_upper`), market context (`close_price`, `close_tick`), pool context (`active_liquidity`, `active_tvl_token0`), valuation helper (`tvl_per_unit_L`), coupon metrics (`fee_per_100_token0_daily/_annual/_7d/_30d/_90d`), bps variants (`fee_bps_annual/_7d/_30d/_90d`).

- Widths generated with `ARRAY JOIN [50, 100, 200, 500, 1000, 2000]`
- `tick_lower` snapped down, `tick_upper` snapped up to the pool's `tick_spacing`
- Fees default to `0` on quiet days; rolling windows only populate when all N daily rows are non-null

#### `mart_lp_macro_daily`

Dense pool-level LP macro mart spanning capital efficiency, regime, LP flow, exit timing, range structure.

Outputs: dense market context (`close_price`, `close_tick`, `tvl_token0_equiv`, `active_tvl_token0`, `active_range_count`, `fees_token0_equiv`, `volume_token0_equiv`, `swap_count`), capital efficiency (`capital_utilization`, `volume_tvl_ratio`, `active_liquidity_depth`), regime (`log_return`, `realized_vol_7d/30d`, `apr_daily/_7d/_30d/_90d`, `apr7_vol_ratio`, `coupon_vol_ratio_500`), LP flow (`mint_count`, `burn_count`, `mint_token0_equiv`, `burn_token0_equiv`, `net_lp_flow_token0_equiv`, `lp_turnover`), burn timing (`burns_inrange_count`, `burns_outofrange_count`, `burns_inrange_token0_equiv`, `burns_outofrange_token0_equiv`, `pct_burns_inrange`), range structure (`open_range_count`, `range_width_median/p25/p75_ticks`, `lp_concentration_top10_pct`, `range_overlap_density`).

- Uses `mart_tvl_daily` as the dense date spine
- Sparse activity sources are left-joined and coalesced where a true "no activity" day is implied; ratios remain `NULL` when their denominator is `0`
- Rolling APRs are trailing averages of `apr_daily`, not re-annualized window ratios
- Joins `mart_fee_per_100_usd` filtered to `range_width_ticks = 500` for the coupon-vs-vol regime signal
- Values open ranges with exact V3 formulas to derive top-10 concentration

#### `mart_open_positions`

Current owner-range exposure with exact V3 mark-to-market.

Outputs: owner-range keys (`pool`, `owner`, `tick_lower`, `tick_upper`), state (`net_liquidity`, `net_amount0`, `net_amount1`), market context (`current_tick`, `price_token1_in_token0`, `tick_spacing`, `token0_symbol`, `token1_symbol`), status and value (`is_active`, `position_amount0`, `position_amount1`, `position_token0`).

- Cumulative owner-range state rebuilt from `int_lp_events`
- Current activity state attached from `int_current_state`
- Current token holdings recomputed from `net_liquidity` and the current pool price using exact V3 formulas
- `position_token0 = position_amount0 + position_amount1 * price_token1_in_token0` — exact current MTM
- `net_amount0` / `net_amount1` are kept as historical net deposited token flows, not current holdings

### 6.3 Price marts

#### `mart_price_analytics_daily`

Daily close-to-close price analytics from `int_daily_close_dense`. Carry-forward days remain in the output with `has_swap = 0`.

Outputs: `pool`, `date`, `close_tick`, `close_price`, `has_swap`, `log_return`, `realized_vol_7d`, `realized_vol_30d`, `rolling_high`, `drawdown`.

- `log_return = ln(close_t / close_{t-1})`
- `realized_vol_Nd = sqrt(E[r^2] - E[r]^2 over trailing N dense rows) * sqrt(365)`
- `drawdown = close_price / rolling_high - 1`

#### `mart_price_intraday`

Hourly OHLCV + within-day intraday volatility, built directly from `stg_swaps`.

Outputs: keys (`pool`, `date`, `hour`), hourly state (`open_tick`, `close_tick`), OHLC (`open_price`, `high_price`, `low_price`, `close_price`), flow (`volume_token0`, `volume_token1`, `volume_token0_equiv`, `swap_count`), returns (`log_return_hourly`, `realized_vol_intraday`).

- Open/close use the first/last swap of the hour by `(block_number, log_index)`
- `realized_vol_intraday` is the within-day stddev of hourly log returns, repeated on each hourly row of the same day for charting convenience

#### `mart_tick_daily`

Daily aggregate of tick sessions per pool. Outputs `pool`, `date`, `tick`, `time_seconds`, `volume_token0`, `swap_count`. Built from `int_tick_changes`, closed sessions only, day assigned by `toDate(start_time)`. Open last session excluded.

Typical uses: time in range, tick residency, volume by tick, session density by price level.

#### `mart_tick_liquidity_volume_daily`

Daily tick-level flow aligned with daily tick liquidity. Outputs `pool`, `date`, `tick`, `tick_liquidity_end`, `tick_liquidity` (TWAP), `volume_token0_equiv`, `volume_per_tick_liquidity_last`, `sigma_evc_last`, plus daily distribution stats of hourly `sigma_evc_*` variants. Designed as the daily warehouse helper for capital-efficiency studies at tick level.

#### `mart_tick_sigma_evc_hourly`

Hourly tick-level `sigma_evc` based on exact hourly flow (`int_tick_volume_hourly`) and hour-end liquidity snapshots (`int_hourly_tick_liquidity_net`). Outputs `pool`, `date`, `hour`, `tick`, `tick_liquidity_end`, `volume_token0_equiv`, `volume_per_tick_liquidity_last`, `sigma_evc_last`.

#### `mart_tick_sigma_evc_weekly`

Weekly tick-level `sigma_evc` based on weekly flow (`int_tick_volume_weekly`), week-end liquidity (`int_weekly_tick_liquidity_net`), daily liquidity TWAP, and the weekly distribution of daily `sigma_evc_last` (`int_tick_sigma_evc_daily_stats_weekly`).

### 6.4 NFPM marts

#### `mart_nfpm_positions_current`

Current state of each mapped NFPM tokenId.

Outputs: identity (`token_id`, `pool`, `tick_lower`, `tick_upper`), ownership (`current_owner`, `is_current_owner_burn_like`), liquidity state (`current_liquidity_raw`, `is_open`, `is_active`), MTM of still-deployed liquidity (`current_position_amount0/1`, `current_position_token0`), collect totals with principal/fees split (`total_principal_collected_amount0/1`, `total_fees_collected_amount0/1`), transfer lifecycle context.

#### `mart_nfpm_open_positions_current`

Open subset of `mart_nfpm_positions_current` (rows where `current_liquidity_raw > 0`).

#### `mart_nfpm_position_lifecycle`

Lifecycle summary per tokenId combining current state, transfer history, collect timing, liquidity timing, and principal-first collect decomposition. Outputs include `lifecycle_status` (open/closed/burned), boolean lifecycle flags, `observed_lifetime_seconds`.

#### `mart_nfpm_position_pnl_current`

Current token0-denominated PnL per tokenId. Principal, collected fees, uncollected (accrued-but-not-collected) fees, lot-based HODL benchmark, and impermanent loss are exposed separately.

Key columns:

- principal owed: `current_principal_owed_amount0/1`, `principal_owed_token0_equiv_current`
- deployed principal MTM: `current_deployed_principal_token0`, `current_principal_wealth_token0`
- accrued fees (lifetime, swap-attribution): `total_fees_accrued_amount0/1`
- collected fees wealth (priced at current price): `current_collected_fee_wealth_token0`
- uncollected fees wealth: `current_uncollected_fee_wealth_token0`
- total fee wealth: `current_fee_wealth_token0 = collected + uncollected`
- total wealth: `current_total_wealth_token0`
- benchmark: `total_hodl_value_token0_current` from `int_nfpm_position_lot_benchmark_summary`
- IL: derived from principal vs HODL
- time-in-range fields from `int_nfpm_position_time_in_range_summary`

Important semantic note: summing wealth across all tokenIds is **not** comparable to current pool TVL — closed/burned positions remain part of the historical tokenId population.

### 6.5 Backtest mart

#### `mart_position_backtest_summary`

Summary mart for simulated LP position backtests. Exposes scenario inputs, entry/exit pool state, accrued fees on the swap path, observed time-in-range, and performance decomposition vs initial capital and HODL.

Outputs: scenario keys (`scenario_id`, `pool`, `start_block`, `end_block`, `tick_lower`, `tick_upper`, `capital_committed_token0`), entry/exit state, `total_fees_accrued_token0_equiv`, `final_principal_token0`, `total_wealth_token0`, HODL benchmark, `observed_time_in_range_seconds`, `observed_window_seconds`.

## 7. End-to-End Lineage

### 7.1 Metadata Lineage

- `analytics.pools`
  → `stg_pools`
  → used by every staging swap/mint/burn model and most marts (decimals, symbols, fee_bps, tick_spacing)

### 7.2 Swap / Price Lineage

- `analytics.uniswap_usdc_weth_swap`
  → `stg_swaps`
  → `int_current_state`
  → `mart_open_positions`, `mart_tvl_current`, `mart_tvl_distribution`, `mart_tvl_block_snapshot`
  → `int_hourly_snapshot_blocks`, `int_daily_snapshot_blocks` → centered distribution marts

- `analytics.uniswap_usdc_weth_swap`
  → `stg_swaps`
  → `int_daily_close` → `int_daily_close_dense`
  → `mart_price_analytics_daily`
  → `int_active_liquidity_daily` → `int_active_tvl_daily` → `mart_tvl_daily` → `mart_fee_yield_daily`, `mart_lp_macro_daily`, `mart_fee_per_100_usd`

- `analytics.uniswap_usdc_weth_swap`
  → `stg_swaps`
  → `mart_price_intraday`

- `analytics.uniswap_usdc_weth_swap`
  → `stg_swaps`
  → `int_swaps_enriched`
  → `int_position_backtest_swap_path` → `mart_position_backtest_summary`
  → `int_nfpm_position_fee_daily` → `int_nfpm_position_fee_summary` → `mart_nfpm_position_pnl_current`

- `analytics.uniswap_usdc_weth_swap`
  → `stg_swaps`
  → `int_tick_changes` → `mart_tick_daily`

- `analytics.uniswap_usdc_weth_swap`
  → `stg_swaps`
  → `mart_volume_daily` → `mart_fee_yield_daily`, `mart_lp_macro_daily`

### 7.3 Tick-Volume / Sigma EVC Lineage

- `analytics.uniswap_usdc_weth_swap`
  → `stg_swaps`
  → `int_swaps_tick_volume`
  → `int_tick_volume_state_changes`, `int_tick_volume_5m`, `int_tick_volume_hourly`
  → `int_tick_volume_daily`, `int_tick_volume_weekly` (rolled up from hourly)
  → `mart_tick_sigma_evc_hourly` (with `int_hourly_tick_liquidity_net`)
  → `mart_tick_liquidity_volume_daily` (with `int_daily_tick_liquidity_net`)
  → `mart_tick_sigma_evc_weekly` (with `int_weekly_tick_liquidity_net`, `int_tick_sigma_evc_daily_stats_weekly`)

### 7.4 LP Event / Range State Lineage (pool side)

- `analytics.uniswap_usdc_weth_mint` → `stg_mints`
  `analytics.uniswap_usdc_weth_burn` → `stg_burns`
  → `int_lp_events`
  → `int_range_liquidity_daily` → `int_active_liquidity_daily` → `int_active_tvl_daily` → `mart_tvl_daily`
  → `mart_open_positions` → `mart_tvl_current`
  → `mart_tvl_distribution` → `mart_tvl_block_snapshot`
  → `int_tick_boundary_deltas` → `int_hourly_tick_liquidity_net`, `int_daily_tick_liquidity_net`, `int_weekly_tick_liquidity_net`
  → centered distribution marts (hourly/daily) and tick-liquidity marts

### 7.5 NFPM Lineage

- `analytics.uniswap_v3_nfpm_*` → `stg_nfpm_*`
  → `int_nfpm_pool_mints`, `int_nfpm_token_mint_actions` → `int_nfpm_positions`
  → `int_nfpm_position_liquidity_events` → `int_nfpm_position_liquidity_summary`, `int_nfpm_position_liquidity_spans`
  → `int_nfpm_position_collect_events` → `int_nfpm_position_collect_decomposition` → `int_nfpm_position_collect_rollup`
  → `int_nfpm_position_transfer_rollup`
  → `int_nfpm_position_entry_state`, `int_nfpm_position_increase_lots` → `int_nfpm_position_lot_benchmark_summary`
  → `int_nfpm_position_fee_daily` → `int_nfpm_position_fee_summary` (uses `int_swaps_enriched`)
  → `int_nfpm_position_time_in_range_daily` → `int_nfpm_position_time_in_range_summary` (uses `int_nfpm_position_liquidity_spans`)
  → `mart_nfpm_positions_current`, `mart_nfpm_open_positions_current`
  → `mart_nfpm_position_lifecycle`
  → `mart_nfpm_position_pnl_current`

### 7.6 Backtest Lineage

- dbt vars (`scenario_id`, `pool`, `start_block`, `end_block`, `tick_lower`, `tick_upper`, `capital_committed_token0`)
  → `int_position_backtest_inputs`
  → `int_position_backtest_entry_state` (anchored on `stg_swaps` ≤ `start_block`)
  → `int_position_backtest_entry_liquidity`
  → `int_position_backtest_swap_path` (uses `int_swaps_enriched`)
  → `int_position_backtest_exit_state`
  → `int_position_backtest_time_in_range`
  → `mart_position_backtest_summary`

### 7.7 Final Feature Lineage by Metric

- `current_tick` ← `stg_swaps.tick`, latest swap by `(block_number, log_index)`
- `price_token1_in_token0_latest` ← `stg_swaps.sqrt_price_x96` derived via pool decimals, latest swap
- `close_price` ← `stg_swaps.price_token1_in_token0`, last swap of each day by `(block_number, log_index)`
- dense `close_price` ← `int_daily_close.close_price`, carry-forward across quiet calendar days within each pool
- `log_return` / `realized_vol_7d/30d` ← rolling on `mart_price_analytics_daily.close_price`, annualized with `sqrt(365)`
- hourly OHLC ← first/last hourly swaps by `(block_number, log_index)`
- `realized_vol_intraday` ← within-day stddev of `mart_price_intraday.log_return_hourly`
- `active_liquidity` ← `int_range_liquidity_daily.net_liquidity` filtered by `tick_lower <= close_tick < tick_upper`
- `active_tvl_token0` ← `int_range_liquidity_daily.net_liquidity` × `int_daily_close.close_price` × `stg_pools.token_decimals` via exact V3 formulas
- `tvl_token0_equiv` ← all open ranges in `int_range_liquidity_daily` × dense daily close × exact V3 formulas
- `fees_token0_equiv` ← `stg_swaps.amount0/1` + `stg_swaps.price_token1_in_token0` × `stg_pools.fee_bps`
- `fee_per_100_token0_daily` ← `mart_volume_daily.fees_token0_equiv` × `int_active_liquidity_daily.active_liquidity` × dense close from `int_daily_close_dense` via exact V3 unit-liquidity valuation
- `apr` ← `fees_token0_equiv * 365 / tvl_active_token0`
- `apr7_vol_ratio` ← `mart_lp_macro_daily.apr_7d` / `mart_price_analytics_daily.realized_vol_7d`
- `coupon_vol_ratio_500` ← `mart_fee_per_100_usd.fee_per_100_token0_7d` (width 500) / `realized_vol_7d`
- `time_seconds` by tick ← `stg_swaps.block_time` × constant-tick sessions in `int_tick_changes`
- `position_token0` (open positions) ← `int_lp_events.liquidity_delta` + `int_current_state.price_token1_in_token0_latest` + `stg_pools.token_decimals` via exact V3 formulas
- `tvl_distribution.tvl_token0` ← `int_lp_events.liquidity_delta` + latest or target-block swap state × exact V3 bin valuation
- `sigma_evc_last` (hourly) ← `int_tick_volume_hourly.volume_token0_equiv` / `int_hourly_tick_liquidity_net.liquidity_net` cumulative over tick
- NFPM `total_fees_accrued_amount0/1` ← per-swap `liquidity_share = position_liquidity / active_pool_liquidity` × per-swap pool fees, summed over `int_nfpm_position_liquidity_spans` ∩ swap path
- NFPM `current_fee_wealth_token0` ← collected (`int_nfpm_position_collect_rollup.total_fees_collected`) priced at current price + uncollected (`fee_summary − collected`) priced at current price
- NFPM HODL benchmark ← `int_nfpm_position_lot_benchmark_summary.total_hodl_value_token0_current`
- backtest `total_fees_accrued_token0_equiv` ← `int_position_backtest_swap_path` summed over the active interval

## 8. Important Semantics and Constraints

- All pool values use `token0` / `token0_equiv` as their numeraire. They equal USD only when `token0` is a known stablecoin (currently USDC). Any historical `_usd` / `_usdc` column has been renamed to `_token0` / `_token0_equiv`.
- Daily close, current state, and snapshots use deterministic ordering by `(block_number, log_index)`.
- `mart_tvl_daily` and `int_range_liquidity_daily` are dense spines: quiet days are preserved. Stale downstream tables can create false flat periods if they are not rebuilt.
- `int_daily_close_dense` makes calendar-day windows explicit: quiet swapless days stay in the series with `has_swap = 0`.
- `mart_volume_daily.fees_token0_equiv` is exact at the swap level for generated fees (no daily-average reprice).
- `mart_open_positions.position_token0` is exact current MTM. `net_amount0` / `net_amount1` remain historical net flow fields, not current holdings.
- `int_active_tvl_daily.active_range_count` is range-based, not NFT-position-based.
- `mart_tick_daily` excludes the still-open final session and assigns sessions by `start_time` day.
- `mart_tvl_distribution` is **not** daily — it is a snapshot at the latest block or a requested `target_block`.
- `mart_tvl_distribution_*_centered` marts only keep bins overlapping a configurable centered window. `pct_visible_*` are normalized inside that visible window only, **not** vs. the global pool distribution.
- `int_swaps_tick_volume` attributes volume to the active tick **before** each swap. The first observed swap per pool falls back to `tick_after` and is flagged via `fallback_after_swap`.
- NFPM mapping (`int_nfpm_token_mint_actions` → `int_nfpm_pool_mints` → `int_nfpm_positions`) requires both raw amount equality and a transaction-local ordinal to disambiguate multi-mint transactions. Positions whose pool Mint isn't found are dropped (not silently mismatched).
- NFPM collect decomposition uses a deterministic principal-first convention: prior decreases create principal liabilities consumed first by subsequent collects. Residual is fees.
- NFPM `int_nfpm_position_entry_state.entry_state_missing = 1` flags positions minted before the first observed swap. Their lot-based benchmark is incomplete.
- NFPM time-in-range and fee accrual operate on the swap-state timeline. Quiet periods after the last observed swap are **not** extrapolated, so `observed_window_seconds` < real lifetime when a position is still open and the pool has been quiet.
- `mart_nfpm_position_pnl_current` is per-tokenId. **Do not** sum wealth across all tokenIds and compare to current pool TVL — closed/burned positions remain in the population.
- Position backtest `observed_*` time-in-range fields use the swap-state timeline only (no quiet-block extrapolation). `int_position_backtest_inputs` reads scenario fields from dbt vars.

## 9. Open Extension Ideas

These are natural next steps that are not yet implemented.

- Per-owner fee attribution at the pool-side (non-NFPM) layer, similar to `int_nfpm_position_fee_*` but keyed on `(owner, tick_lower, tick_upper)`.
- Multi-pool deployment: extend sources beyond USDC/WETH 0.05% and verify all `pool` partitioning still holds. The SQL is ready; only source naming is pool-specific.
- Quiet-block time-in-range extrapolation: use `int_lp_events` + a block-clock to extend NFPM and backtest `observed_*` metrics into the gap between the last observed swap and the position's lifetime end.
- Multi-scenario backtest fan-out: today scenarios are parameterized via dbt vars (one row per run). A scenario seed table would let the engine sweep many ranges/widths/blocks in one build.
- Cross-pool `sigma_evc` benchmarks: compare tick-level capital efficiency across pools at the same tick distance from spot.
- Block-aware ownership history for non-NFPM pool LPs (current `mart_open_positions` is owner-range only).
- Data quality monitors: days with swaps but missing close, stale carried price streaks, `tvl_reconciliation_gap` alerts, NFPM mappings dropped because of unmatched pool Mint.

## 10. Short Prompt Starter for Another LLM

Use this if you want to hand off quickly:

> You are extending a dbt + ClickHouse analytics project for a Uniswap V3 USDC/WETH pool plus the Ethereum NFPM. Read the model inventory and lineage in `analyses/ops/feature_inventory_and_lineage.md`. Respect the current semantics: pool values use `token0` / `token0_equiv` as numeraire (equal to USD only when token0 is a stablecoin); daily close ordering uses `(block_number, log_index)`; `mart_volume_daily.fees_token0_equiv` is exact swap-level fee conversion; `mart_open_positions.position_token0` is exact current MTM while `net_amount0/net_amount1` remain historical flow fields; `mart_tvl_distribution` is snapshot-based, not daily; NFPM marts are per-tokenId and must not be summed against pool TVL; backtest `observed_*` fields are swap-state timeline only. Propose and implement missing high-value features without breaking the current marts and their tests.

---

## 11. V1 Product Layer

The product layer turns the raw evidence layer (sections 1–10) into feature/serving
marts that power DeFine's app surfaces (Pool Screener, Pool Analytics, Wallet,
Positions, Position Detail, Range Optimizer). It is **factual only** — scoring,
recommendations, decision labels, "why this range" / "current thesis" / "main risk"
text live in a Python decision engine (Phase 2), never in dbt.

V1 scope: 1 indexed pool (USDC/WETH 0.05%). All values stay in `token0` /
`token0_equiv` (no USD conversion layer yet). No `pool_paid_volatility`, no flow
quality, no regime classification, no Python engine, no API yet.

### 11.1 Universe dimension

| Folder | Model | Grain | Purpose |
|---|---|---|---|
| marts/dim | `dim_indexed_pools` | 1 row per pool | Canonical product universe; every product mart scopes to it. |

### 11.2 Product intermediates

| Folder | Model | Grain | Purpose |
|---|---|---|---|
| intermediate/product | `int_adverse_selection_proxy_daily` | 1 row per (pool, date) | LVR (`sigma^2/8`) heuristic — APR + daily token0 drag + 7d/30d variants. `is_estimated=1`. |
| intermediate/product | `int_range_candidates_grid` | 1 row per (pool, date, candidate_id) | 6 candidate ranges per pool/day (centered ±1/2/5/10% + shifted up/down 2%), snapped to tick_spacing. |

### 11.3 Product marts

All under `marts/product/`. Materialized as tables.

| Model | Grain | Purpose |
|---|---|---|
| `mart_pool_screener_daily` | 1 row per (pool, date) | Screener feature mart — TVL, volume, fees, APR, realized vol, AS proxy, returns, drawdowns, change deltas, concentration. |
| `mart_pool_analytics_snapshot` | 1 row per pool | Latest screener row + live current_tick/price + NFPM lp_count/position_count. |
| `mart_pool_distribution_snapshot` | 1 row per (pool, tick_lower, tick_upper) | mart_tvl_distribution + 7d volume/fees/fees_per_unit_liquidity per bin + indexed-pool scope. |
| `mart_position_cards_current` | 1 row per open NFPM token_id | Position card facts: range, MTM, status, fees, IL, age, observed time-in-range. |
| `mart_position_features_current` | 1 row per open NFPM token_id | Pure feature inputs for Python position scoring (distances, width, capital utilization, pool regime context). |
| `mart_tracked_lp_wallet_overview_current` | 1 row per wallet | LP-only aggregates on indexed pools, auto-discovery via `current_owner`. Coverage metadata hardcoded. |
| `mart_tracked_lp_wallet_exposure_current` | 1 row per (wallet, exposure_dimension, exposure_name) | V1 dimensions: by_token, by_status, by_pool. |
| `mart_tracked_lp_wallet_pnl_attribution_current` | 1 row per (wallet, component) | Components: fees, rewards (V1 NULL), IL, AS proxy (V1 NULL), gas (V1 NULL), net_pnl. |
| `mart_tracked_lp_wallet_activity_recent` | 1 row per NFPM event | Last 90d feed of mint/burn/transfer/increase/decrease/collect events. Description deterministic. |
| `mart_range_candidates_features` | 1 row per (pool, date, candidate_id) | Optimizer features per candidate: fees inside, IRP 7d/30d (inline), AS proxy, expected APR proxy. |
| `mart_range_heatmap_features` | 1 row per (pool, lower_tick, upper_tick) — latest only | 8×8 grid of tick-offset cells around close_tick. Powers heatmap. |

### 11.4 Forbidden in dbt (Python-owned)

These fields **must not** appear in any dbt mart:

```
pool_score, net_lp_attractiveness_score, range_score, range_health_score, risk_score
decision_label, recommendation_label, reason_badges
why_this_range_text, current_thesis, main_risk, recommendation_reason
suggested_action_text, expected_impact, primary_cta, secondary_cta
trade_flow_quality_score, market_regime_label
```

dbt provides the underlying metrics; Python composes them into decisions.

### 11.5 V1 limitations (carry forward into Phase 2)

- **USD conversion**: every product mart is in `token0` / `token0_equiv`. The single indexed pool is USDC/WETH so `token0_equiv = USD` in practice. Multi-pool needs an `int_usd_price_daily` extension point.
- **Pool-paid volatility / volatility spread**: all columns return NULL stubs in V1. Phase 2 will add liquidity-weighted sigma_evc aggregation around active ticks.
- **Per-position adverse selection**: pool-level only in V1 (`mart_pool_screener_daily.adverse_selection_cost_apr_proxy`). Per-position attribution = Python derivation.
- **`fees_lost_out_of_range_token0`**: counterfactual, requires range-overlay simulation. NULL in V1.
- **Wallet activity attribution**: V1 attributes liquidity/collect events to the tokenId's *current* owner. Historical-correct asof attribution deferred.
- **Backtests**: V1 keeps the existing single-scenario `mart_position_backtest_summary` (dbt vars). Multi-strategy fan-out is Python.
- **`lp_count` per day**: V1 NULL — only the current-state lp_count surfaces (in `mart_pool_analytics_snapshot`). Daily resolved-owner LP counts need an owner-resolved cumulative liquidity mart.
- **Flow quality**: not in V1 dbt. Would need `int_pool_flow_features_daily` (large_swap_count, directional_volume_share, etc.) — Phase 2.
- **Regime detection**: raw features for regime are in `mart_pool_screener_daily` (returns, vols, change deltas, drawdown). Classification = Python.

### 11.6 Tests for the V1 product layer

- Schema-level: `relationships` to `dim_indexed_pools.pool_address` from every product mart that has `pool_address`; `unique` on identity columns; `accepted_values` for enums (status, candidate_id, exposure_dimension, activity_type, coverage_scope).
- Singular tests in `tests/product/`:
  - `test_mart_pool_screener_daily_unique_pool_date.sql`
  - `test_mart_pool_screener_daily_capital_utilization_bounds.sql`
  - `test_mart_position_features_capital_utilization_bounds.sql`
  - `test_mart_position_cards_status_in_range_consistency.sql`
  - `test_mart_tracked_lp_wallet_exposure_pct_bounds.sql`
  - `test_mart_range_candidates_features_irp_bounds.sql`
