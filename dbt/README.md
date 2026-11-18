# dbt — Guide complet

## C'est quoi dbt ?

dbt (data build tool) transforme tes données **dans** ClickHouse via des fichiers SQL.
Il ne déplace pas de données — il envoie du SQL et laisse ClickHouse calculer.

```
toi → fichiers .sql → dbt compile → ClickHouse exécute → tables/vues
```

---

## Structure d'un projet dbt

```
dbt/
├── dbt_project.yml        ← config principale (nom, chemins, matérialisations)
├── profiles.yml           ← connexion à ClickHouse (host, user, password...)
├── models/
│   ├── sources.yml        ← déclare les tables sources (tes tables S3 sur R2)
│   ├── staging/           ← nettoyage des données brutes
│   │   ├── stg_swaps.sql
│   │   ├── stg_mints.sql
│   │   └── stg_burns.sql
│   └── marts/             ← métriques business
│       ├── mart_daily_volume.sql
│       └── mart_liquidity.sql
└── tests/                 ← tests de qualité des données
```

---

## Les fichiers clés

### `dbt_project.yml`
Config principale du projet. Définit le nom, les chemins, et les matérialisations par défaut.

```yaml
name: defind_analytics
models:
  defind_analytics:
    staging:
      +materialized: view      # les staging sont des vues
    marts:
      +materialized: table     # les marts sont des tables
```

### `profiles.yml`
Connexion à la base de données. **Ne jamais committer ce fichier** (il contient les credentials).
Il vit dans `~/.dbt/profiles.yml` par convention, mais on peut le mettre localement.

```yaml
defind_analytics:
  target: dev
  outputs:
    dev:
      type: clickhouse
      host: localhost
      port: 8123              # ClickHouse HTTP port (pas 9000)
      user: default
      password: "1234"
      database: analytics
      secure: false
```

---

## Les couches (layers)

### Staging
Prend les données brutes et les rend propres et utilisables.
- Cast des types (`String` → `Decimal`, `UInt64` → `DateTime`)
- Renommage des colonnes pour plus de clarté
- Application des decimals des tokens (USDC = 6, WETH = 18)

```sql
-- models/staging/stg_swaps.sql
SELECT
    tx_hash,
    block_number,
    toDateTime(block_timestamp)                   AS block_time,
    toDecimal128(amount0, 38) / pow(10, 6)        AS amount0_usdc,
    toDecimal128(amount1, 38) / pow(10, 18)       AS amount1_weth,
    sender,
    recipient
FROM {{ source('analytics', 'uniswap_usdc_weth_swap') }}
```

### Marts
Construits à partir des modèles staging. Contiennent les métriques business.

```sql
-- models/marts/lp_analytics/mart_volume_daily.sql
SELECT
    toDate(block_time)      AS date,
    sum(abs(amount0_usdc))  AS volume_usdc,
    count()                 AS nb_swaps
FROM {{ ref('stg_swaps') }}
GROUP BY date
ORDER BY date
```

---

## Les deux fonctions fondamentales

| Fonction | Usage | Exemple |
|---|---|---|
| `{{ source('db', 'table') }}` | Référence une table existante (tes tables S3) | `{{ source('analytics', 'uniswap_usdc_weth_swap') }}` |
| `{{ ref('model') }}` | Référence un autre modèle dbt | `{{ ref('stg_swaps') }}` |

dbt construit un graphe de dépendances à partir de ces références
et exécute les modèles dans le bon ordre automatiquement.

```
source (swap S3)
      ↓
  stg_swaps
      ↓
mart_daily_volume
```

---

## Les matérialisations

| Type | Description | Quand l'utiliser |
|---|---|---|
| `view` | Recalculée à chaque query, pas stockée | Staging — données toujours fraîches |
| `table` | Matérialisée dans ClickHouse | Marts — requêtes répétées, perfs |
| `incremental` | Ajoute seulement les nouvelles rows | Grandes tables qui grossissent |

---

## Les commandes essentielles

```bash
# Exécuter tous les modèles
dbt run

# Exécuter un seul modèle
dbt run --select stg_swaps

# Exécuter un modèle et tout ce qui en dépend
dbt run --select +mart_daily_volume

# Lancer les tests
dbt test

# Générer la doc
dbt docs generate
dbt docs serve    # ouvre un navigateur avec le lineage graph

# Compiler sans exécuter (voir le SQL généré)
dbt compile
```

---

## Les tests

dbt permet de tester la qualité des données directement dans les fichiers `.yml`.

```yaml
models:
  - name: stg_swaps
    columns:
      - name: tx_hash
        tests:
          - not_null
          - unique
      - name: block_number
        tests:
          - not_null
```

---

## Notre pipeline complet

```
R2 (Parquet)
├── uniswap_usdc_weth_swap   ──→  stg_swaps  ──→  mart_daily_volume
├── uniswap_usdc_weth_mint   ──→  stg_mints  ──→  mart_liquidity
└── uniswap_usdc_weth_burn   ──→  stg_burns  ──┘

pools (MergeTree)            ──→  joinable avec tous les marts
```

---

## Commandes de setup (une seule fois)

```bash
# Installer dbt avec le connecteur ClickHouse
pip3 install dbt-clickhouse --break-system-packages

# Vérifier l'installation
dbt --version

# Initialiser le projet (depuis la racine defind-analytics/)
dbt init defind_analytics --skip-profile-setup

# Tester la connexion
dbt debug
```
