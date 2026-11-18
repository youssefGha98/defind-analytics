#!/usr/bin/env python3
"""
Prepare local ClickHouse raw source views from a mounted local dataset.

This CLI is intended for the `clickhouse_local` environment. It:
- validates that the local dataset exists on disk
- infers the pool address from the first non-empty Initialize parquet chunk
  (fallback: Swap)
- recreates the local raw source views in ClickHouse
- checks whether analytics.pools already contains that pool
- prints the explicit fetch_pool_metadata.py command when metadata is missing

It does not fetch pool metadata automatically on purpose.
"""

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass
from pathlib import Path
from textwrap import dedent

from clickhouse_driver import Client
from dotenv import load_dotenv
from pyarrow import parquet as pq
from web3 import Web3

load_dotenv()

DEFAULT_CLICKHOUSE_HOST = "localhost"
DEFAULT_CLICKHOUSE_PORT = 9001
DEFAULT_CLICKHOUSE_USER = "default"
DEFAULT_CLICKHOUSE_DB = "analytics"
DEFAULT_DATA_ROOT = "/home/gharbi/Defind/data"
DEFAULT_DATASET_RELATIVE_PATH = "uniswap/usdc_weth_alchemy_full_c32"
CLICKHOUSE_MOUNT_ROOT = "defind-data"

VIEW_DEFINITIONS = {
    "uniswap_usdc_weth_mint": {
        "event_dir": "Mint",
        "columns": [
            ("block_number", "Nullable(UInt64)"),
            ("block_timestamp", "Nullable(UInt64)"),
            ("tx_hash", "Nullable(String)"),
            ("log_index", "Nullable(UInt64)"),
            ("contract", "Nullable(String)"),
            ("event", "Nullable(String)"),
            ("amount", "Nullable(String)"),
            ("amount0", "Nullable(String)"),
            ("amount1", "Nullable(String)"),
            ("owner", "Nullable(String)"),
            ("sender", "Nullable(String)"),
            ("tickLower", "Nullable(String)"),
            ("tickUpper", "Nullable(String)"),
        ],
    },
    "uniswap_usdc_weth_burn": {
        "event_dir": "Burn",
        "columns": [
            ("block_number", "Nullable(UInt64)"),
            ("block_timestamp", "Nullable(UInt64)"),
            ("tx_hash", "Nullable(String)"),
            ("log_index", "Nullable(UInt64)"),
            ("contract", "Nullable(String)"),
            ("event", "Nullable(String)"),
            ("amount", "Nullable(String)"),
            ("amount0", "Nullable(String)"),
            ("amount1", "Nullable(String)"),
            ("owner", "Nullable(String)"),
            ("tickLower", "Nullable(String)"),
            ("tickUpper", "Nullable(String)"),
        ],
    },
    "uniswap_usdc_weth_swap": {
        "event_dir": "Swap",
        "columns": [
            ("block_number", "Nullable(UInt64)"),
            ("block_timestamp", "Nullable(UInt64)"),
            ("tx_hash", "Nullable(String)"),
            ("log_index", "Nullable(UInt64)"),
            ("contract", "Nullable(String)"),
            ("event", "Nullable(String)"),
            ("amount0", "Nullable(String)"),
            ("amount1", "Nullable(String)"),
            ("liquidity", "Nullable(String)"),
            ("recipient", "Nullable(String)"),
            ("sender", "Nullable(String)"),
            ("sqrtPriceX96", "Nullable(String)"),
            ("tick", "Nullable(String)"),
        ],
    },
}


@dataclass
class EventScanResult:
    event_dir: str
    scanned_files: int
    empty_files: int
    unreadable_files: int
    contract: str | None
    source_file: Path | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bootstrap local ClickHouse raw source views from a mounted parquet dataset."
    )
    parser.add_argument(
        "--dataset",
        default=os.getenv("LOCAL_UNISWAP_DATASET_RELATIVE_PATH", DEFAULT_DATASET_RELATIVE_PATH),
        help="Relative dataset path under LOCAL_DATALAKE_ROOT.",
    )
    parser.add_argument(
        "--data-root",
        default=os.getenv("LOCAL_DATALAKE_ROOT", DEFAULT_DATA_ROOT),
        help="Host datalake root that is mounted into clickhouse_local.",
    )
    parser.add_argument(
        "--pool-address",
        default=None,
        help="Optional manual pool override. If omitted, the CLI infers the pool from Initialize parquet files.",
    )
    parser.add_argument(
        "--clickhouse-host",
        default=os.getenv("CLICKHOUSE_LOCAL_HOST", os.getenv("CLICKHOUSE_HOST", DEFAULT_CLICKHOUSE_HOST)),
        help="ClickHouse host for the local environment.",
    )
    parser.add_argument(
        "--clickhouse-port",
        type=int,
        default=int(
            os.getenv(
                "CLICKHOUSE_LOCAL_NATIVE_PORT",
                os.getenv("CLICKHOUSE_PORT", DEFAULT_CLICKHOUSE_PORT),
            )
        ),
        help="ClickHouse native port for the local environment.",
    )
    parser.add_argument(
        "--clickhouse-user",
        default=os.getenv("CLICKHOUSE_USER", DEFAULT_CLICKHOUSE_USER),
        help="ClickHouse user.",
    )
    parser.add_argument(
        "--clickhouse-password",
        default=os.getenv("CLICKHOUSE_PASSWORD", ""),
        help="ClickHouse password.",
    )
    parser.add_argument(
        "--clickhouse-db",
        default=os.getenv("CLICKHOUSE_DB", DEFAULT_CLICKHOUSE_DB),
        help="ClickHouse database.",
    )
    return parser.parse_args()


def get_clickhouse_client(args: argparse.Namespace) -> Client:
    return Client(
        host=args.clickhouse_host,
        port=args.clickhouse_port,
        user=args.clickhouse_user,
        password=args.clickhouse_password,
        database=args.clickhouse_db,
    )


def ensure_dataset_layout(dataset_dir: Path) -> None:
    if not dataset_dir.exists():
        raise FileNotFoundError(f"Dataset directory does not exist: {dataset_dir}")
    if not dataset_dir.is_dir():
        raise NotADirectoryError(f"Dataset path is not a directory: {dataset_dir}")

    required_dirs = {"Initialize", "Mint", "Burn", "Swap"}
    missing = sorted(name for name in required_dirs if not (dataset_dir / name).is_dir())
    if missing:
        raise FileNotFoundError(
            f"Dataset is missing required event directories: {', '.join(missing)}"
        )


def infer_pool_address(dataset_dir: Path, override: str | None) -> tuple[str, EventScanResult]:
    if override:
        pool_address = Web3.to_checksum_address(override)
        return pool_address, EventScanResult(
            event_dir="override",
            scanned_files=0,
            empty_files=0,
            unreadable_files=0,
            contract=pool_address,
            source_file=None,
        )

    initialize_result = scan_event_dir_for_contract(dataset_dir / "Initialize")
    if initialize_result.contract:
        return Web3.to_checksum_address(initialize_result.contract), initialize_result

    swap_result = scan_event_dir_for_contract(dataset_dir / "Swap")
    if swap_result.contract:
        return Web3.to_checksum_address(swap_result.contract), swap_result

    raise RuntimeError(
        "Unable to infer the pool address from the dataset. "
        "No non-empty parquet file with a readable `contract` column was found in "
        "Initialize or Swap."
    )


def scan_event_dir_for_contract(event_dir: Path) -> EventScanResult:
    scanned_files = 0
    empty_files = 0
    unreadable_files = 0

    for parquet_path in sorted(event_dir.glob("*.parquet")):
        scanned_files += 1
        try:
            parquet_file = pq.ParquetFile(parquet_path)
            metadata = parquet_file.metadata
            if metadata is None or metadata.num_rows <= 0:
                empty_files += 1
                continue

            if "contract" not in set(parquet_file.schema_arrow.names):
                unreadable_files += 1
                continue

            contract_table = parquet_file.read(columns=["contract"], use_threads=False)
            contract_column = contract_table.column("contract")
            for row_idx in range(contract_table.num_rows):
                value = contract_column[row_idx].as_py()
                if value:
                    return EventScanResult(
                        event_dir=event_dir.name,
                        scanned_files=scanned_files,
                        empty_files=empty_files,
                        unreadable_files=unreadable_files,
                        contract=value,
                        source_file=parquet_path,
                    )
            empty_files += 1
        except Exception:
            unreadable_files += 1

    return EventScanResult(
        event_dir=event_dir.name,
        scanned_files=scanned_files,
        empty_files=empty_files,
        unreadable_files=unreadable_files,
        contract=None,
        source_file=None,
    )


def sql_literal(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def build_view_sql(
    view_name: str, event_dir: str, columns: list[tuple[str, str]], dataset: str
) -> str:
    column_sql = ",\n".join(
        f"    CAST({column_name} AS {column_type}) AS {column_name}"
        for column_name, column_type in columns
    )
    file_path = f"{CLICKHOUSE_MOUNT_ROOT}/{dataset}/{event_dir}/*.parquet"
    return dedent(
        f"""
        CREATE VIEW {view_name} AS
        SELECT
        {column_sql}
        FROM file(
            {sql_literal(file_path)},
            'Parquet'
        )
        """
    ).strip()


def recreate_views(client: Client, dataset: str) -> None:
    for view_name, view_def in VIEW_DEFINITIONS.items():
        client.execute(f"DROP VIEW IF EXISTS {view_name}")
        client.execute(
            build_view_sql(
                view_name=view_name,
                event_dir=view_def["event_dir"],
                columns=view_def["columns"],
                dataset=dataset,
            )
        )


def pools_table_exists(client: Client, database: str) -> bool:
    rows = client.execute(
        "SELECT count() FROM system.tables WHERE database = %(database)s AND name = 'pools'",
        {"database": database},
    )
    return bool(rows[0][0])


def pool_metadata_exists(client: Client, pool_address: str) -> bool:
    rows = client.execute(
        "SELECT count() FROM pools WHERE pool = %(pool)s",
        {"pool": pool_address},
    )
    return bool(rows[0][0])


def metadata_command(args: argparse.Namespace, pool_address: str) -> str:
    return dedent(
        f"""
        cd /home/gharbi/defind-analytics
        CLICKHOUSE_HOST={args.clickhouse_host} \\
        CLICKHOUSE_PORT={args.clickhouse_port} \\
        CLICKHOUSE_USER={args.clickhouse_user} \\
        CLICKHOUSE_PASSWORD={args.clickhouse_password} \\
        CLICKHOUSE_DB={args.clickhouse_db} \\
        .venv/bin/python onchain/metadata/fetch_pool_metadata.py --pool-address {pool_address}
        """
    ).strip()


def main() -> None:
    args = parse_args()
    dataset_dir = Path(args.data_root).expanduser() / args.dataset
    ensure_dataset_layout(dataset_dir)

    pool_address, scan_result = infer_pool_address(dataset_dir, args.pool_address)

    print("Bootstrapping local ClickHouse sources")
    print(f"  host dataset root: {Path(args.data_root).expanduser()}")
    print(f"  dataset:           {args.dataset}")
    print(f"  clickhouse:        {args.clickhouse_host}:{args.clickhouse_port}/{args.clickhouse_db}")
    print(f"  inferred pool:     {pool_address}")
    if scan_result.event_dir == "override":
        print("  detection source:  manual override")
    else:
        source_file = scan_result.source_file.name if scan_result.source_file else "<none>"
        print(
            f"  detection source:  {scan_result.event_dir} "
            f"(scanned={scan_result.scanned_files}, empty={scan_result.empty_files}, "
            f"unreadable={scan_result.unreadable_files}, file={source_file})"
        )

    client = get_clickhouse_client(args)
    recreate_views(client, args.dataset)
    print("  local views:       recreated uniswap_usdc_weth_{mint,burn,swap}")

    if not pools_table_exists(client, args.clickhouse_db) or not pool_metadata_exists(client, pool_address):
        print()
        print(f"Pool metadata is not present yet for {pool_address}.")
        print("Run this CLI command before dbt:")
        print()
        print(metadata_command(args, pool_address))
    else:
        print(f"  pool metadata:     already present in {args.clickhouse_db}.pools")

    print()
    print("Current tables:")
    rows = client.execute(
        "SELECT database, name, engine FROM system.tables WHERE database = %(database)s ORDER BY name",
        {"database": args.clickhouse_db},
    )
    for database, name, engine in rows:
        print(f"  - {database}.{name} [{engine}]")


if __name__ == "__main__":
    main()
