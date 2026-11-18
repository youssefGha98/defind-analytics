"""Shared dataclasses for the Python analytics layer."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class PositionParams:
    token_id: int
    pool: str
    tick_lower: int
    tick_upper: int
    sqrt_pa: float
    sqrt_pb: float


@dataclass(frozen=True)
class BacktestParams:
    scenario_id: str
    pool: str
    start_block: int
    end_block: int
    tick_lower: int
    tick_upper: int
    capital_committed_token0: float
    rebalance_strategy: str | None = "none"
    grain: str = "daily"


@dataclass(frozen=True)
class PerfRow:
    token_id: int
    day: date
    price: float
    sqrt_price: float
    tick: int
    L_effective: float
    reserve_x: float
    reserve_y: float
    position_value: float
    hodl_value: float
    il: float
    fees_collected_value: float
    fees_uncollected_est: float
    pnl_net: float
    pnl_vs_hodl: float
    time_in_range_pct: float
    share_of_pool: float
    is_in_range: bool
