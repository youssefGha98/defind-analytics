# ClickHouse Dual Environment Setup

Ce document sert de guide de travail et de mémo de reproduction pour mettre en
place deux environnements ClickHouse côte à côte dans ce repo:

- `local`: itération rapide sur datalake local + warehouse local
- `remote`: environnement plus proche du staging/prod, avec sources R2 et
  stockage distant pour les tables lourdes de staging

L'objectif est de pouvoir switcher facilement entre les deux sans réécrire les
modèles dbt.

## 1. Pourquoi on fait ça

Aujourd'hui, le projet fonctionne bien avec ClickHouse et dbt, mais le mode
remote a deux contraintes pour l'itération:

- les sources brutes sont lues via R2
- certaines tables lourdes de staging utilisent `storage_policy = 'r2_policy'`
- les `full-refresh` sur les grosses tables comme `stg_swaps` sont longs

Pour itérer vite sur les modèles, on veut un mode où:

- ClickHouse lit les données brutes depuis un datalake local
- le warehouse (`stg_*`, `int_*`, `mart_*`) est lui aussi local
- on peut relancer dbt rapidement sans dépendre de R2

En parallèle, on veut garder un mode `remote` qui reste proche du comportement
prod/staging.

## 2. État actuel du repo

### dbt

- Profil dbt actuel: [profiles.yml](/home/gharbi/defind-analytics/dbt/defind_analytics/profiles.yml)
- Aujourd'hui, il n'y a qu'un seul target: `dev`
- Les modèles staging lisent des sources via:
  - `source('analytics', 'uniswap_usdc_weth_swap')`
  - `source('analytics', 'uniswap_usdc_weth_mint')`
  - `source('analytics', 'uniswap_usdc_weth_burn')`
  - `source('analytics', 'pools')`

### Sources ClickHouse

- Déclaration dbt des sources: [sources.yml](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/sources.yml)
- DDL actuel des sources externes R2:
  [uniswap_usdc_weth.sql](/home/gharbi/defind-analytics/clickhouse/ddl/uniswap_usdc_weth.sql)

### Stockage ClickHouse

- Config R2 courante:
  [r2-storage.xml](/home/gharbi/defind-analytics/clickhouse/config/remote/r2-storage.xml)
- Le service ClickHouse courant est défini dans:
  [docker-compose.yml](/home/gharbi/defind-analytics/docker-compose.yml)

### Modèles dbt concernés par le stockage remote

- [stg_swaps.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_swaps.sql)
- [stg_mints.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_mints.sql)
- [stg_burns.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_burns.sql)

Ces modèles ont aujourd'hui une config liée au remote:

- `materialized='incremental'`
- `settings={'storage_policy': 'r2_policy'}`

## 3. Décision d'architecture

On ne va pas essayer de faire cohabiter deux jeux de sources dans une seule
instance ClickHouse. On va plutôt utiliser deux environnements séparés.

### Cible

- `clickhouse_local`
  - lit un datalake local
  - stocke tout en local
  - target dbt: `local`
  - usage: dev rapide

- `clickhouse_remote`
  - lit les sources R2
  - garde la config `r2_policy`
  - target dbt: `remote`
  - usage: staging/prod-like

### Pourquoi ce choix est simple

Les modèles dbt lisent déjà des `source('analytics', ...)`.

Donc si:

- les deux instances ClickHouse ont les mêmes noms de tables sources
- les deux utilisent le même schema `analytics`

alors les modèles SQL n'ont presque pas besoin de changer.

Le switch se fera surtout via:

- le port / host ClickHouse
- le target dbt
- le DDL utilisé pour créer les tables sources
- l'activation ou non de `r2_policy`

## 4. Ce qu'on veut obtenir à la fin

### Commandes dbt attendues

Mode local:

```bash
cd /home/gharbi/defind-analytics/dbt/defind_analytics
../../.venv/bin/dbt run --target local --select stg_swaps
```

Mode remote:

```bash
cd /home/gharbi/defind-analytics/dbt/defind_analytics
../../.venv/bin/dbt run --target remote --select stg_swaps
```

### Commandes ClickHouse attendues

Démarrer local:

```bash
docker compose up -d clickhouse_local
```

Démarrer remote:

```bash
docker compose up -d clickhouse
```

Ou les deux:

```bash
docker compose up -d clickhouse clickhouse_local
```

## 5. Plan de mise en place pas à pas

On appliquera ces étapes dans cet ordre.

### Étape 1 — Dupliquer le service ClickHouse dans Docker

Fichier principal:
- [docker-compose.yml](/home/gharbi/defind-analytics/docker-compose.yml)

But:

- garder le service ClickHouse actuel tel quel
- ajouter un service `clickhouse_local`
- donner à chaque service:
  - un nom de conteneur distinct
  - un port HTTP distinct
  - un port natif distinct
  - un volume data distinct

Première étape retenue dans ce repo:

- on garde l'environnement ClickHouse actuel tel quel sur `8123` / `9000`
- on ajoute `clickhouse_local` à côté sur `8124` / `9001`

Pourquoi on fait comme ça au début:

- on ne casse pas l'environnement remote-like déjà fonctionnel
- on peut valider le dual-env sans migration brutale
- on pourra toujours inverser les ports plus tard si on veut faire du local
  l'environnement par défaut

### Étape 2 — Ajouter deux targets dbt

Fichier principal:
- [profiles.yml](/home/gharbi/defind-analytics/dbt/defind_analytics/profiles.yml)

But:

- ajouter `local`
- ajouter `remote`

Convention proposée:

- `local`
  - host: `localhost`
  - port: `8124`
  - schema: `analytics`

- `remote`
  - host: `localhost`
  - port: `8123`
  - schema: `analytics`

Important:

- on gardera le même schema `analytics` des deux côtés
- ça permet aux modèles dbt et aux `source()` de rester identiques
- le target par défaut sera `remote` pour préserver le comportement actuel

### Étape 3 — Séparer les DDL des sources

On va créer deux scripts de tables sources:

- `clickhouse/ddl/uniswap_usdc_weth.sql`
- `clickhouse/ddl/uniswap_usdc_weth_local.sql`

#### Remote

Le script remote reprendra la logique actuelle:

- tables externes pointant vers R2 via `ENGINE = S3(...)`

#### Local

Le script local devra pointer vers des fichiers du datalake local.

Deux options possibles:

1. `ENGINE = File(Parquet)` si les fichiers sont accessibles localement au
   conteneur de manière simple
2. `ENGINE = S3(...)` vers un endpoint local compatible S3 si un service de
   type MinIO existe

Par défaut, on vise le cas le plus simple:

- montage du datalake local dans le conteneur
- tables sources locales lisant ces fichiers localement

Chemin local confirmé sur cette machine:

- `/home/gharbi/Defind/data`

Pool dataset confirmé:

- `/home/gharbi/Defind/data/uniswap/usdc_weth_alchemy_full_c32`

Sous-dossiers observés:

- `Burn`
- `Mint`
- `Swap`
- et d'autres événements futurs (`Collect`, `Flash`, etc.)

Choix retenu:

- monter `${LOCAL_DATALAKE_ROOT:-/home/gharbi/Defind/data}` dans
  `clickhouse_local`
- point de montage dans le conteneur:
  `/var/lib/clickhouse/user_files/defind-data`
- créer des vues locales ClickHouse via `file('defind-data/.../*.parquet', 'Parquet')`
- garder les mêmes noms de sources dbt:
  - `uniswap_usdc_weth_swap`
  - `uniswap_usdc_weth_mint`
  - `uniswap_usdc_weth_burn`

### Étape 4 — Rendre le stockage staging dépendant du target

Fichiers principaux:

- [stg_swaps.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_swaps.sql)
- [stg_mints.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_mints.sql)
- [stg_burns.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_burns.sql)

But:

- en `remote`, garder `storage_policy = 'r2_policy'`
- en `local`, ne pas appliquer de policy remote

Forme attendue:

- config conditionnelle dbt/Jinja selon `target.name`

Exemple d'intention:

```jinja
{% set staging_settings = {'storage_policy': 'r2_policy'} if target.name == 'remote' else {} %}
```

Puis:

```jinja
{{ config(settings=staging_settings) }}
```

Important:

- on ne veut pas dupliquer les modèles
- on veut juste rendre la config de stockage dépendante du target

Résultat attendu:

- `--target remote`
  - `stg_swaps`, `stg_mints`, `stg_burns` gardent `storage_policy = 'r2_policy'`
- `--target local`
  - ces mêmes modèles n'appliquent aucune policy spéciale
  - ClickHouse écrit donc sur le storage local par défaut

### Étape 5 — Créer un bootstrap simple pour chaque environnement

On voudra deux séquences de bootstrap claires.

#### Bootstrap remote

1. démarrer `clickhouse_remote`
2. charger la config R2
3. créer les tables sources remote
4. recréer `pools`
5. lancer dbt avec `--target remote`

#### Bootstrap local

1. démarrer `clickhouse_local`
2. monter le datalake local
3. créer les tables sources locales
4. recréer `pools`
5. lancer dbt avec `--target local`

## 6. Ce qu'on ne veut pas faire

Pour éviter la complexité, on ne veut pas:

- ajouter des `if` partout dans les modèles SQL
- changer les noms des sources dbt selon l'environnement
- utiliser une seule instance ClickHouse avec deux jeux de tables
  `analytics_local.*` et `analytics_remote.*`

Ce serait faisable, mais plus fragile et moins lisible.

## 7. Risques et points d'attention

### Secrets

Aujourd'hui, certaines clés d'accès R2 sont présentes dans des fichiers SQL/XML
locaux. À terme, il faudra idéalement:

- sortir ça vers des variables d'environnement
- éviter de figer des credentials dans les DDL

### Données locales

Le mode `local` suppose qu'on sache où vivent les Parquet localement.

Avant de brancher `clickhouse_local`, il faudra clarifier:

- le chemin exact du datalake local
- le pattern des fichiers:
  - `Swap/*.parquet`
  - `Mint/*.parquet`
  - `Burn/*.parquet`

### Pools metadata

La table `analytics.pools` n'est pas créée par dbt.
Elle est bootstrapée via:

- [fetch_pool_metadata.py](/home/gharbi/defind-analytics/onchain/metadata/fetch_pool_metadata.py)

Il faudra donc la recréer dans les deux environnements.

## 8. Ordre recommandé pour nous

Quand on reprendra l'implémentation, l'ordre recommandé est:

1. dupliquer le service Docker
2. ajouter les deux targets dbt
3. rendre `storage_policy` conditionnelle
4. créer les DDL sources `remote` / `local`
5. tester `remote` sans casser l'existant
6. brancher le datalake local
7. tester un run complet `local`

## 9. Résultat attendu

À la fin, on doit pouvoir:

- développer vite en local
- garder un environnement remote fidèle au comportement prod-like
- switcher avec une simple option `--target`
- éviter de retoucher les modèles métier quand on change d'environnement

## 11. État après l'étape 1

L'étape 1 est maintenant appliquée dans le repo:

- service existant conservé:
  - service Docker: `clickhouse`
  - container: `clickhouse`
  - ports hôte: `8123` / `9000`
  - rôle: remote-like

- nouveau service ajouté:
  - service Docker: `clickhouse_local`
  - container: `clickhouse_local`
  - ports hôte: `8124` / `9001`
  - rôle: futur environnement local

- volume remote-like:
  - `clickhouse_data`

- volume local:
  - `clickhouse_local_data`

- config remote-like:
  - [remote](/home/gharbi/defind-analytics/clickhouse/config/remote)

- config locale minimale:
  - [local](/home/gharbi/defind-analytics/clickhouse/config/local)

Choix important:

- on n'a pas renommé le service actuel en `clickhouse_remote` pour éviter de
  casser les commandes et le setup déjà fonctionnel
- on pourra faire ce renommage plus tard si on veut harmoniser les noms

## 12. État après l'étape 2

L'étape 2 est maintenant appliquée dans le repo:

- [profiles.yml](/home/gharbi/defind-analytics/dbt/defind_analytics/profiles.yml)
  expose maintenant deux targets dbt:
  - `remote` -> `localhost:8123`
  - `local` -> `localhost:8124`

Décision prise:

- `remote` est le target par défaut
- ça évite de casser les commandes dbt existantes
- le mode local est opt-in via `--target local`

Commandes attendues:

```bash
cd /home/gharbi/defind-analytics/dbt/defind_analytics
../../.venv/bin/dbt debug --target remote
../../.venv/bin/dbt debug --target local
```

Puis:

```bash
../../.venv/bin/dbt run --target remote --select ...
../../.venv/bin/dbt run --target local --select ...
```

## 13. État après l'étape 3

L'étape 3 est maintenant appliquée dans le repo.

### Ce qui a été ajouté

- montage du datalake local dans `clickhouse_local` via
  [docker-compose.yml](/home/gharbi/defind-analytics/docker-compose.yml):
  - host:
    `${LOCAL_DATALAKE_ROOT:-/home/gharbi/Defind/data}`
  - conteneur:
    `/var/lib/clickhouse/user_files/defind-data`
  - mode: lecture seule

Variable d'environnement recommandée:

- `LOCAL_DATALAKE_ROOT=/home/gharbi/Defind/data`

Elle peut être définie dans:

- [.env](/home/gharbi/defind-analytics/.env)
- [.env.example](/home/gharbi/defind-analytics/.env.example)

- script DDL local:
  [uniswap_usdc_weth_local.sql](/home/gharbi/defind-analytics/clickhouse/ddl/uniswap_usdc_weth_local.sql)

### Choix retenu pour les sources locales

On ne crée pas des tables `ENGINE = S3(...)` comme en remote.
On crée des `VIEW` qui lisent directement les Parquet montés localement via:

```sql
file('defind-data/.../*.parquet', 'Parquet')
```

Pourquoi ce choix:

- très simple à comprendre
- pas de dépendance réseau
- réutilisable pour d'autres événements plus tard
- mêmes noms de sources dbt qu'en remote

### Événements déjà visibles dans le datalake local

Le dataset local contient déjà:

- `Burn`
- `Mint`
- `Swap`
- `Collect`
- `CollectProtocol`
- `Flash`
- `IncreaseObservationCardinalityNext`
- `Initialize`
- `SetFeeProtocol`

Donc on pourra brancher d'autres sources plus tard sans changer l'architecture.

### Commandes de bootstrap local

Redémarrer `clickhouse_local` avec le mount:

```bash
cd /home/gharbi/defind-analytics
docker compose up -d clickhouse_local
```

Créer les sources locales manuellement:

```bash
cd /home/gharbi/defind-analytics
cat clickhouse/ddl/uniswap_usdc_weth_local.sql | docker exec -i clickhouse_local \
  clickhouse-client --user default --password 1234 --database analytics
```

Vérifier les sources locales:

```bash
docker exec clickhouse_local clickhouse-client \
  --user default --password 1234 --database analytics \
  --query "SELECT database, name, engine FROM system.tables WHERE database = 'analytics' ORDER BY name FORMAT Vertical"
```

Tester la lecture directe des Parquet locaux:

```bash
docker exec clickhouse_local clickhouse-client \
  --user default --password 1234 --database analytics \
  --query "SELECT count() FROM file('defind-data/uniswap/usdc_weth_alchemy_full_c32/Swap/*.parquet', 'Parquet')"
```

### Résultat validé

Sur cette machine:

- le mount local fonctionne
- `file(..., 'Parquet')` fonctionne avec wildcard
- `uniswap_usdc_weth_swap` local lit bien `10,763,869` lignes

### Point encore nécessaire avant un vrai `dbt run --target local`

Il faut aussi bootstraper `analytics.pools` dans `clickhouse_local`.

Bonne nouvelle:

- [fetch_pool_metadata.py](/home/gharbi/defind-analytics/onchain/metadata/fetch_pool_metadata.py)
  lit déjà `CLICKHOUSE_HOST`, `CLICKHOUSE_PORT`, `CLICKHOUSE_USER`,
  `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DB`
- donc il peut déjà écrire vers `clickhouse_local` sans code change

Commande attendue:

```bash
cd /home/gharbi/defind-analytics
CLICKHOUSE_HOST=localhost \
CLICKHOUSE_PORT=9001 \
CLICKHOUSE_USER=default \
CLICKHOUSE_PASSWORD=1234 \
CLICKHOUSE_DB=analytics \
.venv/bin/python onchain/metadata/fetch_pool_metadata.py
```

### Bootstrap local automatisé

Une commande unique existe maintenant pour éviter toutes les étapes manuelles:

```bash
cd /home/gharbi/defind-analytics
.venv/bin/python clickhouse/scripts/bootstrap_local_sources.py
```

Cette CLI:

- recharge `.env`
- vérifie que le dataset local existe bien sur disque
- détecte automatiquement la pool depuis le premier chunk `Initialize` non vide
  avec `pyarrow`
- fallback sur `Swap` si `Initialize` ne contient aucune ligne exploitable
- recrée les vues locales `uniswap_usdc_weth_{swap,mint,burn}`
- vérifie si la metadata pool existe déjà
- affiche la commande CLI à lancer si `analytics.pools` est absente ou incomplète

Variables lues depuis `.env`:

- `LOCAL_DATALAKE_ROOT`
- `LOCAL_UNISWAP_DATASET_RELATIVE_PATH`
- `CLICKHOUSE_USER`
- `CLICKHOUSE_PASSWORD`
- `CLICKHOUSE_DB`

Override manuel possible:

```bash
.venv/bin/python clickhouse/scripts/bootstrap_local_sources.py --pool-address 0x...
```

Validation faite:

- la CLI tourne correctement sur le pool USDC/WETH actuel
- elle détecte la pool via `Initialize`
- elle prépare `clickhouse_local` sans SQL manuel

### Règle de fonctionnement retenue

La metadata pool n'est plus fetchée implicitement par le bootstrap local.

On veut un workflow explicite:

1. préparer les sources locales
2. lancer la commande CLI `fetch_pool_metadata.py`
3. lancer dbt

Pourquoi:

- plus lisible
- plus reproductible
- plus simple à comprendre quand on change de pool
- pas de side effect RPC caché dans un bootstrap infra

### Garde-fou côté dbt

dbt vérifie maintenant au démarrage que `analytics.pools` existe.

Si la table manque, dbt échoue tôt avec un message clair et la commande CLI à
lancer:

```bash
cd /home/gharbi/defind-analytics
CLICKHOUSE_HOST=localhost \
CLICKHOUSE_PORT=9001 \
CLICKHOUSE_USER=default \
CLICKHOUSE_PASSWORD=1234 \
CLICKHOUSE_DB=analytics \
.venv/bin/python onchain/metadata/fetch_pool_metadata.py --pool-address <pool_address>
```

En target `local`, le message rappelle aussi:

```bash
.venv/bin/python clickhouse/scripts/bootstrap_local_sources.py
```

si les vues locales n'ont pas encore été créées.

Point d'attention:

- le repo dbt reste aujourd'hui sémantiquement centré sur le pool USDC/WETH
- on peut facilement repointer le bootstrap local vers un autre dataset/pool
- mais pour un pool qui ne suit plus les hypothèses USDC/WETH, certaines
  métriques downstream devront être généralisées

## 14. État après l'étape 4

L'étape 4 est maintenant appliquée dans le repo.

Fichiers modifiés:

- [stg_swaps.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_swaps.sql)
- [stg_mints.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_mints.sql)
- [stg_burns.sql](/home/gharbi/defind-analytics/dbt/defind_analytics/models/staging/stg_burns.sql)

Pattern retenu:

```jinja
{% set staging_settings = {'storage_policy': 'r2_policy'} if target.name == 'remote' else {} %}
```

Puis dans `config(...)`:

```jinja
settings=staging_settings
```

Conséquence pratique:

- target `remote`
  - comportement inchangé
  - les grosses tables staging continuent d'utiliser `r2_policy`

- target `local`
  - aucun `storage_policy` spécifique n'est injecté
  - les tables staging utilisent donc le disque local par défaut de
    `clickhouse_local`

Validation faite:

```bash
cd /home/gharbi/defind-analytics/dbt/defind_analytics
../../.venv/bin/dbt parse --target remote
../../.venv/bin/dbt parse --target local
```

Les deux parses passent.

## 10. Notes de suivi

Ce document est volontairement vivant.

À chaque étape implémentée, on pourra y ajouter:

- ce qui a été modifié
- les commandes exactes utilisées
- les problèmes rencontrés
- la solution retenue

L'idée est qu'il serve à la fois de:

- guide de mise en place
- mémo de debug
- documentation de reproduction
