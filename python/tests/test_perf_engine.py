from __future__ import annotations

from datetime import datetime

import polars as pl

from engines.perf_engine import build_position_performance_daily


def test_build_position_performance_daily_basic_path() -> None:
    positions = pl.DataFrame(
        {
            "token_id": [1],
            "pool": ["pool-a"],
            "tick_lower": [195_600],
            "tick_upper": [197_400],
            "mint_block_time": [datetime(2026, 4, 1, 10, 0, 0)],
            "token0_decimals": [6],
            "token1_decimals": [18],
        }
    )
    daily_close = pl.DataFrame(
        {
            "pool": ["pool-a", "pool-a"],
            "date": [datetime(2026, 4, 1).date(), datetime(2026, 4, 2).date()],
            "close_tick": [196_500, 196_700],
            "close_price": [2050.0, 2100.0],
            "close_sqrt_price": [0.0, 0.0],
        }
    )
    active_liquidity = pl.DataFrame(
        {
            "pool": ["pool-a", "pool-a"],
            "date": [datetime(2026, 4, 1).date(), datetime(2026, 4, 2).date()],
            "active_liquidity": [10_000_000_000_000.0, 10_000_000_000_000.0],
        }
    )
    increase_lots = pl.DataFrame(
        {
            "token_id": [1],
            "lot_seq": [1],
            "lot_block_time": [datetime(2026, 4, 1, 10, 0, 0)],
            "lot_amount0": [1000.0],
            "lot_amount1": [0.5],
            "entry_price_token1_in_token0": [2000.0],
        }
    )
    liquidity_events = pl.DataFrame(
        {
            "token_id": [1],
            "block_time": [datetime(2026, 4, 1, 10, 0, 0)],
            "log_index": [1],
            "event_type": ["IncreaseLiquidity"],
            "liquidity_delta_raw": [5_000_000_000_000.0],
            "amount0": [1000.0],
            "amount1": [0.5],
        }
    )
    collects = pl.DataFrame(
        {
            "token_id": [1],
            "block_time": [datetime(2026, 4, 2, 12, 0, 0)],
            "principal_collected_amount0": [0.0],
            "principal_collected_amount1": [0.0],
            "fees_collected_amount0": [2.0],
            "fees_collected_amount1": [0.001],
        }
    )
    time_in_range = pl.DataFrame(
        {
            "token_id": [1, 1],
            "date": [datetime(2026, 4, 1).date(), datetime(2026, 4, 2).date()],
            "observed_time_in_range_pct": [1.0, 0.5],
        }
    )
    fee_accruals = pl.DataFrame(
        {
            "token_id": [1, 1],
            "date": [datetime(2026, 4, 1).date(), datetime(2026, 4, 2).date()],
            "total_fees_accrued_amount0": [1.0, 1.5],
            "total_fees_accrued_amount1": [0.0005, 0.00075],
            "total_fees_accrued_token0_equiv_generated": [2.0, 3.0],
        }
    )
    lvr_daily = pl.DataFrame(
        {
            "pool": ["pool-a", "pool-a"],
            "date": [datetime(2026, 4, 1).date(), datetime(2026, 4, 2).date()],
            "lvr_total": [0.2, 0.3],
        }
    )

    result = build_position_performance_daily(
        positions=positions,
        daily_close=daily_close,
        active_liquidity=active_liquidity,
        increase_lots=increase_lots,
        liquidity_events=liquidity_events,
        collects=collects,
        time_in_range=time_in_range,
        fee_accruals=fee_accruals,
        lvr_daily=lvr_daily,
    )

    assert result.height == 2
    assert result["token_id"].to_list() == [1, 1]
    assert result["L_effective"].to_list() == [5_000_000_000_000.0, 5_000_000_000_000.0]
    assert result["share_of_pool"].to_list() == [0.5, 0.5]
    assert result["position_value"][0] > 0
    assert result["hodl_value"][1] < result["hodl_value"][0]
    assert result["fees_collected_value"][0] == 0.0
    assert result["fees_collected_value"][1] > 0.0
    assert result["principal_wealth"][1] >= result["position_value"][1]
    assert result["total_wealth"][1] >= result["principal_wealth"][1]
    assert result["lvr_cumulative"].to_list() == [0.1, 0.175]
    assert result["is_in_range"].to_list() == [True, True]


def test_build_position_performance_daily_clamps_negative_liquidity_to_zero() -> None:
    positions = pl.DataFrame(
        {
            "token_id": [1],
            "pool": ["pool-a"],
            "tick_lower": [195_600],
            "tick_upper": [197_400],
            "mint_block_time": [datetime(2026, 4, 1, 10, 0, 0)],
            "token0_decimals": [6],
            "token1_decimals": [18],
        }
    )
    daily_close = pl.DataFrame(
        {
            "pool": ["pool-a"],
            "date": [datetime(2026, 4, 1).date()],
            "close_tick": [196_500],
            "close_price": [2050.0],
            "close_sqrt_price": [0.0],
        }
    )
    active_liquidity = pl.DataFrame(
        {
            "pool": ["pool-a"],
            "date": [datetime(2026, 4, 1).date()],
            "active_liquidity": [10_000_000_000_000.0],
        }
    )
    increase_lots = pl.DataFrame(
        {
            "token_id": [1],
            "lot_seq": [1],
            "lot_block_time": [datetime(2026, 4, 1, 10, 0, 0)],
            "lot_amount0": [1000.0],
            "lot_amount1": [0.5],
            "entry_price_token1_in_token0": [2000.0],
        }
    )
    liquidity_events = pl.DataFrame(
        {
            "token_id": [1],
            "block_time": [datetime(2026, 4, 1, 10, 0, 0)],
            "log_index": [1],
            "event_type": ["DecreaseLiquidity"],
            "liquidity_delta_raw": [-2.0],
            "amount0": [-100.0],
            "amount1": [-0.05],
        }
    )

    result = build_position_performance_daily(
        positions=positions,
        daily_close=daily_close,
        active_liquidity=active_liquidity,
        increase_lots=increase_lots,
        liquidity_events=liquidity_events,
        collects=pl.DataFrame(
            {
                "token_id": [],
                "block_time": [],
                "principal_collected_amount0": [],
                "principal_collected_amount1": [],
                "fees_collected_amount0": [],
                "fees_collected_amount1": [],
            }
        ),
        time_in_range=pl.DataFrame(
            {"token_id": [], "date": [], "observed_time_in_range_pct": []}
        ),
        fee_accruals=pl.DataFrame(
            {
                "token_id": [],
                "date": [],
                "total_fees_accrued_amount0": [],
                "total_fees_accrued_amount1": [],
                "total_fees_accrued_token0_equiv_generated": [],
            }
        ),
    )

    assert result.height == 1
    assert result["L_effective"].to_list() == [0.0]
