# defind-analytics — Inventaire complet des features

> Source de vérité pour le design du frontend. Toutes les colonnes ont été extraites directement de ClickHouse (`DESCRIBE`).
> Périmètre couvert au 2026-05-05 : 1 pool indexé en V3 (USDC/WETH 0.05%, `0x88e6a0c2…`). Pas d'autre fee tier en intraday pour l'instant.

---

## Table des matières

- [§0 Vue d'ensemble](#0-vue-densemble)
- [§1 Couches & flux de données](#1-couches--flux-de-données)
- [§2 Features par THÈME (recommandé pour le front)](#2-features-par-thème-recommandé-pour-le-front)
- [§3 Marts dbt — détail colonne par colonne](#3-marts-dbt--détail-colonne-par-colonne)
- [§4 Marts Python — détail colonne par colonne](#4-marts-python--détail-colonne-par-colonne)
- [§5 Engines Python — endpoints calcul](#5-engines-python--endpoints-calcul)
- [§6 Notebooks d'analyse](#6-notebooks-danalyse)
- [§7 Macros dbt réutilisables](#7-macros-dbt-réutilisables)
- [§8 Pour le design front — recommandations](#8-pour-le-design-front--recommandations)

---

## §0 Vue d'ensemble

| Famille | Granularité | Nb tables | Volume actuel |
|---|---|---|---|
| **mart_pool_*** (vue pool) | per-pool-per-day / -hour / current | 5 | 1 798 jours × 1 pool |
| **mart_position_*** (NFPM) | per-token_id current/lifecycle | 6 | 4 058 positions ouvertes / 114 358 lifetime |
| **mart_price_*** (microstructure) | per-pool-per-hour / -day | 2 | 43 118 heures |
| **mart_tick_*** (sigma EVC, distributions) | per-pool-per-tick-per-day/hour | 5 | 805k–2.3M lignes |
| **mart_tvl_*** (distribution liquidity) | par bin × jour/heure/snapshot | 7 | 367k–1.5M lignes |
| **mart_range_*** (recommandation ranges) | per-pool-per-candidate-per-day | 2 | 10 848 candidats |
| **mart_tracked_lp_*** (vues wallet) | per-wallet | 4 | 22 607 wallets |
| **mart_*backtest*** | per-scenario | 1 | 1 scenario actuel |
| **py_pool_*** (engines vol/gamma) | per-pool-per-day | 3 | 91–181 jours |
| **py_position_*** (engines perf/gamma) | per-position-per-day | 2 | 362 (synthétiques) à 796k (réels) |
| **py_lvr_*** | per-swap / per-day | 2 | 91 jours / 584k swaps |
| **py_subjacent_vol_*** | per-asset-per-day | 1 | 181 jours |
| **py_vol_surface** | per-pool-per-moneyness-bucket-per-day | 1 | 71 lignes |
| **py_backtest_*** | per-scenario / per-day | 2 | 60 jours |

**Domaines fonctionnels couverts** :

1. Volatilité (RV, BV, jumps, σ\*, HAR-RV forecasts)
2. Fees & yield (APR daily/7d/30d/90d, fee_per_100, fee/vol ratios)
3. Liquidité & TVL (active/out-of-range, distribution, concentration top-10)
4. Gamma & IL (gamma cost diffusion+jump, FGY, GSR, edge break-even vs realized)
5. Positions individuelles (PnL vs init, PnL vs HODL, IL token0, time-in-range, fees, lifecycle)
6. LVR (per-swap, daily, fee/LVR ratio)
7. Microstructure tick (sigma EVC last/twap/p95, fee_per_unit_liquidity)
8. Recommandation de range (candidats grid, heatmap)
9. Wallet view (overview, exposure, activité récente, attribution PnL)
10. Backtest (scenario synthétique avec rebalance policy)

---

## §1 Couches & flux de données

```
                   ┌──────────────────────────────────────────────┐
                   │  staging/    (stg_*)                         │
                   │  raw on-chain : swaps, mints, burns, NFPM    │
                   └─────────────────────┬────────────────────────┘
                                         │
                   ┌─────────────────────▼────────────────────────┐
                   │  intermediate/ (int_*)                       │
                   │  spines, daily_close, swaps_enriched,        │
                   │  tick_volume, active_liquidity_daily,        │
                   │  nfpm position lifecycle/fees/TIR            │
                   └─────────────────────┬────────────────────────┘
                                         │
        ┌────────────────────────────────┼────────────────────────────┐
        │                                │                            │
   ┌────▼────┐                    ┌──────▼──────┐              ┌──────▼──────┐
   │ marts   │                    │ python      │              │ marts       │
   │ dbt     │ ◄─── reads ──── ── │ engines     │ ── writes ─► │ py_*        │
   │ (mart_*)│                    │ (gsr,gamma, │              │             │
   │         │                    │  lvr,perf,  │              │             │
   │         │                    │  backtest)  │              │             │
   └────┬────┘                    └─────────────┘              └─────┬───────┘
        │                                                            │
        └─────────────────────► notebooks 01–13 ◄────────────────────┘
```

**Règle d'or** : tout calcul produisant une colonne *décisionnelle* (recommandation, score, classement) doit vivre dans **engines/** (Python), **pas** dans dbt. dbt sert à matérialiser les briques quantitatives ; les décisions sont en Python.

---

## §2 Features par THÈME (recommandé pour le front)

Cette section regroupe les colonnes par **domaine UX**, avec leur source de référence. C'est le tableau à utiliser pour designer les écrans.

### 2.1 Pool overview / hub principal

**Source primaire** : `mart_pool_screener_daily` (1 798 lignes, daily) ou `mart_pool_analytics_snapshot` (1 ligne, current).

| Carte | Colonnes |
|---|---|
| Header pool | `pool_address`, `chain`, `dex`, `token_pair`, `token0_symbol`, `token1_symbol`, `fee_tier`, `current_tick`, `current_price` |
| TVL | `tvl_token0_equiv`, `active_tvl_token0`, `out_of_range_tvl_token0`, `capital_utilization` |
| Volume | `volume_24h_token0_equiv`, `volume_7d_token0_equiv`, `volume_30d_token0_equiv`, `swap_count_24h`, `volume_tvl_ratio` |
| Fees | `fees_24h_token0_equiv`, `fees_7d_token0_equiv`, `fees_30d_token0_equiv`, `fees_per_active_tvl` |
| APR | `gross_fee_apr`, `gross_fee_apr_30d`, `gross_fee_apr_90d`, `incentive_apr` |
| Vol | `realized_vol_7d`, `realized_vol_30d` |
| Coûts cachés | `adverse_selection_cost_apr_proxy`, `adverse_selection_cost_apr_proxy_30d`, `lvr_proxy_daily_token0`, `gas_cost_apr_proxy` |
| Distribution liquidité | `lp_count`, `position_count`, `open_range_count`, `lp_concentration_top10_pct`, `liquidity_concentration_score_raw`, `range_width_median_ticks` (+ p25/p75), `range_overlap_density` |
| Performance prix | `price_return_7d`, `price_return_30d`, `drawdown_7d`, `drawdown_30d` |
| Variations 7j | `tvl_change_7d`, `volume_change_7d`, `fees_change_7d` |
| Drapeaux | `out_of_range_penalty_raw`, `is_estimated`, `updated_at` |

### 2.2 Volatilité & microstructure

**Source primaire** : `py_subjacent_vol_features_daily` (per-asset, 181 jours). Pour les stats prix : `mart_price_intraday`, `mart_price_analytics_daily`.

| Famille | Colonnes |
|---|---|
| Daily integrated vol | `realized_variance_daily`, `realized_quarticity_daily`, `bipower_variation_daily`, `realized_volatility_annual_garman_klass` |
| Décomposition jump | `jump_intensity_daily` (= (RV − BV)/RV) |
| Forecasts | `sigma_har_forecast_1d_annual`, `sigma_har_forecast_7d_annual` |
| Stat de gamma cost (heuristique) | `cv_realized_il` |
| Hourly OHLC | `mart_price_intraday`: `open_price`, `high_price`, `low_price`, `close_price`, `log_return_hourly`, `realized_vol_intraday` |
| Daily price | `mart_price_analytics_daily`: `close_price`, `log_return`, `realized_vol_7d/30d`, `rolling_high`, `drawdown` |

### 2.3 Pool gamma framework (Layer A)

**Source primaire** : `py_pool_gamma_features_daily` (181 jours). Le mart phare pour l'arbitrage break-even vs realized.

| Famille | Colonnes |
|---|---|
| Geometry | `liquidity_active_at_close`, `sqrt_price_at_close`, `full_range_equivalent_value_usd`, `capital_deployed_active_usd`, `concentration_leverage` |
| Vol break-even | `break_even_volatility_annual_7d_window`, `break_even_volatility_annual_30d_window` |
| Vol réalisée (alignée) | `realized_volatility_annual_7d_window`, `realized_volatility_annual_30d_window` |
| **Edge** | `volatility_edge_7d`, `volatility_edge_30d` |
| Yield-vs-risk | `fee_to_mean_gamma_cost_ratio_pool` (FGY pool) |

### 2.4 Position gamma framework (Layer B) + GSR pool

**Source primaire** : `py_position_gamma_features_daily` (positions synthétiques) + `py_pool_gsr_daily` (91 jours).

| `py_pool_gsr_daily` | description |
|---|---|
| `V_usd`, `L_active`, `sqrt_P`, `TVL_FR_usd` | géométrie du pool, full-range-equivalent |
| `fees_daily_usd`, `fees_7d_usd` | fees windows |
| `sigma_star_pool_daily_annual`, `sigma_star_pool_7d_annual` | break-even σ\* annualisée |
| `sigma_realized_annual` | σ Garman-Klass annualisée |
| `edge` | σ\*\_7d − σ_realized |
| `E_abs_IL`, `std_IL`, `cv_IL` | heuristique tail IL |
| `n_hours`, `n_returns` | data-quality |

| `py_position_gamma_features_daily` | description |
|---|---|
| `position_id`, `range_lower_price`, `range_upper_price`, `range_width_pct` | géométrie position |
| `liquidity_position`, `capital_deployed_position_usd`, `time_in_range_fraction` | sizing + activité |
| `fees_position_usd_daily` | fees position |
| `gamma_cost_expected_usd_daily`, `gamma_cost_realized_usd_daily`, `gamma_cost_volatility_usd_daily` | gamma cost central + réalisé + std |
| `diffusion_gamma_cost_usd_daily`, `jump_gamma_cost_usd_daily` | décomposition diffusion/jump |
| `gamma_pnl_usd_daily` | fees − gc réalisé |
| `fee_to_mean_gamma_cost_ratio` (FGY), `fee_to_gamma_cost_volatility_ratio` (GSR) | ratios clés |
| `cv_gamma_cost` | std/mean |

### 2.5 Liquidité & TVL distribution

**Source primaire** : `mart_tvl_distribution_daily_centered` (367k lignes, par bin centré sur le tick courant).

| Niveau | Mart | Colonnes clés |
|---|---|---|
| Snapshot pool now | `mart_tvl_current` | `total_tvl_token0`, `active_tvl_token0`, `out_of_range_tvl_token0`, `current_bin_tvl_token0` |
| Snapshot block | `mart_tvl_block_snapshot` | identique + `target_block`, `snapshot_log_index` |
| Distribution snapshot | `mart_tvl_distribution` (flat) / `mart_pool_distribution_snapshot` (avec fees + VPL 7d) | `tick_lower/upper`, `liquidity`, `amount0/1`, `tvl_token0`, `pct_liquidity`, + dans le snapshot : `volume_7d_token0_equiv`, `fees_7d_token0_equiv`, `swap_count_7d`, `fees_per_unit_liquidity_7d`, `is_crowded_band_raw`, `pool_paid_volatility`, `adverse_selection_risk_proxy` |
| Distribution daily centrée | `mart_tvl_distribution_daily_centered` | `relative_tick_lower/mid/upper`, `overlap_ticks_with_window`, `liquidity`, `amount0/1`, `tvl_token0`, `pct_visible_liquidity`, `pct_visible_tvl` |
| Métriques distribution daily | `mart_tvl_distribution_daily_metrics` | `visible_tvl_token0`, `current_bin_share_visible`, `share_overlapping_50/100/250/500_ticks`, `weighted_mean_relative_tick`, `weighted_abs_relative_tick`, `weighted_std_relative_tick` |
| Distribution & métriques hourly | `mart_tvl_distribution_hourly_centered`, `mart_tvl_distribution_hourly_metrics` | mêmes colonnes mais hourly |
| TVL daily simple | `mart_tvl_daily` | `tvl_token0`, `tvl_token1`, `tvl_token0_equiv` |

### 2.6 Microstructure tick / sigma EVC

**Source primaire** : `mart_tick_liquidity_volume_daily` (805k) + `mart_tick_sigma_evc_hourly` (2.3M) + `mart_tick_sigma_evc_weekly` (855).

| Mart | Colonnes |
|---|---|
| `mart_tick_daily` | `tick`, `time_seconds`, `volume_usd`, `swap_count` (signal le plus simple) |
| `mart_tick_liquidity_volume_daily` | `tick_liquidity_end`, `tick_liquidity_twap`, `tick_tvl_token0_last/twap`, `volume_token0/1/equiv`, `fees_generated_token0/1/equiv`, `fee_ratio`, `volume_token0_equiv_annualized`, `volume_per_tick_liquidity_last/twap`, **`sigma_evc_last`, `sigma_evc_twap`, `sigma_evc_mean/std/p95`** |
| `mart_tick_sigma_evc_hourly` | mêmes colonnes en hourly grain |
| `mart_tick_sigma_evc_weekly` | mêmes colonnes en weekly + `week_start` |
| `py_vol_surface_daily` | sigma EVC bucketé en moneyness : `moneyness_bucket`, `sigma_evc_raw`, `sigma_evc_smoothed`, `tick_count`, `total_liquidity`, `rv_realized_7d/30d` |

### 2.7 LVR (Loss-Versus-Rebalancing)

**Source primaire** : `py_lvr_per_swap` (584k swaps) + `py_lvr_daily` (91 jours).

| Mart | Colonnes |
|---|---|
| `py_lvr_per_swap` | `tx_hash`, `log_index`, `block_number`, `block_time`, `sqrt_price_before/after`, `liquidity_active`, `lvr`, `fee_amount` |
| `py_lvr_daily` | `lvr_total`, `fees_total`, `fee_lvr_ratio`, `swap_count` |

Proxy pool-level dans `mart_pool_screener_daily` : `lvr_proxy_daily_token0`.

### 2.8 Recommandation de range (range candidates)

**Source primaire** : `mart_range_candidates_features` (10 848 candidats × jour) + `mart_range_heatmap_features` (64 lignes pour heatmap UI).

| `mart_range_candidates_features` | description |
|---|---|
| `candidate_id`, `range_type` | identifiant + classe (e.g. fitted, ±X%, etc.) |
| `tick_lower`, `tick_upper`, `price_lower`, `price_upper`, `width_ticks`, `width_pct` | géométrie |
| `fees_7d_inside_token0_equiv`, `volume_7d_inside_token0_equiv`, `swap_count_7d_inside` | revenue inside range |
| `gross_fee_apr_inside_range_proxy`, `fees_per_unit_liquidity_inside_range_7d`, `expected_fee_apr_proxy` | APR projeté |
| `in_range_probability_7d_observed`, `in_range_probability_30d_observed`, `time_in_range_pct_hist` | TIR historique |
| `capital_utilization_inside_range`, `realized_volatility_7d`, `realized_volatility_30d` | risk / efficiency |
| `adverse_selection_cost_proxy`, `pool_paid_volatility_inside_range`, `volatility_spread_7d`, `gas_estimate_proxy`, `crowding_penalty_raw` | coûts |

`mart_range_heatmap_features` : version aplatie pour la heatmap UI (lower×upper grid).

### 2.9 Position individuelle (cards + features ML)

**Source primaire** : `mart_position_cards_current` (4 058 lignes) + `mart_position_features_current` (4 058 lignes, ML inputs).

| `mart_position_cards_current` (vue résumée) | description |
|---|---|
| `token_id`, `wallet`, `pool_address`, `token0/1_symbol`, `fee_tier` | identité |
| `tick_lower/upper`, `price_lower/upper`, `range_width_ticks` | range |
| `current_tick`, `current_price`, `status_in_range` | état actuel |
| `pooled_amount0/1`, `pooled_value_token0`, `current_total_wealth_token0` | valuation |
| `pnl_token0`, `pnl_pct`, `pnl_vs_hodl_token0`, `pnl_vs_hodl_pct` | PnL |
| `impermanent_loss_token0`, `il_pct` | IL |
| `fees_collected_token0`, `uncollected_fees_token0`, `total_fees_token0` | fees |
| `apr_estimate`, `adverse_selection_cost_token0_proxy` | rendement & coût |
| `position_age_days`, `time_in_range_pct_observed`, `observed_time_in_range_seconds`, `observed_window_seconds` | activité |
| `mint_block_time`, `last_position_activity_time`, `is_lot_benchmark_valid`, `entry_state_missing`, `entry_price_token1_in_token0` | data quality + entry state |

`mart_position_features_current` (sous-ensemble ML) : 23 colonnes — distance_to_lower/upper_pct, position_width_pct, current_price_relative_to_range_mid, price_return_since_entry, pnl_pct, il_pct, time_in_range_pct_observed, capital_utilization_current/observed, fees_collected_token0, uncollected_fees_token0, fees_earned_in_range_token0, fees_lost_out_of_range_token0, realized_vol_7d/30d, pool_adverse_selection_cost_apr_proxy, adverse_selection_cost_token0_proxy, position_age_days, observed_window_seconds, observed_time_in_range_seconds, is_lot_benchmark_valid, entry_state_missing.

### 2.10 Position lifecycle / PnL deep-dive

**Source primaire** : `mart_nfpm_position_pnl_current` (114 358 lignes, full PnL decomposition) + `mart_nfpm_position_lifecycle` (timeline).

`mart_nfpm_position_pnl_current` contient la **décomposition PnL complète** (principal + fees + IL + hodl):

- Décomposition principal: `total_contribution_amount0/1`, `total_principal_collected_amount0/1`, `current_principal_owed_amount0/1`
- Décomposition fees: `total_fees_accrued_amount0/1`, `total_fees_accrued_token0_equiv_generated`, `total_fees_collected_amount0/1`, `current_uncollected_fees_amount0/1`, `current_collected_fee_wealth_token0`, `current_uncollected_fee_wealth_token0`, `current_fee_wealth_token0`
- Wealth: `current_principal_wealth_token0`, `current_total_wealth_token0`
- IL: `impermanent_loss_token0`, `impermanent_loss_pct`
- PnL: `principal_pnl_vs_initial_token0/pct`, `pnl_vs_initial_token0/pct`, `pnl_vs_hodl_token0/pct`, `fee_to_il_ratio`
- Activité observée: `observed_time_in_range_seconds`, `observed_window_seconds`, `observed_out_of_range_seconds`, `observed_time_in_range_pct`, `observed_out_of_range_pct`
- Data quality: `is_lot_benchmark_valid`, `is_mint_anchored_benchmark_valid`, `entry_state_missing`, `lot_count`, `valid_lot_benchmark_count`, `missing_lot_benchmark_count`

`mart_nfpm_position_lifecycle` (timeline events) :

- Counts: `transfer_count`, `burn_transfer_count`, `increase_count`, `decrease_count`, `collect_count`, `distinct_to_address_count`
- Status: `is_open`, `is_active`, `is_nft_burned`, `is_current_owner_burn_like`, `lifecycle_status`
- Time markers: `first_secondary_transfer_*`, `last_secondary_transfer_*`, `burn_transfer_*`, `first_liquidity_event_*`, `first_increase_*`, `last_increase_*`, `first_decrease_*`, `last_decrease_*`, `first_collect_*`, `last_collect_*`
- Lifetimes: `observed_lifetime_seconds`, `time_to_first_collect_seconds`, `time_to_close_seconds`, `time_to_burn_seconds`

### 2.11 Position daily timeline (perf engine)

**Source primaire** : `py_position_performance_daily` (796 398 lignes, daily per token_id).

Colonnes (40+) : `token_id`, `day`, `price`, `sqrt_price`, `tick`, `L_effective`, `reserve_x`, `reserve_y`, `position_value`, `hodl_value`, `il`, `fees_collected_value`, `fees_uncollected_est`, `principal_owed_value`, `principal_collected_value`, `principal_wealth`, `total_wealth`, `pnl_net`, `pnl_vs_hodl`, `time_in_range_pct`, `share_of_pool`, `lvr_cumulative`, `is_in_range`, `tick_lower/upper`, `cum_hodl_amount0/1`, `cum_principal_generated_amount0/1`, `cum_principal_collected_amount0/1`, `cum_fees_amount0/1`, `cum_fees_generated_amount0/1`.

C'est le mart pour les **timelines** et **charts d'évolution** d'une position.

### 2.12 Wallet / leaderboard

**Source primaire** : `mart_tracked_lp_wallet_overview_current` (22 607 wallets).

| Mart | Colonnes |
|---|---|
| `mart_tracked_lp_wallet_overview_current` | `tracked_lp_value_token0`, `tracked_lp_pnl_token0/pct`, `tracked_lp_fees_collected_token0`, `tracked_lp_uncollected_fees_token0`, `tracked_open_positions_count`, `tracked_total_positions_count`, `tracked_in_range/out_of_range_positions_count`, `tracked_active_capital_token0`, `tracked_out_of_range_capital_token0`, `tracked_capital_utilization`, `indexed_pools_count`, `last_activity_time`, `coverage_scope/label/tooltip` |
| `mart_tracked_lp_wallet_exposure_current` | `exposure_dimension`, `exposure_name`, `exposure_token0`, `exposure_pct` (long format pour breakdowns) |
| `mart_tracked_lp_wallet_activity_recent` | `event_time`, `tx_hash`, `token_id`, `pool_address`, `activity_type` (mint/burn/collect/transfer/increase/decrease), `amount_token0`, `description` |
| `mart_tracked_lp_wallet_pnl_attribution_current` | `component`, `value_token0`, `value_pct` (long format pour waterfall) |

### 2.13 Backtest

**Source primaire** : `py_backtest_results` (60 jours) + `py_backtest_summary` (1 ligne).

| Mart | Colonnes |
|---|---|
| `py_backtest_results` (daily) | `scenario_id`, `pool`, `day`, `tick_lower/upper`, `rebalance_strategy`, `rebalance_count`, `total_gas_est`, `price_token1_in_token0`, `sqrt_price`, `tick`, `liquidity`, `amount0/1`, `principal_value_token0`, `hodl_value_token0`, `impermanent_loss_token0`, `fees_accrued_token0/1_cumulative`, `fees_accrued_token0_equiv_cumulative`, `lp_value_including_fees_token0`, `pnl_vs_initial_token0`, `pnl_vs_hodl_token0`, `time_in_range_pct`, `share_of_pool`, `is_in_range` |
| `py_backtest_summary` (terminal) | + tous les champs entry/exit, observed_time_in_range_pct, hodl_end_value, lp_end_value_including_fees, impermanent_loss, pnl_vs_initial/hodl_token0 |
| `mart_position_backtest_summary` (dbt) | équivalent dbt avec `fee_to_il_ratio` en plus + `start/end_position_status` |

---

## §3 Marts dbt — détail colonne par colonne

### 3.1 Pool views (V3)

#### `mart_pool_analytics_snapshot` (current, 1 ligne par pool indexé)
> 1 row × 50 cols. Snapshot business "live" : KPIs daily les plus récents + état pool maintenant.

```
pool_address, snapshot_time, chain, dex, token_pair, token0_symbol, token1_symbol,
fee_tier, current_tick, current_price,
tvl_token0_equiv, active_tvl_token0, out_of_range_tvl_token0, capital_utilization,
volume_24h_token0_equiv, volume_7d_token0_equiv, volume_30d_token0_equiv,
fees_24h_token0_equiv, fees_7d_token0_equiv, fees_30d_token0_equiv,
swap_count_24h,
gross_fee_apr, gross_fee_apr_30d, gross_fee_apr_90d, incentive_apr,
realized_vol_7d, realized_vol_30d,
adverse_selection_cost_apr_proxy, adverse_selection_cost_apr_proxy_30d,
lvr_proxy_daily_token0, gas_cost_apr_proxy,
volume_tvl_ratio, fees_per_active_tvl,
lp_count, position_count, open_range_count,
lp_concentration_top10_pct, liquidity_concentration_score_raw,
range_width_median_ticks, range_width_p25_ticks, range_width_p75_ticks, range_overlap_density,
price_return_7d, price_return_30d, drawdown_7d, drawdown_30d,
tvl_change_7d, volume_change_7d, fees_change_7d,
out_of_range_penalty_raw, is_estimated, updated_at
```

#### `mart_pool_screener_daily` (1 798 jours)
> Variante daily du snapshot. Mêmes colonnes + `date`, `has_swap`, `gross_fee_apr_daily`, `log_return_daily`. C'est le mart ergonomique pour le timeline pool.

#### `mart_pool_distribution_snapshot` (1 537 lignes, current par pool × bin)
> Distribution liquidity actuelle avec metrics fees & toxicité par bin.
```
pool_address, tick_lower, tick_upper, tick_mid, price_lower, price_upper,
token0_symbol, token1_symbol, tick_spacing, current_tick, price_token1_in_token0,
liquidity, amount0, amount1, tvl_token0, pct_liquidity,
volume_7d_token0_equiv, fees_7d_token0_equiv, swap_count_7d, fees_per_unit_liquidity_7d,
is_current_tick, is_crowded_band_raw, pool_paid_volatility, adverse_selection_risk_proxy,
updated_at
```

### 3.2 Volume / fees / yield

#### `mart_volume_daily` (1 798)
```
pool, date, volume_token0, volume_token1, volume_token0_equiv,
swap_count, fees_token0, fees_token1, fees_token0_equiv
```

#### `mart_fee_yield_daily` (1 798)
```
pool, date, tvl_total_token0, tvl_active_token0, tvl_outofrange_token0,
fees_token0_equiv, apr
```

#### `mart_fee_per_100_usd` (10 788, par pool×date×width)
```
pool, date, range_width_ticks, tick_lower, tick_upper, close_price, close_tick,
active_liquidity, active_tvl_token0, tvl_per_unit_L,
fee_per_100_token0_daily, fee_per_100_token0_annual,
fee_per_100_token0_7d, fee_per_100_token0_30d, fee_per_100_token0_90d,
fee_bps_annual, fee_bps_7d, fee_bps_30d, fee_bps_90d
```

#### `mart_lp_macro_daily` (1 798) — **bundle one-stop pour LP macro view**
```
pool, date, close_price, close_tick,
tvl_token0_equiv, active_tvl_token0, active_range_count,
fees_token0_equiv, volume_token0_equiv, swap_count,
capital_utilization, volume_tvl_ratio, active_liquidity_depth,
log_return, realized_vol_7d, realized_vol_30d,
apr_daily, apr_7d, apr_30d, apr_90d, apr7_vol_ratio, coupon_vol_ratio_500,
mint_count, burn_count, mint_token0, burn_token0, net_lp_flow_token0, lp_turnover,
burns_inrange_count, burns_outofrange_count, burns_inrange_token0, burns_outofrange_token0, pct_burns_inrange,
open_range_count, range_width_median_ticks, range_width_p25_ticks, range_width_p75_ticks,
lp_concentration_top10_pct, range_overlap_density
```

### 3.3 NFPM positions

#### `mart_nfpm_open_positions_current` (4 058)
> Vue ouverte uniquement, full state + valuations courantes. ~80 colonnes (cf. §2.10).

#### `mart_nfpm_positions_current` (114 358)
> Vue exhaustive (open + fermées) avec mêmes colonnes que `_open_` + secondary transfers history.

#### `mart_nfpm_position_lifecycle` (114 358)
> Timeline événementielle. Cf. §2.10.

#### `mart_nfpm_position_pnl_current` (114 358)
> PnL decomposition complète. Cf. §2.10. **Mart phare pour le PnL d'une position.**

#### `mart_open_positions` (3 145, vue agrégée par pool×owner×range)
```
pool, owner, tick_lower, tick_upper, net_liquidity, net_amount0, net_amount1,
current_tick, price_token1_in_token0, tick_spacing, token0_symbol, token1_symbol,
is_active, position_amount0, position_amount1, position_token0
```

### 3.4 Prix microstructure

#### `mart_price_intraday` (43 118 heures)
```
pool, date, hour, open_tick, close_tick,
open_price, high_price, low_price, close_price,
volume_token0/1/equiv, swap_count, log_return_hourly, realized_vol_intraday
```

#### `mart_price_analytics_daily` (1 808)
```
pool, date, close_tick, close_price, has_swap,
log_return, realized_vol_7d, realized_vol_30d, rolling_high, drawdown
```

### 3.5 Tick microstructure (sigma EVC)

#### `mart_tick_daily` (805 633) — léger
```
pool, date, tick, time_seconds, volume_usd, swap_count
```

#### `mart_tick_liquidity_volume_daily` (805 812) — riche
```
pool, date, tick, tick_lower, tick_upper,
tick_liquidity_end, tick_liquidity_twap, tick_tvl_token0_last/twap,
swap_count, fallback_after_swap_count,
volume_token0/1/equiv, fees_generated_token0/1/equiv, fee_ratio,
volume_token0_equiv_annualized, volume_per_tick_liquidity_last/twap,
sigma_evc_last, sigma_evc_twap, sigma_evc_mean, sigma_evc_std, sigma_evc_p95
```

#### `mart_tick_sigma_evc_hourly` (2 345 792)
> Idem en grain horaire (sans p95/std/mean).

#### `mart_tick_sigma_evc_weekly` (855)
> Idem en grain hebdo + `week_start`.

### 3.6 TVL

| Mart | rows | Granularité |
|---|---|---|
| `mart_tvl_current` | 1 | snapshot pool now |
| `mart_tvl_block_snapshot` | 1 | snapshot at target_block |
| `mart_tvl_daily` | 1 798 | per pool × day |
| `mart_tvl_distribution` | 1 537 | per pool × bin (snapshot) |
| `mart_tvl_distribution_daily_centered` | 367 039 | per pool × bin × day, centré |
| `mart_tvl_distribution_daily_metrics` | 461 | metrics agrégés par pool × day |
| `mart_tvl_distribution_hourly_centered` | 105 721 | per pool × bin × hour |
| `mart_tvl_distribution_hourly_metrics` | 132 | metrics agrégés par pool × hour |

### 3.7 Range candidates / heatmap

| Mart | rows | Description |
|---|---|---|
| `mart_range_candidates_features` | 10 848 | grid de candidats `tick_lower×tick_upper×date` avec features |
| `mart_range_heatmap_features` | 64 | version aplatie pour heatmap UI |

### 3.8 Tracked LP wallets

(cf. §2.12)

### 3.9 dim

#### `dim_indexed_pools` — la dimension canonique des pools indexés
> *À lire en premier* dans toute query frontend pour scoper aux pools réellement indexés.

---

## §4 Marts Python — détail colonne par colonne

### 4.1 Vol / Gamma framework

#### `py_subjacent_vol_features_daily` (181, asset='ETH')
```
asset, date,
realized_variance_daily, realized_quarticity_daily, bipower_variation_daily,
jump_intensity_daily,
realized_volatility_annual_garman_klass, cv_realized_il,
sigma_har_forecast_1d_annual, sigma_har_forecast_7d_annual
```

#### `py_pool_gamma_features_daily` (181, Layer A)
```
date, pool_address,
volume_usd_daily, fees_usd_daily,
liquidity_active_at_close, sqrt_price_at_close,
full_range_equivalent_value_usd, capital_deployed_active_usd, concentration_leverage,
break_even_volatility_annual_7d_window, break_even_volatility_annual_30d_window,
realized_volatility_annual_7d_window, realized_volatility_annual_30d_window,
volatility_edge_7d, volatility_edge_30d,
fee_to_mean_gamma_cost_ratio_pool
```

#### `py_position_gamma_features_daily` (362, Layer B — synthétiques)
```
date, pool_address, position_id,
range_lower_price, range_upper_price, range_width_pct,
liquidity_position, capital_deployed_position_usd, time_in_range_fraction,
fees_position_usd_daily,
gamma_cost_expected_usd_daily, gamma_cost_realized_usd_daily, gamma_cost_volatility_usd_daily,
diffusion_gamma_cost_usd_daily, jump_gamma_cost_usd_daily, gamma_pnl_usd_daily,
fee_to_mean_gamma_cost_ratio, fee_to_gamma_cost_volatility_ratio, cv_gamma_cost
```

#### `py_pool_gsr_daily` (91)
> Cf. §2.4.

### 4.2 LVR

#### `py_lvr_per_swap` (584 535)
```
pool, tx_hash, log_index, block_number, block_time,
sqrt_price_before, sqrt_price_after, liquidity_active,
lvr, fee_amount
```

#### `py_lvr_daily` (91)
```
pool, day, lvr_total, fees_total, fee_lvr_ratio, swap_count
```

### 4.3 Performance positions

#### `py_position_performance_daily` (796 398, par token_id × day)
> Mart le plus volumineux. Cf. §2.11 pour les colonnes complètes.

### 4.4 Vol surface

#### `py_vol_surface_daily` (71, par moneyness bucket)
```
pool, day, moneyness_bucket,
sigma_evc_raw, sigma_evc_smoothed,
tick_count, total_liquidity,
rv_realized_7d, rv_realized_30d
```

### 4.5 Backtest

#### `py_backtest_results` (60, daily)
> Cf. §2.13.

#### `py_backtest_summary` (1, terminal)
> Cf. §2.13.

---

## §5 Engines Python — endpoints calcul

> Tous dans `/home/gharbi/defind-analytics/python/engines/`. Chacun a un runner CLI dans `/home/gharbi/defind-analytics/python/runners/run_<engine>.py`.

### `gsr_engine.py`
- **Output** : `py_pool_gsr_daily`
- **Entry points** : `build_pool_gsr_daily(db, pool, start_date, end_date)`, `run_pool_gsr(...)`, `summarize_gsr(gsr)`
- **Inputs lus** : `int_daily_close_dense`, `int_active_liquidity_daily`, `int_active_tvl_daily`, `mart_volume_daily`, `mart_price_intraday`, `stg_pools`
- **Calculs** : break-even σ\* daily/7d, σ Garman-Klass, edge, E[|IL|]/std/cv via realized quarticity

### `gamma_framework.py`
- **Output** : 3 marts (`py_subjacent_vol_features_daily`, `py_pool_gamma_features_daily`, `py_position_gamma_features_daily`)
- **Entry points** : `run_gamma_framework(db, pool, position, start_date, end_date, asset_label, position_share, write)`
- **Builders** : `build_subjacent_vol_features_daily`, `build_pool_gamma_features_daily`, `build_position_gamma_features_daily`, `har_rv_rolling_forecast`
- **Classes** : `LpPosition(L, Pa, Pb, label)`, `GammaFrameworkOutput`

### `gamma_risk_engine.py` (engine pandas, antérieur à `gamma_framework`)
- **Output** : pas de mart écrit (legacy notebook 11)
- **Entry points** : `run_gamma_risk_pipeline(...)`
- **Builders** : `compute_gamma`, `compute_realized_il`, `compute_rv_bv_jumps`, `decompose_il`, `compute_core_metrics`, `compute_tail_diagnostics`, `aggregate_il_daily`

### `lvr_engine.py`
- **Output** : `py_lvr_per_swap`, `py_lvr_daily`
- **Entry points** : `run_lvr(...)`, `build_lvr_per_swap`, `build_lvr_daily`
- **Inputs** : `mart_volume_daily`, `int_swaps_enriched`
- **Validation** : `validate_fee_lvr_ratio`, `summarize_lvr_daily`

### `perf_engine.py`
- **Output** : `py_position_performance_daily`
- **Entry points** : `run_position_performance(db, pool, start_date, end_date, position_ids)`
- **Builders** : `build_position_performance_daily`
- **Validation** : `compare_terminal_values_to_dbt`, `summarize_terminal_comparison`

### `backtest_engine.py`
- **Output** : `py_backtest_results`, `py_backtest_summary`
- **Entry points** : `run_backtest(scenarios)`, `normalize_scenarios`
- **Builders** : `build_backtest_entry_liquidity`, `build_backtest_swap_path`, `build_backtest_time_in_range`, `build_backtest_exit_state`, `build_backtest_daily_results`, `build_backtest_summary`
- **Validation** : `compare_backtest_summary_to_dbt`, `summarize_backtest_comparison`

### Runners (`runners/`)
- `run_gsr.py` — pool, start_date, end_date, write
- `run_gamma_framework.py` — pool, range, position L/Pa/Pb, share, write
- `run_lvr.py` — pool, range, write
- `run_perf.py` — pool, range, position_ids, write
- `run_backtest.py` — scenario file, write
- `run_vol_surface.py` — pool, range, write

---

## §6 Notebooks d'analyse

| # | Fichier | Topic |
|---|---|---|
| 01 | [01_pool_overview.ipynb](python/notebooks/01_pool_overview.ipynb) | Pool Overview — QA |
| 02 | [02_price_volatility.ipynb](python/notebooks/02_price_volatility.ipynb) | Price & Volatility — QA |
| 03 | [03_liquidity_tvl.ipynb](python/notebooks/03_liquidity_tvl.ipynb) | Liquidity & TVL — QA |
| 04 | [04_fees_yield.ipynb](python/notebooks/04_fees_yield.ipynb) | Fees & Yield — QA |
| 05 | [05_lvr.ipynb](python/notebooks/05_lvr.ipynb) | LVR — QA |
| 06 | [06_vol_surface.ipynb](python/notebooks/06_vol_surface.ipynb) | Volatility Surface (EVC) |
| 06b | [06_vol_surface_evc.ipynb](python/notebooks/06_vol_surface_evc.ipynb) | Vol Surface / EVC — QA |
| 07 | [07_position_performance.ipynb](python/notebooks/07_position_performance.ipynb) | Position Performance — QA |
| 08 | [08_backtest.ipynb](python/notebooks/08_backtest.ipynb) | Backtest — QA |
| 09 | [09_lp_leaderboard.ipynb](python/notebooks/09_lp_leaderboard.ipynb) | LP Leaderboard — QA |
| 10 | [10_gamma_sharpe.ipynb](python/notebooks/10_gamma_sharpe.ipynb) | Gamma Sharpe Ratio (GSR) — POC v0 |
| 11 | [11_gamma_risk.ipynb](python/notebooks/11_gamma_risk.ipynb) | Gamma-Risk Framework |
| 12 | [12_gamma_framework.ipynb](python/notebooks/12_gamma_framework.ipynb) | Gamma Framework — Central POC Question |
| 13 | [13_gamma_framework_remediation.ipynb](python/notebooks/13_gamma_framework_remediation.ipynb) | Gamma Framework — Remediation Report (v0.2) |

Notebooks 01-09 sont **QA-only** (vérifient la cohérence des marts) — pas destinés au front. 10-13 sont les **POC analytiques** qui ont produit les findings business (FGY, GSR, jump decomposition, range optimization).

---

## §7 Macros dbt réutilisables

> Dans `/home/gharbi/defind-analytics/dbt/defind_analytics/macros/`. À considérer comme briques de calcul si on doit dériver des features supplémentaires.

| Macro | Rôle |
|---|---|
| `macros/core/latest_state.sql` | Window function pour récupérer le dernier état d'une entité |
| `macros/core/nfpm_amounts.sql` | Conversion liquidity → amount0/amount1 selon range et tick courant |
| `macros/core/tvl_snapshot.sql` | Calcul TVL token0_equiv à partir d'une distribution |
| `macros/core/ensure_pools_source_exists.sql` | Garde `stg_pools` toujours valide |
| `macros/math/uniswap_math.sql` | Helpers sqrt_price, tick→price, etc. |
| `macros/backtest/position_backtest.sql` | Logique fee accrual pour backtest |
| `macros/testing/unit_test_fixtures.sql` | Fixtures pour tests |

---

## §8 Pour le design front — recommandations

### Sections naturelles (mapping mart ↔ écran)

| Section UI | Mart principal | Marts complémentaires |
|---|---|---|
| **Pool overview / hub** | `mart_pool_screener_daily` (timeline) + `mart_pool_analytics_snapshot` (snapshot) | `mart_volume_daily`, `mart_lp_macro_daily` |
| **Volatility tab** | `py_subjacent_vol_features_daily` | `mart_price_intraday`, `mart_price_analytics_daily` |
| **Gamma framework** (Layer A) | `py_pool_gamma_features_daily` | `py_pool_gsr_daily` |
| **Gamma framework** (Layer B) | `py_position_gamma_features_daily` | linked to a `LpPosition` |
| **Liquidity distribution** (chart) | `mart_tvl_distribution_daily_centered` + `_metrics` | `mart_tvl_distribution` (snapshot) |
| **Tick microstructure** | `mart_tick_liquidity_volume_daily` | `mart_tick_sigma_evc_hourly`, `py_vol_surface_daily` |
| **LVR drill-down** | `py_lvr_daily` (timeline) | `py_lvr_per_swap` (table) |
| **Range recommender** | `mart_range_candidates_features` | `mart_range_heatmap_features` |
| **Position card** | `mart_position_cards_current` | `mart_position_features_current`, `mart_nfpm_position_pnl_current` |
| **Position timeline** | `py_position_performance_daily` | `mart_nfpm_position_lifecycle` |
| **Wallet** | `mart_tracked_lp_wallet_overview_current` | `_exposure_`, `_activity_recent`, `_pnl_attribution_` |
| **Backtest** | `py_backtest_results` (timeline) + `py_backtest_summary` | `mart_position_backtest_summary` |

### Patterns à suivre

1. **Toujours scoper via `dim_indexed_pools`** pour ne montrer que les pools réellement indexés.
2. **Le timestamp `updated_at` existe sur la plupart des marts** → exposer comme "last refreshed" dans le UI.
3. **Distinguer current vs daily** : `_current` / `_snapshot` = 1 row/entité maintenant ; `_daily` = timeline. Beaucoup de KPIs existent en deux versions ; choisir selon que l'écran montre un état ou une évolution.
4. **`*_token0_equiv`** = exprimé en token0 (USDC pour notre pool, donc ≈ USD). Pas besoin de re-convertir côté front sauf pour i18n.
5. **Drapeaux de qualité** : `is_estimated`, `is_lot_benchmark_valid`, `entry_state_missing` doivent être surfacés dans le UI (badge "estimé" ou warning).
6. **Décisions/recommandations en API Python**, pas en mart : pour un score "is this position healthy?" ou un "recommended range", appeler un endpoint qui consomme les marts et retourne la décision. Les marts servent les *features*, pas les verdicts.

### Limites connues actuelles

- **1 seul pool en intraday** : USDC/WETH 0.05%. Pas de 0.3% / autres tiers en CH.
- **`mart_pool_analytics_snapshot` n'a qu'une row** : structure prête pour multi-pool mais pas peuplée.
- **`py_position_gamma_features_daily`** = 362 lignes seulement (positions synthétiques wide+narrow) — pas de couverture exhaustive des positions réelles.
- **`py_vol_surface_daily`** = 71 lignes — POC, pas en production.
