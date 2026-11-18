#!/usr/bin/env python3
"""
Prepare local ClickHouse raw source views for the Uniswap V3 NFPM dataset.

This CLI is intended for the `clickhouse_local` environment. It:
- validates that the local NFPM dataset exists on disk
- recreates the local raw source views in ClickHouse

Unlike the pool bootstrap, there is no pool inference here because NFPM is a
protocol-level dataset.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from textwrap import dedent

from clickhouse_driver import Client
from dotenv import load_dotenv

load_dotenv()

DEFAULT_CLICKHOUSE_HOST = "localhost"
DEFAULT_CLICKHOUSE_PORT = 9001
DEFAULT_CLICKHOUSE_USER = "default"
DEFAULT_CLICKHOUSE_DB = "analytics"
DEFAULT_DATA_ROOT = "/home/gharbi/Defind/data"
DEFAULT_NFPM_DATASET_RELATIVE_PATH = "uniswap/nfpm"
CLICKHOUSE_MOUNT_ROOT = "defind-data"

VIEW_DEFINITIONS = {
    "uniswap_nfpm_transfer": {
        "event_dir": "Transfer",
        "columns": [
            ("block_number", "Nullable(UInt64)"),
            ("block_timestamp", "Nullable(UInt64)"),
            ("tx_hash", "Nullable(String)"),
            ("log_index", "Nullable(UInt64)"),
            ("contract", "Nullable(String)"),
            ("event", "Nullable(String)"),
            ("from", "Nullable(String)"),
            ("to", "Nullable(String)"),
            ("tokenId", "Nullable(String)"),
        ],
    },
    "uniswap_nfpm_increase_liquidity": {
        "event_dir": "IncreaseLiquidity",
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
            ("tokenId", "Nullable(String)"),
        ],
    },
    "uniswap_nfpm_decrease_liquidity": {
        "event_dir": "DecreaseLiquidity",
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
            ("tokenId", "Nullable(String)"),
        ],
    },
    "uniswap_nfpm_collect": {
        "event_dir": "Collect",
        "columns": [
            ("block_number", "Nullable(UInt64)"),
            ("block_timestamp", "Nullable(UInt64)"),
            ("tx_hash", "Nullable(String)"),
            ("log_index", "Nullable(UInt64)"),
            ("contract", "Nullable(String)"),
            ("event", "Nullable(String)"),
            ("amount0", "Nullable(String)"),
            ("amount1", "Nullable(String)"),
            ("recipient", "Nullable(String)"),
            ("tokenId", "Nullable(String)"),
        ],
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bootstrap local ClickHouse NFPM raw source views from a mounted parquet dataset."
    )
    parser.add_argument(
        "--dataset",
        default=os.getenv("LOCAL_NFPM_DATASET_RELATIVE_PATH", DEFAULT_NFPM_DATASET_RELATIVE_PATH),
        help="Relative NFPM dataset path under LOCAL_DATALAKE_ROOT.",
    )
    parser.add_argument(
        "--data-root",
        default=os.getenv("LOCAL_DATALAKE_ROOT", DEFAULT_DATA_ROOT),
        help="Host datalake root that is mounted into clickhouse_local.",
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

    required_dirs = {"Transfer", "IncreaseLiquidity", "DecreaseLiquidity", "Collect"}
    missing = sorted(name for name in required_dirs if not (dataset_dir / name).is_dir())
    if missing:
        raise FileNotFoundError(
            f"Dataset is missing required event directories: {', '.join(missing)}"
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


def main() -> None:
    args = parse_args()
    dataset_dir = Path(args.data_root).expanduser() / args.dataset
    ensure_dataset_layout(dataset_dir)

    print("Bootstrapping local ClickHouse NFPM sources")
    print(f"  host dataset root: {Path(args.data_root).expanduser()}")
    print(f"  dataset:           {args.dataset}")
    print(f"  clickhouse:        {args.clickhouse_host}:{args.clickhouse_port}/{args.clickhouse_db}")

    client = get_clickhouse_client(args)
    recreate_views(client, args.dataset)
    print("  local views:       recreated uniswap_nfpm_{transfer,increase_liquidity,decrease_liquidity,collect}")

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

