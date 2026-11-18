"""
Fetch Uniswap V3 pool metadata from a pool address and write to ClickHouse.
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from clickhouse_driver import Client
from dotenv import load_dotenv
from web3 import Web3

load_dotenv()

# ── Config ────────────────────────────────────────────────────────────────────

ABIS_DIR        = Path(__file__).resolve().parent.parent / "abis"
FACTORY_ADDRESS = Web3.to_checksum_address("0x1F98431c8aD98523631AE4a59f267346ea31F984")
FACTORY_BLOCK   = 12_369_621  # Uniswap V3 factory deployment block
DEFAULT_POOL    = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"


def load_abi(name: str) -> list:
    return json.loads((ABIS_DIR / f"{name}.json").read_text())


# ── Blockchain calls ──────────────────────────────────────────────────────────

def get_deployment_block(w3: Web3, pool_address: str) -> int:
    """
    Binary search for the first block where the pool contract exists.
    O(log n) eth_getCode calls — no event scanning.
    """
    lo = FACTORY_BLOCK
    hi = w3.eth.block_number

    while lo < hi:
        mid  = (lo + hi) // 2
        code = w3.eth.get_code(Web3.to_checksum_address(pool_address), mid)
        if code:
            hi = mid
        else:
            lo = mid + 1

    return lo


def get_pool_info(w3: Web3, pool_address: str) -> dict:
    pool    = w3.eth.contract(address=Web3.to_checksum_address(pool_address), abi=load_abi("pool"))
    factory = w3.eth.contract(address=FACTORY_ADDRESS, abi=load_abi("factory"))

    token0_addr = pool.functions.token0().call()
    token1_addr = pool.functions.token1().call()
    fee          = pool.functions.fee().call()
    tick_spacing = pool.functions.tickSpacing().call()

    token0 = w3.eth.contract(address=token0_addr, abi=load_abi("erc20"))
    token1 = w3.eth.contract(address=token1_addr, abi=load_abi("erc20"))

    # Verify pool exists in factory
    factory_pool = factory.functions.getPool(token0_addr, token1_addr, fee).call()
    assert Web3.to_checksum_address(factory_pool) == Web3.to_checksum_address(pool_address), \
        "Pool not found in factory"

    deployment_block = get_deployment_block(w3, pool_address)
    block            = w3.eth.get_block(deployment_block)
    deployment_ts    = datetime.fromtimestamp(block["timestamp"], tz=timezone.utc)

    return {
        "pool":             pool_address,
        "fee_bps":          fee / 10_000,
        "token0_address":   token0_addr,
        "token0_symbol":    token0.functions.symbol().call(),
        "token0_decimals":  token0.functions.decimals().call(),
        "token1_address":   token1_addr,
        "token1_symbol":    token1.functions.symbol().call(),
        "token1_decimals":  token1.functions.decimals().call(),
        "tick_spacing":     tick_spacing,
        "deployment_block": deployment_block,
        "deployment_ts":    deployment_ts,
    }


# ── ClickHouse ────────────────────────────────────────────────────────────────

def get_clickhouse_client() -> Client:
    return Client(
        host=os.getenv("CLICKHOUSE_HOST", "localhost"),
        port=int(os.getenv("CLICKHOUSE_PORT", 9000)),
        user=os.getenv("CLICKHOUSE_USER", "default"),
        password=os.getenv("CLICKHOUSE_PASSWORD", ""),
        database=os.getenv("CLICKHOUSE_DB", "analytics"),
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch Uniswap V3 pool metadata from RPC and write it to ClickHouse."
    )
    parser.add_argument(
        "--pool-address",
        default=os.getenv("POOL_ADDRESS", DEFAULT_POOL),
        help="Pool address to fetch. Defaults to POOL_ADDRESS env var.",
    )
    parser.add_argument(
        "--eth-rpc-url",
        default=os.getenv("ETH_RPC_URL"),
        help="Ethereum RPC URL. Defaults to ETH_RPC_URL env var.",
    )
    return parser.parse_args()


def write_to_clickhouse(info: dict) -> None:
    client = get_clickhouse_client()

    client.execute("""
        CREATE TABLE IF NOT EXISTS pools
        (
            pool             String,
            fee_bps          Float32,
            token0_address   String,
            token0_symbol    String,
            token0_decimals  UInt8,
            token1_address   String,
            token1_symbol    String,
            token1_decimals  UInt8,
            tick_spacing     Int32,
            deployment_block UInt64,
            deployment_ts    DateTime('UTC')
        )
        ENGINE = MergeTree()
        ORDER BY pool
    """)

    existing_rows = client.execute(
        "SELECT count() FROM pools WHERE pool = %(pool)s",
        {"pool": info["pool"]},
    )[0][0]

    if existing_rows:
        print("→ Pool metadata already exists in ClickHouse table `pools`, skipping insert")
        return

    client.execute("INSERT INTO pools VALUES", [info])
    print("→ Written to ClickHouse table `pools`")


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    args = parse_args()
    POOL = Web3.to_checksum_address(args.pool_address)

    w3 = Web3(Web3.HTTPProvider(args.eth_rpc_url))
    assert w3.is_connected(), "Cannot connect to RPC"

    print(f"Fetching pool info for {POOL}...")
    info = get_pool_info(w3, POOL)

    print(f"\nPool:             {info['pool']}")
    print(f"Fee:              {info['fee_bps']}%")
    print(f"Token0:           {info['token0_symbol']} ({info['token0_decimals']} decimals) — {info['token0_address']}")
    print(f"Token1:           {info['token1_symbol']} ({info['token1_decimals']} decimals) — {info['token1_address']}")
    print(f"Tick spacing:     {info['tick_spacing']}")
    print(f"Deployment block: {info['deployment_block']}")
    print(f"Deployment date:  {info['deployment_ts']}")

    write_to_clickhouse(info)
