"""Parametric backtest engine for hypothetical LP positions."""

from __future__ import annotations

from dataclasses import asdict
from datetime import date, datetime, time, timedelta

import polars as pl

from core.db import ClickHouseDB
from core.position_math import (
    amount0_from_liquidity,
    amount1_from_liquidity,
    is_in_range,
    sqrt_price_from_human_price,
    tick_to_sqrt_price,
)
from core.types import BacktestParams


def _ensure_schema(df: pl.DataFrame, schema: dict[str, pl.DataType]) -> pl.DataFrame:
    if df.columns:
        return df
    return pl.DataFrame(schema=schema)


def _position_status_from_tick(tick: int, tick_lower: int, tick_upper: int) -> str:
    if tick < tick_lower:
        return "below_range"
    if tick >= tick_upper:
        return "above_range"
    return "in_range"


def _default_scenario_id(
    pool: str,
    start_block: int,
    end_block: int,
    tick_lower: int,
    tick_upper: int,
    capital_committed_token0: float,
) -> str:
    return (
        f"{pool.lower()}__{start_block}__{end_block}__{tick_lower}__"
        f"{tick_upper}__{capital_committed_token0}"
    )


def normalize_scenarios(
    scenarios: list[BacktestParams | dict[str, object]],
) -> list[BacktestParams]:
    normalized: list[BacktestParams] = []
    seen: set[str] = set()
    for scenario in scenarios:
        if isinstance(scenario, BacktestParams):
            item = scenario
        else:
            pool = str(scenario["pool"]).lower()
            start_block = int(scenario["start_block"])
            end_block = int(scenario["end_block"])
            tick_lower = int(scenario["tick_lower"])
            tick_upper = int(scenario["tick_upper"])
            capital = float(scenario["capital_committed_token0"])
            scenario_id = str(
                scenario.get(
                    "scenario_id",
                    _default_scenario_id(
                        pool,
                        start_block,
                        end_block,
                        tick_lower,
                        tick_upper,
                        capital,
                    ),
                )
            )
            item = BacktestParams(
                scenario_id=scenario_id,
                pool=pool,
                start_block=start_block,
                end_block=end_block,
                tick_lower=tick_lower,
                tick_upper=tick_upper,
                capital_committed_token0=capital,
                rebalance_strategy=str(scenario.get("rebalance_strategy", "none")),
                grain=str(scenario.get("grain", "daily")),
            )
        if item.end_block < item.start_block:
            raise ValueError(f"{item.scenario_id}: end_block < start_block")
        if item.tick_lower >= item.tick_upper:
            raise ValueError(f"{item.scenario_id}: tick_lower >= tick_upper")
        if item.capital_committed_token0 <= 0:
            raise ValueError(f"{item.scenario_id}: capital_committed_token0 must be > 0")
        if item.rebalance_strategy not in {None, "none"}:
            raise ValueError(
                f"{item.scenario_id}: only rebalance_strategy=None/'none' is supported"
            )
        if item.scenario_id in seen:
            raise ValueError(f"duplicate scenario_id: {item.scenario_id}")
        seen.add(item.scenario_id)
        normalized.append(item)
    return normalized


def scenarios_to_frame(scenarios: list[BacktestParams]) -> pl.DataFrame:
    return pl.DataFrame([asdict(scenario) for scenario in scenarios]).with_columns(
        pl.col("pool").str.to_lowercase(),
        pl.col("scenario_id").cast(pl.String),
        pl.col("start_block").cast(pl.UInt64),
        pl.col("end_block").cast(pl.UInt64),
        pl.col("tick_lower").cast(pl.Int32),
        pl.col("tick_upper").cast(pl.Int32),
        pl.col("capital_committed_token0").cast(pl.Float64),
        pl.col("rebalance_strategy").cast(pl.String),
        pl.col("grain").cast(pl.String),
    )


def build_backtest_entry_liquidity(
    entry_states: pl.DataFrame,
) -> pl.DataFrame:
    records: list[dict[str, object]] = []
    for row in entry_states.to_dicts():
        start_price = float(row["start_price"])
        token0_decimals = int(row["token0_decimals"])
        token1_decimals = int(row["token1_decimals"])
        tick_lower = int(row["tick_lower"])
        tick_upper = int(row["tick_upper"])
        sqrt_start = float(row["start_sqrt_price"])
        sqrt_pa = float(tick_to_sqrt_price(tick_lower))
        sqrt_pb = float(tick_to_sqrt_price(tick_upper))
        sqrt_clamped = min(max(sqrt_start, sqrt_pa), sqrt_pb)
        unit_amount0 = float(amount0_from_liquidity(1.0, sqrt_clamped, sqrt_pb, token0_decimals))
        unit_amount1 = float(amount1_from_liquidity(1.0, sqrt_clamped, sqrt_pa, token1_decimals))
        unit_value_token0 = unit_amount0 + unit_amount1 * start_price
        initial_liquidity = (
            float(row["capital_committed_token0"]) / unit_value_token0
            if unit_value_token0 > 0
            else None
        )
        initial_amount0 = initial_liquidity * unit_amount0 if initial_liquidity is not None else None
        initial_amount1 = initial_liquidity * unit_amount1 if initial_liquidity is not None else None
        initial_principal_value_token0 = (
            initial_amount0 + initial_amount1 * start_price
            if initial_amount0 is not None and initial_amount1 is not None
            else None
        )
        records.append(
            {
                **row,
                "start_position_status": _position_status_from_tick(
                    int(row["start_tick"]), tick_lower, tick_upper
                ),
                "unit_amount0": unit_amount0,
                "unit_amount1": unit_amount1,
                "unit_position_value_token0": unit_value_token0,
                "initial_liquidity": initial_liquidity,
                "initial_amount0": initial_amount0,
                "initial_amount1": initial_amount1,
                "initial_principal_value_token0": initial_principal_value_token0,
            }
        )
    return pl.DataFrame(records, infer_schema_length=len(records)) if records else pl.DataFrame()


def build_backtest_swap_path(
    entry_liquidity: pl.DataFrame,
    swaps: pl.DataFrame,
) -> pl.DataFrame:
    if entry_liquidity.is_empty():
        return pl.DataFrame()
    records: list[dict[str, object]] = []
    for scenario in entry_liquidity.to_dicts():
        pool_swaps = swaps.filter(pl.col("pool") == str(scenario["pool"]).lower()).sort(
            ["block_number", "log_index"]
        )
        if pool_swaps.is_empty():
            continue
        path = pool_swaps.filter(
            (pl.col("block_number") > int(scenario["start_block"]))
            & (pl.col("block_number") <= int(scenario["end_block"]))
        )
        for swap in path.to_dicts():
            tick_before = swap.get("tick_before")
            active_before = (
                tick_before is not None
                and is_in_range(
                    int(tick_before),
                    int(scenario["tick_lower"]),
                    int(scenario["tick_upper"]),
                )
            )
            active_liquidity_at_swap = float(swap["active_liquidity_at_swap"] or 0.0)
            position_fee_share = (
                float(scenario["initial_liquidity"]) / active_liquidity_at_swap
                if active_before and active_liquidity_at_swap > 0
                else None
            )
            records.append(
                {
                    "scenario_id": scenario["scenario_id"],
                    "pool": scenario["pool"],
                    "start_block": scenario["start_block"],
                    "end_block": scenario["end_block"],
                    "tick_lower": scenario["tick_lower"],
                    "tick_upper": scenario["tick_upper"],
                    "block_number": swap["block_number"],
                    "log_index": swap["log_index"],
                    "block_time": swap["block_time"],
                    "tick_before": tick_before,
                    "price_before": swap.get("price_before"),
                    "tick_after": swap.get("tick_after"),
                    "price_after": swap.get("price_after"),
                    "active_liquidity_at_swap": active_liquidity_at_swap,
                    "fees_generated_token0": float(swap.get("fees_generated_token0") or 0.0),
                    "fees_generated_token1": float(swap.get("fees_generated_token1") or 0.0),
                    "fees_generated_token0_equiv": float(
                        swap.get("fees_generated_token0_equiv") or 0.0
                    ),
                    "initial_liquidity": float(scenario["initial_liquidity"]),
                    "is_active_before_swap": 1 if active_before else 0,
                    "position_fee_share": position_fee_share,
                    "fees_accrued_token0": (
                        float(swap.get("fees_generated_token0") or 0.0) * position_fee_share
                        if position_fee_share is not None
                        else 0.0
                    ),
                    "fees_accrued_token1": (
                        float(swap.get("fees_generated_token1") or 0.0) * position_fee_share
                        if position_fee_share is not None
                        else 0.0
                    ),
                    "fees_accrued_token0_equiv_generated": (
                        float(swap.get("fees_generated_token0_equiv") or 0.0) * position_fee_share
                        if position_fee_share is not None
                        else 0.0
                    ),
                }
            )
    return pl.DataFrame(records, infer_schema_length=len(records)) if records else pl.DataFrame()


def _split_interval_by_day(start_time: datetime, end_time: datetime) -> list[tuple[date, int]]:
    if end_time <= start_time:
        return []
    chunks: list[tuple[date, int]] = []
    cursor = start_time
    while cursor < end_time:
        next_midnight = datetime.combine(cursor.date() + timedelta(days=1), time.min)
        chunk_end = min(end_time, next_midnight)
        seconds = int((chunk_end - cursor).total_seconds())
        if seconds > 0:
            chunks.append((cursor.date(), seconds))
        cursor = chunk_end
    return chunks


def build_backtest_time_in_range(
    entry_liquidity: pl.DataFrame,
    exit_state: pl.DataFrame,
    swaps: pl.DataFrame,
) -> tuple[pl.DataFrame, pl.DataFrame]:
    if entry_liquidity.is_empty() or exit_state.is_empty():
        return pl.DataFrame(), pl.DataFrame()
    summary_records: list[dict[str, object]] = []
    daily_records: list[dict[str, object]] = []
    exit_by_scenario = {row["scenario_id"]: row for row in exit_state.to_dicts()}
    for scenario in entry_liquidity.to_dicts():
        exit_row = exit_by_scenario.get(str(scenario["scenario_id"]))
        if exit_row is None:
            continue
        start_time = scenario.get("start_snapshot_block_time")
        end_time = exit_row.get("end_snapshot_block_time")
        if start_time is None or end_time is None:
            continue
        pool_swaps = swaps.filter(pl.col("pool") == str(scenario["pool"]).lower()).sort(
            ["block_number", "log_index"]
        )
        in_range_seconds = 0
        total_seconds = 0
        day_buckets: dict[date, dict[str, int]] = {}
        if not pool_swaps.is_empty():
            overlaps = pool_swaps.filter(
                (pl.col("block_time") < end_time)
                & (
                    pl.col("next_block_time").fill_null(end_time)
                    > start_time
                )
            )
            for swap in overlaps.to_dicts():
                interval_start = max(swap["block_time"], start_time)
                next_time = swap["next_block_time"] or end_time
                interval_end = min(next_time, end_time)
                if interval_end <= interval_start:
                    continue
                active_after = (
                    swap.get("tick_after") is not None
                    and is_in_range(
                        int(swap["tick_after"]),
                        int(scenario["tick_lower"]),
                        int(scenario["tick_upper"]),
                    )
                )
                chunks = _split_interval_by_day(interval_start, interval_end)
                for day_value, seconds in chunks:
                    bucket = day_buckets.setdefault(
                        day_value,
                        {"observed_window_seconds": 0, "observed_time_in_range_seconds": 0},
                    )
                    bucket["observed_window_seconds"] += seconds
                    if active_after:
                        bucket["observed_time_in_range_seconds"] += seconds
                total_seconds += int((interval_end - interval_start).total_seconds())
                if active_after:
                    in_range_seconds += int((interval_end - interval_start).total_seconds())
        summary_records.append(
            {
                "scenario_id": scenario["scenario_id"],
                "pool": scenario["pool"],
                "start_block": scenario["start_block"],
                "end_block": scenario["end_block"],
                "resolved_start_time": start_time,
                "resolved_end_time": end_time,
                "observed_time_in_range_seconds": in_range_seconds,
                "observed_window_seconds": total_seconds,
                "observed_out_of_range_seconds": total_seconds - in_range_seconds,
                "observed_time_in_range_pct": (
                    in_range_seconds / total_seconds if total_seconds > 0 else None
                ),
                "observed_out_of_range_pct": (
                    (total_seconds - in_range_seconds) / total_seconds
                    if total_seconds > 0
                    else None
                ),
            }
        )
        for day_value, bucket in sorted(day_buckets.items()):
            window_seconds = bucket["observed_window_seconds"]
            range_seconds = bucket["observed_time_in_range_seconds"]
            daily_records.append(
                {
                    "scenario_id": scenario["scenario_id"],
                    "day": day_value,
                    "observed_time_in_range_seconds": range_seconds,
                    "observed_window_seconds": window_seconds,
                    "observed_out_of_range_seconds": window_seconds - range_seconds,
                    "time_in_range_pct": range_seconds / window_seconds if window_seconds > 0 else None,
                }
            )
    return (
        pl.DataFrame(summary_records, infer_schema_length=len(summary_records)) if summary_records else pl.DataFrame(),
        pl.DataFrame(daily_records, infer_schema_length=len(daily_records)) if daily_records else pl.DataFrame(),
    )


def build_backtest_exit_state(
    entry_liquidity: pl.DataFrame,
    swaps: pl.DataFrame,
) -> pl.DataFrame:
    if entry_liquidity.is_empty():
        return pl.DataFrame()
    records: list[dict[str, object]] = []
    for scenario in entry_liquidity.to_dicts():
        pool_swaps = swaps.filter(pl.col("pool") == str(scenario["pool"]).lower()).sort(
            ["block_number", "log_index"]
        )
        relevant = pool_swaps.filter(pl.col("block_number") <= int(scenario["end_block"]))
        if relevant.is_empty():
            continue
        end_swap = relevant.tail(1).to_dicts()[0]
        end_price = float(end_swap["price_after"])
        token0_decimals = int(scenario["token0_decimals"])
        token1_decimals = int(scenario["token1_decimals"])
        sqrt_end = float(
            sqrt_price_from_human_price(end_price, token0_decimals, token1_decimals)
        )
        sqrt_pa = float(tick_to_sqrt_price(int(scenario["tick_lower"])))
        sqrt_pb = float(tick_to_sqrt_price(int(scenario["tick_upper"])))
        sqrt_clamped = min(max(sqrt_end, sqrt_pa), sqrt_pb)
        end_amount0 = float(
            amount0_from_liquidity(
                float(scenario["initial_liquidity"]),
                sqrt_clamped,
                sqrt_pb,
                token0_decimals,
            )
        )
        end_amount1 = float(
            amount1_from_liquidity(
                float(scenario["initial_liquidity"]),
                sqrt_clamped,
                sqrt_pa,
                token1_decimals,
            )
        )
        records.append(
            {
                **scenario,
                "end_snapshot_block_number": end_swap["block_number"],
                "end_snapshot_log_index": end_swap["log_index"],
                "end_snapshot_block_time": end_swap["block_time"],
                "end_tick": int(end_swap["tick_after"]),
                "end_price": end_price,
                "end_sqrt_price": sqrt_end,
                "end_position_status": _position_status_from_tick(
                    int(end_swap["tick_after"]),
                    int(scenario["tick_lower"]),
                    int(scenario["tick_upper"]),
                ),
                "end_amount0": end_amount0,
                "end_amount1": end_amount1,
                "end_principal_value_token0": end_amount0 + end_amount1 * end_price,
            }
        )
    return pl.DataFrame(records, infer_schema_length=len(records)) if records else pl.DataFrame()


def build_backtest_daily_results(
    entry_liquidity: pl.DataFrame,
    daily_close: pl.DataFrame,
    active_liquidity: pl.DataFrame,
    swap_path: pl.DataFrame,
    time_in_range_daily: pl.DataFrame,
) -> pl.DataFrame:
    if entry_liquidity.is_empty():
        return pl.DataFrame()
    fee_daily = (
        swap_path.with_columns(pl.col("block_time").dt.date().alias("day"))
        .group_by(["scenario_id", "day"])
        .agg(
            pl.col("fees_accrued_token0").sum().alias("fees_accrued_token0_day"),
            pl.col("fees_accrued_token1").sum().alias("fees_accrued_token1_day"),
            pl.col("fees_accrued_token0_equiv_generated").sum().alias(
                "fees_accrued_token0_equiv_day"
            ),
            pl.len().alias("swap_count_day"),
        )
        if not swap_path.is_empty()
        else pl.DataFrame(
            schema={
                "scenario_id": pl.String,
                "day": pl.Date,
                "fees_accrued_token0_day": pl.Float64,
                "fees_accrued_token1_day": pl.Float64,
                "fees_accrued_token0_equiv_day": pl.Float64,
                "swap_count_day": pl.UInt32,
            }
        )
    )
    closes_by_pool = {key[0] if isinstance(key, tuple) else key: frame.sort("date") for key, frame in daily_close.group_by("pool")}
    liq_by_pool = {key[0] if isinstance(key, tuple) else key: frame.sort("date") for key, frame in active_liquidity.group_by("pool")}
    tir_by_scenario = (
        {key[0] if isinstance(key, tuple) else key: frame.sort("day") for key, frame in time_in_range_daily.group_by("scenario_id")}
        if not time_in_range_daily.is_empty()
        else {}
    )
    fee_by_scenario = (
        {key[0] if isinstance(key, tuple) else key: frame.sort("day") for key, frame in fee_daily.group_by("scenario_id")}
        if not fee_daily.is_empty()
        else {}
    )
    records: list[dict[str, object]] = []
    for scenario in entry_liquidity.to_dicts():
        scenario_id = str(scenario["scenario_id"])
        pool = str(scenario["pool"]).lower()
        closes = closes_by_pool.get(pool, pl.DataFrame())
        if closes.is_empty():
            continue
        start_day = scenario["start_snapshot_block_time"].date()
        fee_frame = fee_by_scenario.get(scenario_id, pl.DataFrame())
        tir_frame = tir_by_scenario.get(scenario_id, pl.DataFrame())
        liq_frame = liq_by_pool.get(pool, pl.DataFrame())
        fee_by_day = (
            {row["day"]: row for row in fee_frame.to_dicts()}
            if not fee_frame.is_empty()
            else {}
        )
        tir_by_day = (
            {row["day"]: row for row in tir_frame.to_dicts()}
            if not tir_frame.is_empty()
            else {}
        )
        liq_by_day = (
            {row["date"]: row for row in liq_frame.to_dicts()}
            if not liq_frame.is_empty()
            else {}
        )
        fees0_cum = 0.0
        fees1_cum = 0.0
        # Cumulative token0_equiv fees accrued at swap-time price (monotonic by
        # construction). Replaces the previous `fees0_cum + fees1_cum * close_price`
        # formula which was mark-to-market and could decrease when token1 weakens.
        fees_equiv_cum = 0.0
        rebalance_count = 0
        daily_rows = closes.filter(pl.col("date") >= start_day)
        for close_row in daily_rows.to_dicts():
            day_value = close_row["date"]
            close_price = float(close_row["close_price"])
            tick = int(close_row["close_tick"])
            token0_decimals = int(scenario["token0_decimals"])
            token1_decimals = int(scenario["token1_decimals"])
            sqrt_close = float(
                sqrt_price_from_human_price(close_price, token0_decimals, token1_decimals)
            )
            sqrt_pa = float(tick_to_sqrt_price(int(scenario["tick_lower"])))
            sqrt_pb = float(tick_to_sqrt_price(int(scenario["tick_upper"])))
            sqrt_clamped = min(max(sqrt_close, sqrt_pa), sqrt_pb)
            amount0 = float(
                amount0_from_liquidity(
                    float(scenario["initial_liquidity"]),
                    sqrt_clamped,
                    sqrt_pb,
                    token0_decimals,
                )
            )
            amount1 = float(
                amount1_from_liquidity(
                    float(scenario["initial_liquidity"]),
                    sqrt_clamped,
                    sqrt_pa,
                    token1_decimals,
                )
            )
            fee_day = fee_by_day.get(day_value)
            tir_day = tir_by_day.get(day_value)
            active_liq_row = liq_by_day.get(day_value)
            fees0_cum += float(fee_day["fees_accrued_token0_day"]) if fee_day else 0.0
            fees1_cum += float(fee_day["fees_accrued_token1_day"]) if fee_day else 0.0
            fees_equiv_cum += (
                float(fee_day["fees_accrued_token0_equiv_day"]) if fee_day else 0.0
            )
            principal_value_token0 = amount0 + amount1 * close_price
            hodl_value_token0 = float(scenario["initial_amount0"]) + float(
                scenario["initial_amount1"]
            ) * close_price
            # Cumulative fees in token0_equiv use swap-time accrual (monotonic).
            # LP value still uses MTM (`fees0_cum + fees1_cum * close_price`) so the
            # current LP wealth reflects current token1 value.
            fees_cumulative_token0 = fees_equiv_cum
            lp_value_including_fees_token0 = (
                principal_value_token0 + fees0_cum + fees1_cum * close_price
            )
            active_liquidity_value = (
                float(active_liq_row["active_liquidity"]) if active_liq_row is not None else 0.0
            )
            records.append(
                {
                    "scenario_id": scenario_id,
                    "pool": pool,
                    "day": day_value,
                    "tick_lower": scenario["tick_lower"],
                    "tick_upper": scenario["tick_upper"],
                    "rebalance_strategy": scenario["rebalance_strategy"],
                    "rebalance_count": rebalance_count,
                    "total_gas_est": 0.0,
                    "price_token1_in_token0": close_price,
                    "sqrt_price": sqrt_close,
                    "tick": tick,
                    "liquidity": float(scenario["initial_liquidity"]),
                    "amount0": amount0,
                    "amount1": amount1,
                    "principal_value_token0": principal_value_token0,
                    "hodl_value_token0": hodl_value_token0,
                    "impermanent_loss_token0": principal_value_token0 - hodl_value_token0,
                    "fees_accrued_token0_cumulative": fees0_cum,
                    "fees_accrued_token1_cumulative": fees1_cum,
                    "fees_accrued_token0_equiv_cumulative": fees_cumulative_token0,
                    "lp_value_including_fees_token0": lp_value_including_fees_token0,
                    "pnl_vs_initial_token0": lp_value_including_fees_token0
                    - float(scenario["capital_committed_token0"]),
                    "pnl_vs_hodl_token0": lp_value_including_fees_token0 - hodl_value_token0,
                    "time_in_range_pct": (
                        float(tir_day["time_in_range_pct"]) if tir_day is not None else None
                    ),
                    "share_of_pool": (
                        float(scenario["initial_liquidity"]) / active_liquidity_value
                        if active_liquidity_value > 0
                        else 0.0
                    ),
                    "is_in_range": is_in_range(
                        tick,
                        int(scenario["tick_lower"]),
                        int(scenario["tick_upper"]),
                    ),
                }
            )
    return pl.DataFrame(records, infer_schema_length=len(records)) if records else pl.DataFrame()


def build_backtest_summary(
    entry_liquidity: pl.DataFrame,
    exit_state: pl.DataFrame,
    swap_path: pl.DataFrame,
    time_in_range_summary: pl.DataFrame,
) -> pl.DataFrame:
    if entry_liquidity.is_empty() or exit_state.is_empty():
        return pl.DataFrame()
    fee_totals = (
        swap_path.group_by("scenario_id")
        .agg(
            pl.len().alias("swap_count_in_window"),
            pl.col("is_active_before_swap").sum().alias("swap_count_while_active"),
            pl.col("fees_accrued_token0").sum().alias("fees_accrued_token0"),
            pl.col("fees_accrued_token1").sum().alias("fees_accrued_token1"),
            pl.col("fees_accrued_token0_equiv_generated").sum().alias(
                "fees_accrued_token0_equiv_generated"
            ),
        )
        if not swap_path.is_empty()
        else pl.DataFrame(
            schema={
                "scenario_id": pl.String,
                "swap_count_in_window": pl.UInt32,
                "swap_count_while_active": pl.UInt32,
                "fees_accrued_token0": pl.Float64,
                "fees_accrued_token1": pl.Float64,
                "fees_accrued_token0_equiv_generated": pl.Float64,
            }
        )
    )
    summary = (
        entry_liquidity.join(exit_state, on="scenario_id", how="left", suffix="_exit")
        .join(fee_totals, on="scenario_id", how="left")
        .join(time_in_range_summary, on="scenario_id", how="left")
        .with_columns(
            pl.col("swap_count_in_window").fill_null(0),
            pl.col("swap_count_while_active").fill_null(0),
            pl.col("fees_accrued_token0").cast(pl.Float64).fill_null(0.0),
            pl.col("fees_accrued_token1").cast(pl.Float64).fill_null(0.0),
            pl.col("fees_accrued_token0_equiv_generated").cast(pl.Float64).fill_null(0.0),
            pl.col("observed_time_in_range_seconds").fill_null(0),
            pl.col("observed_window_seconds").fill_null(0),
            pl.col("observed_out_of_range_seconds").fill_null(0),
        )
        .with_columns(
            (
                pl.col("initial_amount0")
                + pl.col("initial_amount1") * pl.col("end_price")
            ).alias("hodl_end_value_token0"),
            (
                pl.col("end_principal_value_token0")
                + pl.col("fees_accrued_token0_equiv_generated")
            ).alias("lp_end_value_including_fees_token0"),
            (
                pl.col("end_principal_value_token0")
                - (pl.col("initial_amount0") + pl.col("initial_amount1") * pl.col("end_price"))
            ).alias("impermanent_loss_token0"),
            (
                pl.col("end_principal_value_token0")
                + pl.col("fees_accrued_token0_equiv_generated")
                - pl.col("capital_committed_token0")
            ).alias("pnl_vs_initial_token0"),
            (
                pl.col("end_principal_value_token0")
                + pl.col("fees_accrued_token0_equiv_generated")
                - (pl.col("initial_amount0") + pl.col("initial_amount1") * pl.col("end_price"))
            ).alias("pnl_vs_hodl_token0"),
        )
    )
    return summary


def _read_single_scenario_inputs(
    db: ClickHouseDB,
    scenario: BacktestParams,
) -> tuple[pl.DataFrame, pl.DataFrame, pl.DataFrame]:
    pool = scenario.pool.lower()
    pool_meta = _ensure_schema(
        db.read_table(
            "stg_pools",
            columns=[
                "lower(pool) AS pool",
                "tick_spacing",
                "token0_decimals",
                "token1_decimals",
            ],
            where=f"lower(pool) = '{pool}'",
        ),
        {
            "pool": pl.String,
            "tick_spacing": pl.UInt32,
            "token0_decimals": pl.UInt8,
            "token1_decimals": pl.UInt8,
        },
    )
    entry_swap = _ensure_schema(
        db.read_query(
            "SELECT lower(pool) AS pool, block_number, log_index, block_time, "
            "next_block_time, tick_before, price_before, tick_after, price_after, "
            "active_liquidity_at_swap, fees_generated_token0, fees_generated_token1, "
            "fees_generated_token0_equiv "
            f"FROM {db.qualify('int_swaps_enriched')} "
            f"WHERE lower(pool) = '{pool}' AND block_number <= {scenario.start_block} "
            "ORDER BY block_number DESC, log_index DESC LIMIT 1"
        ),
        {
            "pool": pl.String,
            "block_number": pl.UInt64,
            "log_index": pl.UInt32,
            "block_time": pl.Datetime,
            "next_block_time": pl.Datetime,
            "tick_before": pl.Int32,
            "price_before": pl.Float64,
            "tick_after": pl.Int32,
            "price_after": pl.Float64,
            "active_liquidity_at_swap": pl.Float64,
            "fees_generated_token0": pl.Float64,
            "fees_generated_token1": pl.Float64,
            "fees_generated_token0_equiv": pl.Float64,
        },
    )
    exit_swap = _ensure_schema(
        db.read_query(
            "SELECT lower(pool) AS pool, block_number, log_index, block_time, "
            "next_block_time, tick_before, price_before, tick_after, price_after, "
            "active_liquidity_at_swap, fees_generated_token0, fees_generated_token1, "
            "fees_generated_token0_equiv "
            f"FROM {db.qualify('int_swaps_enriched')} "
            f"WHERE lower(pool) = '{pool}' AND block_number <= {scenario.end_block} "
            "ORDER BY block_number DESC, log_index DESC LIMIT 1"
        ),
        {
            "pool": pl.String,
            "block_number": pl.UInt64,
            "log_index": pl.UInt32,
            "block_time": pl.Datetime,
            "next_block_time": pl.Datetime,
            "tick_before": pl.Int32,
            "price_before": pl.Float64,
            "tick_after": pl.Int32,
            "price_after": pl.Float64,
            "active_liquidity_at_swap": pl.Float64,
            "fees_generated_token0": pl.Float64,
            "fees_generated_token1": pl.Float64,
            "fees_generated_token0_equiv": pl.Float64,
        },
    )
    if entry_swap.is_empty() or exit_swap.is_empty():
        return pool_meta, pl.DataFrame(), pl.DataFrame()
    start_time = entry_swap.to_dicts()[0]["block_time"]
    end_time = exit_swap.to_dicts()[0]["block_time"]
    swaps = _ensure_schema(
        db.read_table(
            "int_swaps_enriched",
            columns=[
                "lower(pool) AS pool",
                "block_number",
                "log_index",
                "block_time",
                "next_block_time",
                "tick_before",
                "price_before",
                "tick_after",
                "price_after",
                "active_liquidity_at_swap",
                "fees_generated_token0",
                "fees_generated_token1",
                "fees_generated_token0_equiv",
            ],
            where=(
                f"lower(pool) = '{pool}' AND block_number > {scenario.start_block} "
                f"AND block_number <= {scenario.end_block}"
            ),
        ),
        {
            "pool": pl.String,
            "block_number": pl.UInt64,
            "log_index": pl.UInt32,
            "block_time": pl.Datetime,
            "next_block_time": pl.Datetime,
            "tick_before": pl.Int32,
            "price_before": pl.Float64,
            "tick_after": pl.Int32,
            "price_after": pl.Float64,
            "active_liquidity_at_swap": pl.Float64,
            "fees_generated_token0": pl.Float64,
            "fees_generated_token1": pl.Float64,
            "fees_generated_token0_equiv": pl.Float64,
        },
    )
    daily_close = _ensure_schema(
        db.read_table(
            "int_daily_close_dense",
            columns=["lower(pool) AS pool", "date", "close_tick", "close_price", "close_sqrt_price"],
            where=(
                f"lower(pool) = '{pool}' AND date >= toDate('{start_time.date().isoformat()}') "
                f"AND date <= toDate('{end_time.date().isoformat()}')"
            ),
        ),
        {
            "pool": pl.String,
            "date": pl.Date,
            "close_tick": pl.Int32,
            "close_price": pl.Float64,
            "close_sqrt_price": pl.Float64,
        },
    )
    active_liquidity = _ensure_schema(
        db.read_table(
            "int_active_liquidity_daily",
            columns=["lower(pool) AS pool", "date", "active_liquidity"],
            where=(
                f"lower(pool) = '{pool}' AND date >= toDate('{start_time.date().isoformat()}') "
                f"AND date <= toDate('{end_time.date().isoformat()}')"
            ),
        ),
        {
            "pool": pl.String,
            "date": pl.Date,
            "active_liquidity": pl.Float64,
        },
    )
    combined = daily_close.join(active_liquidity, on=["pool", "date"], how="left")
    anchors = (
        pl.concat([entry_swap, exit_swap], how="vertical_relaxed")
        .unique(subset=["block_number", "log_index"], keep="last")
        .sort(["block_number", "log_index"])
    )
    relevant_swaps = (
        pl.concat([anchors, swaps], how="diagonal_relaxed")
        .unique(subset=["block_number", "log_index"], keep="last")
        .sort(["block_number", "log_index"])
    )
    return pool_meta, relevant_swaps, combined


def resolve_backtest_entry_state(
    scenarios: pl.DataFrame,
    pool_meta: pl.DataFrame,
    swaps: pl.DataFrame,
) -> pl.DataFrame:
    pool_meta_by_pool = {row["pool"]: row for row in pool_meta.to_dicts()}
    records: list[dict[str, object]] = []
    for scenario in scenarios.to_dicts():
        pool = str(scenario["pool"]).lower()
        pool_swaps = swaps.filter(pl.col("pool") == pool).sort(["block_number", "log_index"])
        if pool_swaps.is_empty():
            continue
        entry = pool_swaps.filter(pl.col("block_number") <= int(scenario["start_block"]))
        if entry.is_empty():
            continue
        entry_row = entry.tail(1).to_dicts()[0]
        meta = pool_meta_by_pool[pool]
        start_price = float(entry_row["price_after"])
        records.append(
            {
                **scenario,
                "tick_spacing": int(meta["tick_spacing"]),
                "token0_decimals": int(meta["token0_decimals"]),
                "token1_decimals": int(meta["token1_decimals"]),
                "start_snapshot_block_number": entry_row["block_number"],
                "start_snapshot_log_index": entry_row["log_index"],
                "start_snapshot_block_time": entry_row["block_time"],
                "start_tick": int(entry_row["tick_after"]),
                "start_price": start_price,
                "start_sqrt_price": float(
                    sqrt_price_from_human_price(
                        start_price,
                        int(meta["token0_decimals"]),
                        int(meta["token1_decimals"]),
                    )
                ),
            }
        )
    return pl.DataFrame(records, infer_schema_length=len(records)) if records else pl.DataFrame()


def run_backtest(
    db: ClickHouseDB,
    scenarios: list[BacktestParams | dict[str, object]],
    *,
    write: bool = False,
    results_table: str = "py_backtest_results",
    summary_table: str = "py_backtest_summary",
) -> tuple[pl.DataFrame, pl.DataFrame]:
    normalized = normalize_scenarios(scenarios)
    if not normalized:
        return pl.DataFrame(), pl.DataFrame()
    results_parts: list[pl.DataFrame] = []
    summary_parts: list[pl.DataFrame] = []
    for scenario in normalized:
        scenario_df = scenarios_to_frame([scenario])
        pool_meta, swaps, daily_with_liquidity = _read_single_scenario_inputs(db, scenario)
        if pool_meta.is_empty() or swaps.is_empty() or daily_with_liquidity.is_empty():
            continue
        entry_state = resolve_backtest_entry_state(scenario_df, pool_meta, swaps)
        if entry_state.is_empty():
            continue
        entry_liquidity = build_backtest_entry_liquidity(entry_state)
        if entry_liquidity.is_empty():
            continue
        exit_state = build_backtest_exit_state(entry_liquidity, swaps)
        if exit_state.is_empty():
            continue
        swap_path = build_backtest_swap_path(entry_liquidity, swaps)
        tir_summary, tir_daily = build_backtest_time_in_range(entry_liquidity, exit_state, swaps)
        daily_close = daily_with_liquidity.select(
            "pool", "date", "close_tick", "close_price", "close_sqrt_price"
        )
        active_liquidity = daily_with_liquidity.select("pool", "date", "active_liquidity")
        scenario_results = build_backtest_daily_results(
            entry_liquidity,
            daily_close,
            active_liquidity,
            swap_path,
            tir_daily,
        )
        scenario_summary = build_backtest_summary(
            entry_liquidity,
            exit_state,
            swap_path,
            tir_summary,
        )
        if not scenario_results.is_empty():
            results_parts.append(scenario_results)
        if not scenario_summary.is_empty():
            summary_parts.append(scenario_summary)
    results = pl.concat(results_parts, how="diagonal_relaxed") if results_parts else pl.DataFrame()
    summary = pl.concat(summary_parts, how="diagonal_relaxed") if summary_parts else pl.DataFrame()
    if write:
        if not results.is_empty():
            db.write_table(
                results,
                results_table,
                create_if_missing=True,
                order_by=["scenario_id", "day"],
            )
        if not summary.is_empty():
            db.write_table(
                summary,
                summary_table,
                create_if_missing=True,
                order_by=["scenario_id"],
            )
    return results, summary


def compare_backtest_summary_to_dbt(
    db: ClickHouseDB,
    summary: pl.DataFrame,
    *,
    tolerance: float = 1e-3,
) -> pl.DataFrame:
    if summary.is_empty():
        return pl.DataFrame()
    scenario_ids = ", ".join(f"'{value}'" for value in summary.get_column("scenario_id").to_list())
    dbt = db.read_table(
        "mart_position_backtest_summary",
        columns=[
            "scenario_id",
            "end_principal_value_token0",
            "fees_accrued_token0_equiv_generated",
            "hodl_end_value_token0",
            "lp_end_value_including_fees_token0",
            "impermanent_loss_token0",
            "pnl_vs_initial_token0",
            "pnl_vs_hodl_token0",
            "observed_time_in_range_pct",
        ],
        where=f"scenario_id IN ({scenario_ids})",
    )
    if dbt.is_empty():
        return pl.DataFrame()
    return (
        summary.join(dbt, on="scenario_id", how="inner", suffix="_dbt")
        .with_columns(
            (
                (pl.col("lp_end_value_including_fees_token0") - pl.col("lp_end_value_including_fees_token0_dbt"))
                / pl.col("lp_end_value_including_fees_token0_dbt").abs().clip(lower_bound=1e-12)
            ).alias("lp_end_value_rel_error"),
            (
                (pl.col("pnl_vs_hodl_token0") - pl.col("pnl_vs_hodl_token0_dbt"))
                / pl.col("pnl_vs_hodl_token0_dbt").abs().clip(lower_bound=1e-12)
            ).alias("pnl_vs_hodl_rel_error"),
        )
        .with_columns(
            (pl.col("lp_end_value_rel_error").abs() <= tolerance).alias("lp_end_value_within_tolerance"),
            (pl.col("pnl_vs_hodl_rel_error").abs() <= tolerance).alias("pnl_vs_hodl_within_tolerance"),
        )
    )


def summarize_backtest_comparison(comparison: pl.DataFrame) -> dict[str, float | int]:
    if comparison.is_empty():
        return {
            "matched_scenarios": 0,
            "lp_end_value_within_tolerance_count": 0,
            "pnl_vs_hodl_within_tolerance_count": 0,
            "avg_abs_lp_end_value_rel_error": 0.0,
            "avg_abs_pnl_vs_hodl_rel_error": 0.0,
        }
    return {
        "matched_scenarios": comparison.height,
        "lp_end_value_within_tolerance_count": int(comparison["lp_end_value_within_tolerance"].sum()),
        "pnl_vs_hodl_within_tolerance_count": int(comparison["pnl_vs_hodl_within_tolerance"].sum()),
        "avg_abs_lp_end_value_rel_error": float(comparison["lp_end_value_rel_error"].abs().mean()),
        "avg_abs_pnl_vs_hodl_rel_error": float(comparison["pnl_vs_hodl_rel_error"].abs().mean()),
    }
