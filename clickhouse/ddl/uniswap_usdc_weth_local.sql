-- Local Parquet-backed sources for the USDC/WETH pool.
-- These views are meant for clickhouse_local and read files from the host
-- datalake mounted read-only under:
--   /var/lib/clickhouse/user_files/defind-data
--
-- Expected host root:
--   ${LOCAL_DATALAKE_ROOT:-/home/gharbi/Defind/data}
--
-- Dataset path inside the mounted root:
--   defind-data/uniswap/usdc_weth_alchemy_full_c32/{Event}/*.parquet

CREATE VIEW IF NOT EXISTS uniswap_usdc_weth_mint AS
SELECT
    CAST(block_number AS Nullable(UInt64))    AS block_number,
    CAST(block_timestamp AS Nullable(UInt64)) AS block_timestamp,
    CAST(tx_hash AS Nullable(String))         AS tx_hash,
    CAST(log_index AS Nullable(UInt64))       AS log_index,
    CAST(contract AS Nullable(String))        AS contract,
    CAST(event AS Nullable(String))           AS event,
    CAST(amount AS Nullable(String))          AS amount,
    CAST(amount0 AS Nullable(String))         AS amount0,
    CAST(amount1 AS Nullable(String))         AS amount1,
    CAST(owner AS Nullable(String))           AS owner,
    CAST(sender AS Nullable(String))          AS sender,
    CAST(tickLower AS Nullable(String))       AS tickLower,
    CAST(tickUpper AS Nullable(String))       AS tickUpper
FROM file(
    'defind-data/uniswap/usdc_weth_alchemy_full_c32/Mint/*.parquet',
    'Parquet'
);

CREATE VIEW IF NOT EXISTS uniswap_usdc_weth_burn AS
SELECT
    CAST(block_number AS Nullable(UInt64))    AS block_number,
    CAST(block_timestamp AS Nullable(UInt64)) AS block_timestamp,
    CAST(tx_hash AS Nullable(String))         AS tx_hash,
    CAST(log_index AS Nullable(UInt64))       AS log_index,
    CAST(contract AS Nullable(String))        AS contract,
    CAST(event AS Nullable(String))           AS event,
    CAST(amount AS Nullable(String))          AS amount,
    CAST(amount0 AS Nullable(String))         AS amount0,
    CAST(amount1 AS Nullable(String))         AS amount1,
    CAST(owner AS Nullable(String))           AS owner,
    CAST(tickLower AS Nullable(String))       AS tickLower,
    CAST(tickUpper AS Nullable(String))       AS tickUpper
FROM file(
    'defind-data/uniswap/usdc_weth_alchemy_full_c32/Burn/*.parquet',
    'Parquet'
);

CREATE VIEW IF NOT EXISTS uniswap_usdc_weth_swap AS
SELECT
    CAST(block_number AS Nullable(UInt64))    AS block_number,
    CAST(block_timestamp AS Nullable(UInt64)) AS block_timestamp,
    CAST(tx_hash AS Nullable(String))         AS tx_hash,
    CAST(log_index AS Nullable(UInt64))       AS log_index,
    CAST(contract AS Nullable(String))        AS contract,
    CAST(event AS Nullable(String))           AS event,
    CAST(amount0 AS Nullable(String))         AS amount0,
    CAST(amount1 AS Nullable(String))         AS amount1,
    CAST(liquidity AS Nullable(String))       AS liquidity,
    CAST(recipient AS Nullable(String))       AS recipient,
    CAST(sender AS Nullable(String))          AS sender,
    CAST(sqrtPriceX96 AS Nullable(String))    AS sqrtPriceX96,
    CAST(tick AS Nullable(String))            AS tick
FROM file(
    'defind-data/uniswap/usdc_weth_alchemy_full_c32/Swap/*.parquet',
    'Parquet'
);
