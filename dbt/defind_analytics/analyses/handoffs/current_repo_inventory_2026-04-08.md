# Current Repo Inventory — 2026-04-08

Validation de couverture rerunée sur le repo au `2026-04-14`.

Ce document est un handoff compact de l'état actuel du repo `defind-analytics`, pour pouvoir le donner à un autre chat sans lui faire relire tout l'historique.

## 1. État global

- Le projet est organisé par domaine métier à l'intérieur des couches dbt classiques:
  - `models/staging`
  - `models/intermediate`
  - `models/marts`
- Le repo dbt contient actuellement `77` modèles SQL:
  - `8` staging
  - `45` intermediate
  - `24` marts
- La famille `distribution` a été recâblée proprement autour de `int_tick_boundary_deltas`.
- Les modèles `hourly` / `daily` de distribution sont conservés comme implémentations de référence dbt.
- Intention future:
  - garder dbt comme couche canonique / de référence
  - déplacer les calculs lourds et paramétriques multi-grains vers Python plus tard
  - comparer Python vs dbt à partir des tables de référence déjà matérialisées
- Ce document vise maintenant à être exhaustif pour l'inventaire des modèles SQL dbt du repo.

## 2. Ce qui est canonique

### Staging

- [stg_swaps.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_swaps.sql)
- [stg_mints.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_mints.sql)
- [stg_burns.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_burns.sql)
- [stg_pools.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_pools.sql)
- [sources.yml](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/sources.yml)

### Intermediates canoniques

- [int_lp_events.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/core_state/int_lp_events.sql)
  - vérité canonique LP
  - mint positif, burn négatif
- [int_swaps_enriched.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/core_state/int_swaps_enriched.sql)
  - source canonique des economics swap-level
- [int_swaps_tick_volume.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tick_volume/int_swaps_tick_volume.sql)
  - volume swap-level attribué au tick actif juste avant le swap
  - helper canonique pour les études volume par tick / IV-like
- [int_tick_volume_state_changes.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tick_volume/int_tick_volume_state_changes.sql)
  - version compressée au grain state change / session de `active_tick` constant
  - conserve `volume_token0`, `volume_token1`, `volume_token0_equiv`
- [int_tick_volume_5m.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tick_volume/int_tick_volume_5m.sql)
  - vue dérivée exacte au grain `(pool, bucket_5m, tick)`
  - agrège `int_swaps_tick_volume` pour le grain fin
- [int_tick_volume_hourly.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tick_volume/int_tick_volume_hourly.sql)
  - vue dérivée exacte au grain `(pool, hour, tick)`
  - agrège `int_swaps_tick_volume` sans perdre `volume_token0` / `volume_token1`
- [int_tick_changes.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/core_state/int_tick_changes.sql)
  - sessions de tick / base utile pour time-in-range
- [int_current_state.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/core_state/int_current_state.sql)
  - dernier état courant du pool
- [int_daily_close.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/core_state/int_daily_close.sql)
  - close journalier observé sur les swaps
- [int_daily_close_dense.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/core_state/int_daily_close_dense.sql)
  - close journalier dense avec carry-forward pour les jours sans swap
- [int_tick_boundary_deltas.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/distribution/int_tick_boundary_deltas.sql)
  - représentation dérivée canonique pour toute la famille `distribution`
  - règle:
    - `tick_lower -> +liquidity_delta`
    - `tick_upper -> -liquidity_delta`
- [int_tick_volume_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tick_volume/int_tick_volume_daily.sql)
  - vue dérivée agrégée depuis l'hourly
- [int_tick_volume_weekly.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tick_volume/int_tick_volume_weekly.sql)
  - vue dérivée agrégée depuis l'hourly
  - semaine calendaire démarrant le lundi

## 3. Famille Distribution

### Contrat actuel

La famille `distribution` repose maintenant sur:

- [int_tick_boundary_deltas.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/distribution/int_tick_boundary_deltas.sql)
- [int_hourly_snapshot_blocks.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/distribution/int_hourly_snapshot_blocks.sql)
- [int_hourly_tick_liquidity_net.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/distribution/int_hourly_tick_liquidity_net.sql)
- [int_daily_snapshot_blocks.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/distribution/int_daily_snapshot_blocks.sql)
- [int_daily_tick_liquidity_net.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/distribution/int_daily_tick_liquidity_net.sql)
- [int_weekly_tick_liquidity_net.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/distribution/int_weekly_tick_liquidity_net.sql)
  - snapshot hebdomadaire de liquidité par tick via last daily snapshot de la semaine
- [int_range_liquidity_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tvl/int_range_liquidity_daily.sql)
  - liquidité agrégée par range et par jour
- [int_active_liquidity_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tvl/int_active_liquidity_daily.sql)
  - liquidité active journalière sur le tick courant
- [int_active_tvl_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/tvl/int_active_tvl_daily.sql)
  - TVL active journalière dérivée de la liquidité active

### Marts de référence

- [mart_tvl_distribution.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/tvl/mart_tvl_distribution.sql)
  - snapshot current / block-level
- [mart_tvl_distribution_hourly_centered.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/tvl/mart_tvl_distribution_hourly_centered.sql)
- [mart_tvl_distribution_hourly_metrics.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/tvl/mart_tvl_distribution_hourly_metrics.sql)
- [mart_tvl_distribution_daily_centered.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/tvl/mart_tvl_distribution_daily_centered.sql)
- [mart_tvl_distribution_daily_metrics.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/tvl/mart_tvl_distribution_daily_metrics.sql)
- [mart_tick_liquidity_volume_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/price/mart_tick_liquidity_volume_daily.sql)
  - expose `Volume(K)`, `TickLiquidity(K)`, `Volume(K)/TickLiquidity(K)` et `sigma_evc(K)`
- [mart_tick_sigma_evc_hourly.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/price/mart_tick_sigma_evc_hourly.sql)
  - sigma EVC horaire par tick, utilisé comme baseline de comparaison et de distribution intra-day
- [mart_tick_sigma_evc_weekly.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/price/mart_tick_sigma_evc_weekly.sql)
  - dérivé hebdomadaire de la famille sigma EVC

### Décision importante

- `hourly` et `daily` sont gardés comme références dbt.
- `weekly` est pour l'instant pensé comme dérivé du `daily`.
- Les grains plus fins (`5m`, etc.) ne doivent pas forcément être ajoutés dans dbt.
- L'idée future est:
  - dbt = baseline / contrat
  - Python = moteur flexible / plus léger à itérer

## 4. TVL / Price / LP Analytics

### TVL

- [mart_tvl_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/tvl/mart_tvl_daily.sql)
- [mart_tvl_current.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/tvl/mart_tvl_current.sql)
- [mart_tvl_block_snapshot.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/tvl/mart_tvl_block_snapshot.sql)

### Price

- [mart_price_analytics_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/price/mart_price_analytics_daily.sql)
- [mart_price_intraday.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/price/mart_price_intraday.sql)
- [mart_tick_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/price/mart_tick_daily.sql)
- [int_tick_sigma_evc_daily_stats_weekly.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/price/int_tick_sigma_evc_daily_stats_weekly.sql)
  - stats weekly dérivées des `sigma_evc` journaliers, utilisées par le mart weekly

### LP analytics

- [mart_volume_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/lp_analytics/mart_volume_daily.sql)
  - agrège maintenant depuis `int_swaps_enriched`
- [mart_fee_yield_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/lp_analytics/mart_fee_yield_daily.sql)
- [mart_fee_per_100_usd.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/lp_analytics/mart_fee_per_100_usd.sql)
- [mart_lp_macro_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/lp_analytics/mart_lp_macro_daily.sql)
- [mart_open_positions.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/lp_analytics/mart_open_positions.sql)

## 5. Backtest simulé

### Inputs / helpers

- [int_position_backtest_inputs.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/backtest/int_position_backtest_inputs.sql)
- [int_position_backtest_entry_state.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/backtest/int_position_backtest_entry_state.sql)
- [int_position_backtest_entry_liquidity.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/backtest/int_position_backtest_entry_liquidity.sql)
- [int_position_backtest_swap_path.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/backtest/int_position_backtest_swap_path.sql)
- [int_position_backtest_time_in_range.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/backtest/int_position_backtest_time_in_range.sql)
- [int_position_backtest_exit_state.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/backtest/int_position_backtest_exit_state.sql)

### Mart final

- [mart_position_backtest_summary.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/backtest/mart_position_backtest_summary.sql)

### Position actuelle du projet sur le backtest

- Le backtest SQL existe et fonctionne comme baseline.
- Il est probable que le moteur de simulation interactif parte ensuite en Python.
- Il faut garder la version dbt comme référence de validation.

## 6. NFPM / positions NFT

### Staging NFPM

- [stg_nfpm_transfers.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_nfpm_transfers.sql)
- [stg_nfpm_increase_liquidity.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_nfpm_increase_liquidity.sql)
- [stg_nfpm_decrease_liquidity.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_nfpm_decrease_liquidity.sql)
- [stg_nfpm_collects.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_nfpm_collects.sql)

### Intermediates NFPM

- [int_nfpm_pool_mints.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_pool_mints.sql)
  - signatures `pool Mint` canoniques attribuables à NFPM sur la pool suivie
- [int_nfpm_token_mint_actions.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_token_mint_actions.sql)
  - mappe les mint-like `Transfer` NFPM au premier `IncreaseLiquidity`, puis à la signature `pool Mint` exacte
- [int_nfpm_positions.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_positions.sql)
  - définition immuable des positions NFT de la pool, enrichie des métadonnées token
- [int_nfpm_position_liquidity_events.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_liquidity_events.sql)
- [int_nfpm_position_collect_events.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_collect_events.sql)
- [int_nfpm_position_liquidity_summary.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_liquidity_summary.sql)
- [int_nfpm_position_increase_lots.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_increase_lots.sql)
  - découpe les apports successifs en lots d'entrée distincts pour les benchmarks et le PnL
- [int_nfpm_position_transfer_rollup.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_transfer_rollup.sql)
  - rollup unique des `Transfer`: owner courant, stats de burn, stats de secondary transfers
- [int_nfpm_position_collect_decomposition.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_collect_decomposition.sql)
  - décompose `Collect` en `principal` puis `fees` avec une convention explicite `principal-first`
- [int_nfpm_position_collect_rollup.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_collect_rollup.sql)
  - rollup unique des `Collect`: totaux collectés + split `principal / fees`
- [int_nfpm_position_entry_state.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_entry_state.sql)
  - snapshot `as-of mint` via `ASOF JOIN` sur les swaps
  - 1 seule position connue a `entry_state_missing = 1` car elle précède le premier swap observé
- [int_nfpm_position_fee_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_fee_daily.sql)
  - couche journalière chunkable de fees générées par position
- [int_nfpm_position_fee_summary.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_fee_summary.sql)
  - summary stable `1 row per token_id` des fees générées
- [int_nfpm_position_liquidity_spans.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_liquidity_spans.sql)
  - vérité canonique des spans de liquidité positive par `token_id`
- [int_nfpm_position_time_in_range_daily.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_time_in_range_daily.sql)
  - couche journalière chunkable de time-in-range
- [int_nfpm_position_time_in_range_summary.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_time_in_range_summary.sql)
  - summary stable `1 row per token_id` du temps observé in-range
- [int_nfpm_position_lot_benchmark_summary.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/intermediate/nfpm/int_nfpm_position_lot_benchmark_summary.sql)
  - benchmark lot-based agrégé par position pour comparer la position courante à un HODL reconstruit

### Marts NFPM

- [mart_nfpm_positions_current.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/nfpm/mart_nfpm_positions_current.sql)
  - snapshot courant par `token_id`
- [mart_nfpm_open_positions_current.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/nfpm/mart_nfpm_open_positions_current.sql)
  - sous-ensemble ouvert du snapshot courant
- [mart_nfpm_position_lifecycle.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/nfpm/mart_nfpm_position_lifecycle.sql)
  - résumé lifecycle complet par `token_id`
- [mart_nfpm_position_pnl_current.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/marts/nfpm/mart_nfpm_position_pnl_current.sql)
  - PnL courant par `token_id`
  - sépare `principal`, `fees collected`, `fees uncollected`, benchmark `HODL`, `IL`, `PnL vs initial`, `PnL vs hodl`
  - inclut aussi les stats observées de `time in range`

### Couverture / garanties déjà validées

- `mint transfer -> initial increase` : couverture `100%`
- `pool Mint <-> IncreaseLiquidity` : couverture `100%`
- `pool Burn non-zero <-> DecreaseLiquidity` : couverture `100%`
- `zero-burns` pool conservés comme events métier légitimes de mise à jour de fees

### Volumétrie connue

- `int_nfpm_positions` : `114,358`
- `mart_nfpm_open_positions_current` : `4,058`
- `mart_nfpm_position_lifecycle` :
  - `open = 4,058`
  - `closed_unburned = 82,469`
  - `burned = 27,831`
- `mart_nfpm_position_pnl_current` :
  - `114,358` positions
  - `1` seule position sans état d'entrée observable
## 7. Macros importantes

- [latest_state.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/macros/core/latest_state.sql)
  - helpers `latest swap as of block`
- [tvl_snapshot.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/macros/core/tvl_snapshot.sql)
  - projection commune des snapshots TVL
- [uniswap_math.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/macros/math/uniswap_math.sql)
  - macros mathématiques V3 à ne pas réimplémenter ailleurs
- [position_backtest.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/macros/backtest/position_backtest.sql)
- [unit_test_fixtures.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/macros/testing/unit_test_fixtures.sql)

## 8. Notebooks / analyses

### TVL / Distribution

- [tvl_dashboard_readiness.ipynb](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/tvl/tvl_dashboard_readiness.ipynb)
- [tvl_distribution_hourly_evolution.ipynb](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/tvl/tvl_distribution_hourly_evolution.ipynb)

### Backtest

- [position_backtest_validation.ipynb](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/backtest/position_backtest_validation.ipynb)

### Data quality

- [staging_data_quality.ipynb](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/data_quality/staging_data_quality.ipynb)
- [nfpm_raw_data_quality_2026-04-06.md](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/data_quality/nfpm_raw_data_quality_2026-04-06.md)

### Exploration / overview

- [lp_feature_overview.ipynb](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/exploration/lp_feature_overview.ipynb)
- [investigation.ipynb](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/exploration/investigation.ipynb)
- [quick_dbt_viz.ipynb](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/exploration/quick_dbt_viz.ipynb)

## 9. Infra / ClickHouse

### ClickHouse

- [clickhouse/README.md](/home/gharbi/defind-analytics/clickhouse/README.md)
- [clickhouse/config/remote/docker_related_config.xml](/home/gharbi/defind-analytics/clickhouse/config/remote/docker_related_config.xml)
- [clickhouse/config/remote/r2-storage.xml](/home/gharbi/defind-analytics/clickhouse/config/remote/r2-storage.xml)
- [clickhouse/config/local/docker_related_config.xml](/home/gharbi/defind-analytics/clickhouse/config/local/docker_related_config.xml)
- [clickhouse/ddl/uniswap_usdc_weth.sql](/home/gharbi/defind-analytics/clickhouse/ddl/uniswap_usdc_weth.sql)
- [clickhouse/ddl/uniswap_usdc_weth_local.sql](/home/gharbi/defind-analytics/clickhouse/ddl/uniswap_usdc_weth_local.sql)
- [clickhouse/scripts/bootstrap_local_sources.py](/home/gharbi/defind-analytics/clickhouse/scripts/bootstrap_local_sources.py)

### Onchain metadata

- [fetch_pool_metadata.py](/home/gharbi/defind-analytics/onchain/metadata/fetch_pool_metadata.py)

### Dual env

- `clickhouse` = remote-like
- `clickhouse_local` = dev local
- doc:
  - [clickhouse_dual_env_setup.md](/home/gharbi/defind-analytics/dbt/defind_analytics/analyses/ops/clickhouse_dual_env_setup.md)

## 10. Ce qu'il ne faut pas recâbler

- Ne pas remplacer `int_lp_events` comme source de vérité LP.
- Ne pas déplacer la logique mathématique V3 hors de `uniswap_math.sql`.
- Ne pas multiplier les grains SQL (`5m`, etc.) tant que le moteur Python n'existe pas.
- Ne pas convertir toute l'analytics de positions/backtest pour lire `tick_boundary_deltas`; cette représentation est surtout pour la famille `distribution`.
- Ne pas appeler `Collect` des "fees pures" sans passer par la décomposition `principal-first`.

## 11. Validation récente

État validé au moment de ce handoff:

- `dbt parse --target local` passe
- `dbt test --target local --select test_type:unit` passe
- Les modèles suivants ont été rebuildés avec succès après recâblage sur `int_tick_boundary_deltas`:
  - `int_tick_boundary_deltas`
  - `int_daily_tick_liquidity_net`
  - `int_hourly_tick_liquidity_net`
  - `mart_tvl_distribution`
- La chaîne NFPM current / lifecycle / PnL passe en local:
  - `int_nfpm_position_entry_state`
  - `mart_nfpm_position_pnl_current`
  - tests de couverture NFPM
  - tests de cohérence PnL

## 12. Ce qui reste optionnel

Rien de bloquant ne manque pour continuer.

Les ajouts encore possibles, mais non nécessaires pour avancer:

- data tests sur `int_tick_boundary_deltas`:
  - 2 lignes par event LP
  - somme des `liquidity_net_delta` = 0 par event
- baseline `weekly` SQL si on veut une vraie référence warehouse dédiée
- moteur Python multi-grains plus tard, branché sur les tables canoniques déjà prêtes
