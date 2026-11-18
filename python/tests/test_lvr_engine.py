from __future__ import annotations

from datetime import datetime

import polars as pl

from engines.lvr_engine import build_lvr_daily, build_lvr_per_swap


def test_build_lvr_per_swap_computes_positive_lvr_and_fee_amount() -> None:
    swaps = pl.DataFrame(
        {
            "pool": ["pool-a", "pool-a"],
            "tx_hash": ["0x1", "0x2"],
            "log_index": [1, 2],
            "block_number": [100, 101],
            "block_time": [datetime(2026, 4, 1, 10, 0, 0), datetime(2026, 4, 1, 11, 0, 0)],
            "tick_before": [196_500, 196_501],
            "tick_after": [196_501, 196_503],
            "price_before": [2045.0, 2050.0],
            "liquidity_active": [1_000_000.0, 2_000_000.0],
            "price_after": [2050.0, 2055.0],
            "fee_amount_token0": [5.0, 8.0],
            "token0_decimals": [6, 6],
            "token1_decimals": [18, 18],
        }
    )

    result = build_lvr_per_swap(swaps)

    expected_first_lvr = (
        (1_000_000.0 / (10 ** ((6 + 18) / 2)))
        * (2050.0 ** 0.5 - 2045.0 ** 0.5) ** 2
        / 2.0
    )

    assert result.height == 2
    assert result["tx_hash"].to_list() == ["0x1", "0x2"]
    assert result["lvr"][0] == expected_first_lvr
    assert result["lvr"].min() > 0
    assert result["fee_amount"][0] == 5.0


def test_build_lvr_daily_aggregates_ratio() -> None:
    per_swap = pl.DataFrame(
        {
            "pool": ["pool-a", "pool-a", "pool-a"],
            "tx_hash": ["0x1", "0x2", "0x3"],
            "log_index": [1, 2, 3],
            "block_number": [100, 101, 102],
            "block_time": [
                datetime(2026, 4, 1, 10, 0, 0),
                datetime(2026, 4, 1, 11, 0, 0),
                datetime(2026, 4, 2, 12, 0, 0),
            ],
            "sqrt_price_before": [1.0, 1.0, 1.0],
            "sqrt_price_after": [1.001, 1.002, 1.0015],
            "liquidity_active": [100.0, 200.0, 300.0],
            "lvr": [0.2, 0.3, 0.4],
            "fee_amount": [0.4, 0.3, 0.2],
        }
    )

    result = build_lvr_daily(per_swap)

    assert result.height == 2
    assert result["day"].to_list() == [datetime(2026, 4, 1).date(), datetime(2026, 4, 2).date()]
    assert result["lvr_total"].to_list() == [0.5, 0.4]
    assert result["fees_total"].to_list() == [0.7, 0.2]
    assert result["fee_lvr_ratio"].to_list() == [1.4, 0.5]
    assert result["swap_count"].to_list() == [2, 1]
