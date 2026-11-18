from __future__ import annotations

from datetime import datetime

import polars as pl

from engines.backtest_engine import (
    build_backtest_entry_liquidity,
    build_backtest_summary,
    build_backtest_swap_path,
)


def test_build_backtest_entry_liquidity_below_range_starts_all_in_token0() -> None:
    entry_state = pl.DataFrame(
        {
            "scenario_id": ["scenario_1"],
            "pool": ["0xpool1"],
            "start_block": [10],
            "end_block": [20],
            "tick_lower": [10],
            "tick_upper": [20],
            "capital_committed_token0": [100.0],
            "rebalance_strategy": ["none"],
            "grain": ["daily"],
            "tick_spacing": [1],
            "token0_decimals": [0],
            "token1_decimals": [0],
            "start_snapshot_block_number": [10],
            "start_snapshot_log_index": [0],
            "start_snapshot_block_time": [datetime(2024, 1, 1, 0, 0, 0)],
            "start_tick": [0],
            "start_price": [1.0],
            "start_sqrt_price": [1.0],
        }
    )

    result = build_backtest_entry_liquidity(entry_state)

    assert result.height == 1
    assert result["start_position_status"].to_list() == ["below_range"]
    assert result["initial_amount0"].to_list() == [100.0]
    assert result["initial_amount1"].to_list() == [0.0]
    assert result["initial_principal_value_token0"].to_list() == [100.0]


def test_build_backtest_swap_path_accrues_fees_only_when_active() -> None:
    entry_liquidity = pl.DataFrame(
        {
            "scenario_id": ["scenario_1"],
            "pool": ["0xpool1"],
            "start_block": [10],
            "end_block": [20],
            "tick_lower": [90],
            "tick_upper": [110],
            "initial_liquidity": [10.0],
        }
    )
    swaps = pl.DataFrame(
        {
            "pool": ["0xpool1", "0xpool1"],
            "block_number": [11, 12],
            "log_index": [0, 0],
            "block_time": [datetime(2024, 1, 1, 12, 0, 0), datetime(2024, 1, 1, 13, 0, 0)],
            "tick_before": [100, 120],
            "price_before": [2000.0, 2001.0],
            "tick_after": [101, 119],
            "price_after": [2001.0, 1999.0],
            "active_liquidity_at_swap": [100.0, 100.0],
            "fees_generated_token0": [20.0, 30.0],
            "fees_generated_token1": [0.0, 0.0],
            "fees_generated_token0_equiv": [20.0, 30.0],
        }
    )

    result = build_backtest_swap_path(entry_liquidity, swaps).sort(["block_number", "log_index"])

    assert result.height == 2
    assert result["is_active_before_swap"].to_list() == [1, 0]
    assert result["position_fee_share"].to_list() == [0.1, None]
    assert result["fees_accrued_token0"].to_list() == [2.0, 0.0]
    assert result["fees_accrued_token0_equiv_generated"].to_list() == [2.0, 0.0]


def test_build_backtest_summary_decomposes_lp_vs_hodl_and_fees() -> None:
    entry_liquidity = pl.DataFrame(
        {
            "scenario_id": ["scenario_1"],
            "pool": ["0xpool1"],
            "start_block": [10],
            "end_block": [20],
            "tick_lower": [90],
            "tick_upper": [110],
            "capital_committed_token0": [100.0],
            "rebalance_strategy": ["none"],
            "tick_spacing": [10],
            "token0_decimals": [6],
            "token1_decimals": [18],
            "start_snapshot_block_number": [10],
            "start_snapshot_log_index": [0],
            "start_snapshot_block_time": [datetime(2024, 1, 1, 0, 0, 0)],
            "start_tick": [100],
            "start_price": [2000.0],
            "start_sqrt_price": [1.0],
            "start_position_status": ["in_range"],
            "unit_amount0": [1.0],
            "unit_amount1": [0.0],
            "unit_position_value_token0": [1.0],
            "initial_liquidity": [10.0],
            "initial_amount0": [40.0],
            "initial_amount1": [0.03],
            "initial_principal_value_token0": [100.0],
        }
    )
    exit_state = pl.DataFrame(
        {
            "scenario_id": ["scenario_1"],
            "end_snapshot_block_number": [20],
            "end_snapshot_log_index": [1],
            "end_snapshot_block_time": [datetime(2024, 1, 2, 0, 0, 0)],
            "end_tick": [101],
            "end_price": [2000.0],
            "end_sqrt_price": [1.0],
            "end_position_status": ["in_range"],
            "end_amount0": [30.0],
            "end_amount1": [0.03],
            "end_principal_value_token0": [90.0],
        }
    )
    swap_path = pl.DataFrame(
        {
            "scenario_id": ["scenario_1", "scenario_1"],
            "is_active_before_swap": [1, 0],
            "fees_accrued_token0": [2.0, 0.0],
            "fees_accrued_token1": [0.0, 0.0],
            "fees_accrued_token0_equiv_generated": [2.0, 0.0],
        }
    )
    tir_summary = pl.DataFrame(
        {
            "scenario_id": ["scenario_1"],
            "pool": ["0xpool1"],
            "start_block": [10],
            "end_block": [20],
            "resolved_start_time": [datetime(2024, 1, 1, 0, 0, 0)],
            "resolved_end_time": [datetime(2024, 1, 2, 0, 0, 0)],
            "observed_time_in_range_seconds": [600],
            "observed_window_seconds": [1000],
            "observed_out_of_range_seconds": [400],
            "observed_time_in_range_pct": [0.6],
            "observed_out_of_range_pct": [0.4],
        }
    )

    result = build_backtest_summary(entry_liquidity, exit_state, swap_path, tir_summary)

    assert result.height == 1
    row = result.to_dicts()[0]
    assert row["swap_count_in_window"] == 2
    assert row["swap_count_while_active"] == 1
    assert row["fees_accrued_token0_equiv_generated"] == 2.0
    assert row["observed_time_in_range_seconds"] == 600
    assert row["observed_time_in_range_pct"] == 0.6
    assert row["hodl_end_value_token0"] == 100.0
    assert row["lp_end_value_including_fees_token0"] == 92.0
    assert row["impermanent_loss_token0"] == -10.0
    assert row["pnl_vs_initial_token0"] == -8.0
    assert row["pnl_vs_hodl_token0"] == -8.0
