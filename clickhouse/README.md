# ClickHouse

## Démarrer le serveur

```bash
docker compose up -d clickhouse
```

## Démarrer l'environnement local

```bash
docker compose up -d clickhouse_local
```

## Démarrer les deux environnements

```bash
docker compose up -d clickhouse clickhouse_local
```

## Se connecter au client interactif

```bash
docker exec -it clickhouse clickhouse-client --user default --password 1234 --database analytics
```

## Se connecter à l'environnement local

```bash
docker exec -it clickhouse_local clickhouse-client --user default --password 1234 --database analytics
```

## Exécuter un fichier SQL

```bash
docker exec -i clickhouse clickhouse-client \
  --user default --password 1234 \
  --database analytics \
  < clickhouse/ddl/<fichier>.sql
```

## Créer les tables uniswap usdc/weth

```bash
docker exec -i clickhouse clickhouse-client \
  --user default --password 1234 \
  --database analytics \
  < clickhouse/ddl/uniswap_usdc_weth.sql
```

## Créer les sources locales uniswap usdc/weth

```bash
cat clickhouse/ddl/uniswap_usdc_weth_local.sql | docker exec -i clickhouse_local \
  clickhouse-client --user default --password 1234 --database analytics
```

## Bootstrap local automatisé

La commande recommandée pour préparer `clickhouse_local` est maintenant:

```bash
.venv/bin/python clickhouse/scripts/bootstrap_local_sources.py
```

Elle:

- recrée les vues locales `uniswap_usdc_weth_{swap,mint,burn}`
- lit le dataset pointé par `LOCAL_UNISWAP_DATASET_RELATIVE_PATH`
- détecte automatiquement la pool depuis le premier chunk `Initialize` non vide
  avec `pyarrow` et fallback sur `Swap`
- vérifie si `analytics.pools` contient la metadata du pool cible
- affiche la commande CLI à lancer si la metadata manque

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

## Fetch pool metadata en CLI

La metadata pool doit être créée explicitement via:

```bash
cd /home/gharbi/defind-analytics
CLICKHOUSE_HOST=localhost \
CLICKHOUSE_PORT=9001 \
CLICKHOUSE_USER=default \
CLICKHOUSE_PASSWORD=1234 \
CLICKHOUSE_DB=analytics \
.venv/bin/python onchain/metadata/fetch_pool_metadata.py --pool-address 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
```

## Vérifier les tables

```bash
docker exec clickhouse clickhouse-client --user default --password 1234 --database analytics --query "SHOW TABLES"
```

## Supprimer les tables

```bash
docker exec clickhouse clickhouse-client --user default --password 1234 --database analytics --query "
DROP TABLE IF EXISTS uniswap_usdc_weth_mint;
DROP TABLE IF EXISTS uniswap_usdc_weth_burn;
DROP TABLE IF EXISTS uniswap_usdc_weth_swap;
"
```

## Credentials R2 (fichiers non versionnés)

Trois fichiers contiennent des clés R2 et sont exclus du repo (`.gitignore`). Le repo
fournit des templates `*.example` avec des placeholders `YOUR_R2_*` :

```bash
cp clickhouse/config/remote/r2-storage.xml.example clickhouse/config/remote/r2-storage.xml
cp clickhouse/config/legacy/r2-storage.xml.example clickhouse/config/legacy/r2-storage.xml
cp clickhouse/ddl/uniswap_usdc_weth.sql.example    clickhouse/ddl/uniswap_usdc_weth.sql
# puis remplacer YOUR_R2_ACCOUNT_ID / YOUR_R2_ACCESS_KEY_ID / YOUR_R2_SECRET_ACCESS_KEY
```

Le suffixe `.xml.example` n'est pas chargé par ClickHouse (seuls `*.xml`, `*.yaml`, `*.conf`
le sont dans `config.d`). Seul l'environnement `clickhouse` (remote, R2) en a besoin ;
`clickhouse_local` lit le datalake local et fonctionne sans.
