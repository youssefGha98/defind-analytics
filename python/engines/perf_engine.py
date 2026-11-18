"""Mark-to-market performance engine for real NFPM positions."""

from __future__ import annotations

from dataclasses import asdict
from datetime import date

import polars as pl

from core.db import ClickHouseDB
from core.position_math import (
    amount0_from_liquidity,
    amount1_from_liquidity,
    sqrt_price_from_human_price,
    tick_to_sqrt_price,
)


def _date_filter(column: str, start_date: date | None, end_date: date | None) -> str:
    predicates: list[str] = []
    if start_date is not None:
        predicates.append(f"{column} >= toDate('{start_date.isoformat()}')")
    if end_date is not None:
        predicates.append(f"{column} <= toDate('{end_date.isoformat()}')")
    return " AND ".join(predicates) if predicates else "1 = 1"


def _id_filter(column: str, values: list[int] | None) -> str:
    if not values:
        return "1 = 1"
    ids = ", ".join(str(int(v)) for v in values)
    return f"{column} IN ({ids})"


def _pool_filter(column: str, pool: str | None) -> str:
    if not pool:
        return "1 = 1"
    return f"lower({column}) = lower('{pool}')"


def _position_scope_where(
    *,
    pool: str | None = None,
    token_ids: list[int] | None = None,
) -> str:
    return " AND ".join(
        [
            _pool_filter("pool", pool),
            _id_filter("token_id", token_ids),
        ]
    )


def _position_scope_subquery(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    token_ids: list[int] | None = None,
) -> str:
    return (
        f"SELECT token_id FROM {db.qualify('int_nfpm_positions')} "
        f"WHERE {_position_scope_where(pool=pool, token_ids=token_ids)}"
    )


def _read_perf_inputs(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    token_ids: list[int] | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
) -> dict[str, pl.DataFrame]:
    position_where = _position_scope_where(pool=pool, token_ids=token_ids)
    positions = db.read_table(
        "int_nfpm_positions",
        columns=[
            "toUInt64(token_id) AS token_id",
            "lower(pool) AS pool",
            "tick_lower",
            "tick_upper",
            "mint_block_time",
            "token0_decimals",
            "token1_decimals",
        ],
        where=position_where,
    )
    if positions.is_empty():
        return {
            "positions": positions,
            "daily_close": pl.DataFrame(),
            "active_liquidity": pl.DataFrame(),
            "lvr_daily": pl.DataFrame(),
            "increase_lots": pl.DataFrame(),
            "liquidity_events": pl.DataFrame(),
            "collects": pl.DataFrame(),
            "time_in_range": pl.DataFrame(),
            "fee_accruals": pl.DataFrame(),
        }

    pools = positions.get_column("pool").unique().to_list()
    quoted_pools = ", ".join(f"'{pool_value.lower()}'" for pool_value in pools)
    pool_set_filter = f"lower(pool) IN ({quoted_pools})"
    dates_filter = _date_filter("date", start_date, end_date)

    daily_close = db.read_table(
        "int_daily_close_dense",
        columns=["lower(pool) AS pool", "date", "close_tick", "close_price", "close_sqrt_price"],
        where=f"{pool_set_filter} AND {dates_filter}",
    )
    active_liquidity = db.read_table(
        "int_active_liquidity_daily",
        columns=["lower(pool) AS pool", "date", "active_liquidity"],
        where=f"{pool_set_filter} AND {dates_filter}",
    )
    if db.table_exists("py_lvr_daily"):
        lvr_daily = db.read_table(
            "py_lvr_daily",
            columns=["lower(pool) AS pool", "day AS date", "lvr_total"],
            where=f"{pool_set_filter} AND {_date_filter('day', start_date, end_date)}",
        )
    else:
        lvr_daily = pl.DataFrame(
            schema={
                "pool": pl.String,
                "date": pl.Date,
                "lvr_total": pl.Float64,
            }
        )
    scoped_token_ids = _position_scope_subquery(db, pool=pool, token_ids=token_ids)
    increase_lots = db.read_table(
        "int_nfpm_position_increase_lots",
        columns=[
            "toUInt64(token_id) AS token_id",
            "lot_seq",
            "lot_block_time",
            "lot_amount0",
            "lot_amount1",
            "entry_price_token1_in_token0",
        ],
        where=f"token_id IN ({scoped_token_ids})",
    )
    liquidity_events = db.read_table(
        "int_nfpm_position_liquidity_events",
        columns=[
            "toUInt64(token_id) AS token_id",
            "block_time",
            "log_index",
            "event_type",
            "liquidity_delta_raw",
            "amount0",
            "amount1",
        ],
        where=f"token_id IN ({scoped_token_ids})",
    )
    collects = db.read_table(
        "int_nfpm_position_collect_decomposition",
        columns=[
            "toUInt64(token_id) AS token_id",
            "block_time",
            "principal_collected_amount0",
            "principal_collected_amount1",
            "fees_collected_amount0",
            "fees_collected_amount1",
        ],
        where=f"token_id IN ({scoped_token_ids})",
    )
    time_in_range = db.read_table(
        "int_nfpm_position_time_in_range_daily",
        columns=["toUInt64(token_id) AS token_id", "date", "observed_time_in_range_pct"],
        where=f"token_id IN ({scoped_token_ids})",
    )
    fee_accruals = db.read_table(
        "int_nfpm_position_fee_daily",
        columns=[
            "toUInt64(token_id) AS token_id",
            "date",
            "total_fees_accrued_amount0",
            "total_fees_accrued_amount1",
            "total_fees_accrued_token0_equiv_generated",
        ],
        where=f"token_id IN ({scoped_token_ids})",
    )
    return {
        "positions": positions,
        "daily_close": daily_close,
        "active_liquidity": active_liquidity,
        "lvr_daily": lvr_daily,
        "increase_lots": increase_lots,
        "liquidity_events": liquidity_events,
        "collects": collects,
        "time_in_range": time_in_range,
        "fee_accruals": fee_accruals,
    }


def build_position_performance_daily(
    *,
    positions: pl.DataFrame,
    daily_close: pl.DataFrame,
    active_liquidity: pl.DataFrame,
    increase_lots: pl.DataFrame,
    liquidity_events: pl.DataFrame,
    collects: pl.DataFrame,
    time_in_range: pl.DataFrame,
    fee_accruals: pl.DataFrame,
    lvr_daily: pl.DataFrame | None = None,
) -> pl.DataFrame:
    if positions.is_empty() or daily_close.is_empty():
        return pl.DataFrame(
            schema={
                "token_id": pl.Int64,
                "day": pl.Date,
                "price": pl.Float64,
                "sqrt_price": pl.Float64,
                "tick": pl.Int32,
                "L_effective": pl.Float64,
                "reserve_x": pl.Float64,
                "reserve_y": pl.Float64,
                "position_value": pl.Float64,
                "hodl_value": pl.Float64,
                "il": pl.Float64,
                "fees_collected_value": pl.Float64,
                "fees_uncollected_est": pl.Float64,
                "principal_owed_value": pl.Float64,
                "principal_collected_value": pl.Float64,
                "principal_wealth": pl.Float64,
                "total_wealth": pl.Float64,
                "pnl_net": pl.Float64,
                "pnl_vs_hodl": pl.Float64,
                "time_in_range_pct": pl.Float64,
                "share_of_pool": pl.Float64,
                "lvr_cumulative": pl.Float64,
                "is_in_range": pl.Boolean,
                "pool": pl.String,
                "tick_lower": pl.Int32,
                "tick_upper": pl.Int32,
                "token0_decimals": pl.Int64,
                "token1_decimals": pl.Int64,
                "cum_hodl_amount0": pl.Float64,
                "cum_hodl_amount1": pl.Float64,
                "cum_principal_generated_amount0": pl.Float64,
                "cum_principal_generated_amount1": pl.Float64,
                "cum_principal_collected_amount0": pl.Float64,
                "cum_principal_collected_amount1": pl.Float64,
                "cum_fees_amount0": pl.Float64,
                "cum_fees_amount1": pl.Float64,
                "cum_fees_generated_amount0": pl.Float64,
                "cum_fees_generated_amount1": pl.Float64,
            }
        )

    window_start = daily_close.get_column("date").min()

    positions_daily = (
        positions.with_columns(pl.col("mint_block_time").dt.date().alias("mint_date"))
        .join(daily_close, on="pool", how="inner")
        .filter(pl.col("date") >= pl.col("mint_date"))
        .drop("mint_date")
    )

    liq_daily = (
        liquidity_events.sort(["token_id", "block_time", "log_index"])
        .with_columns(
            pl.col("liquidity_delta_raw").cast(pl.Float64).cum_sum().over("token_id").alias("liquidity_after"),
            pl.col("block_time").dt.date().alias("date"),
        )
        .group_by(["token_id", "date"])
        .agg(
            pl.col("liquidity_after").last().alias("L_effective_event"),
            pl.when(pl.col("amount0").cast(pl.Float64) < 0)
            .then(-pl.col("amount0").cast(pl.Float64))
            .otherwise(0.0)
            .sum()
            .alias("principal_generated_amount0"),
            pl.when(pl.col("amount1").cast(pl.Float64) < 0)
            .then(-pl.col("amount1").cast(pl.Float64))
            .otherwise(0.0)
            .sum()
            .alias("principal_generated_amount1"),
        )
    )

    opening_liquidity = (
        liquidity_events.with_columns(pl.col("block_time").dt.date().alias("date"))
        .filter(pl.col("date") < window_start)
        .group_by("token_id")
        .agg(pl.col("liquidity_delta_raw").cast(pl.Float64).sum().alias("opening_liquidity"))
    )

    if increase_lots.is_empty():
        lot_daily = pl.DataFrame(
            schema={
                "token_id": pl.UInt64,
                "date": pl.Date,
                "lot_amount0": pl.Float64,
                "lot_amount1": pl.Float64,
                "lot_value1_in_token0": pl.Float64,
            }
        )
        opening_lots = pl.DataFrame(
            schema={
                "token_id": pl.UInt64,
                "opening_lot_amount0": pl.Float64,
                "opening_lot_amount1": pl.Float64,
                "opening_lot_value1_in_token0": pl.Float64,
            }
        )
    else:
        increase_lots_with_dates = increase_lots.with_columns(
            pl.col("lot_block_time").dt.date().alias("date"),
            pl.col("entry_price_token1_in_token0").cast(pl.Float64).alias("entry_price_t1_in_t0"),
        )
        lot_daily = (
            increase_lots_with_dates
            .group_by(["token_id", "date"])
            .agg(
                pl.col("lot_amount0").cast(pl.Float64).sum().alias("lot_amount0"),
                pl.col("lot_amount1").cast(pl.Float64).sum().alias("lot_amount1"),
                (
                    pl.col("lot_amount1").cast(pl.Float64)
                    * pl.col("entry_price_t1_in_t0").cast(pl.Float64)
                ).sum().alias("lot_value1_in_token0"),
            )
        )
        opening_lots = (
            increase_lots_with_dates.filter(pl.col("date") < window_start)
            .group_by("token_id")
            .agg(
                pl.col("lot_amount0").cast(pl.Float64).sum().alias("opening_lot_amount0"),
                pl.col("lot_amount1").cast(pl.Float64).sum().alias("opening_lot_amount1"),
                (
                    pl.col("lot_amount1").cast(pl.Float64)
                    * pl.col("entry_price_t1_in_t0").cast(pl.Float64)
                ).sum().alias("opening_lot_value1_in_token0"),
            )
        )

    if collects.is_empty():
        collect_daily = pl.DataFrame(
            schema={
                "token_id": pl.UInt64,
                "date": pl.Date,
                "principal_collected_amount0": pl.Float64,
                "principal_collected_amount1": pl.Float64,
                "fees_collected_amount0": pl.Float64,
                "fees_collected_amount1": pl.Float64,
            }
        )
        opening_collects = pl.DataFrame(
            schema={
                "token_id": pl.UInt64,
                "opening_principal_collected_amount0": pl.Float64,
                "opening_principal_collected_amount1": pl.Float64,
                "opening_fees_collected_amount0": pl.Float64,
                "opening_fees_collected_amount1": pl.Float64,
            }
        )
    else:
        collects_with_dates = collects.with_columns(pl.col("block_time").dt.date().alias("date"))
        collect_daily = (
            collects_with_dates
            .group_by(["token_id", "date"])
            .agg(
                pl.col("principal_collected_amount0").cast(pl.Float64).sum().alias("principal_collected_amount0"),
                pl.col("principal_collected_amount1").cast(pl.Float64).sum().alias("principal_collected_amount1"),
                pl.col("fees_collected_amount0").cast(pl.Float64).sum().alias("fees_collected_amount0"),
                pl.col("fees_collected_amount1").cast(pl.Float64).sum().alias("fees_collected_amount1"),
            )
        )
        opening_collects = (
            collects_with_dates.filter(pl.col("date") < window_start)
            .group_by("token_id")
            .agg(
                pl.col("principal_collected_amount0").cast(pl.Float64).sum().alias("opening_principal_collected_amount0"),
                pl.col("principal_collected_amount1").cast(pl.Float64).sum().alias("opening_principal_collected_amount1"),
                pl.col("fees_collected_amount0").cast(pl.Float64).sum().alias("opening_fees_collected_amount0"),
                pl.col("fees_collected_amount1").cast(pl.Float64).sum().alias("opening_fees_collected_amount1"),
            )
        )

    if time_in_range.is_empty():
        tir_daily = pl.DataFrame(
            schema={
                "token_id": pl.UInt64,
                "date": pl.Date,
                "time_in_range_pct": pl.Float64,
            }
        )
    else:
        tir_daily = time_in_range.rename({"observed_time_in_range_pct": "time_in_range_pct"})

    if fee_accruals.is_empty():
        fee_generated_daily = pl.DataFrame(
            schema={
                "token_id": pl.UInt64,
                "date": pl.Date,
                "total_fees_accrued_amount0": pl.Float64,
                "total_fees_accrued_amount1": pl.Float64,
                "total_fees_accrued_token0_equiv_generated": pl.Float64,
            }
        )
        opening_fees_generated = pl.DataFrame(
            schema={
                "token_id": pl.UInt64,
                "opening_fees_generated_amount0": pl.Float64,
                "opening_fees_generated_amount1": pl.Float64,
            }
        )
    else:
        fee_generated_daily = fee_accruals.with_columns(pl.col("date").cast(pl.Date))
        opening_fees_generated = (
            fee_generated_daily.filter(pl.col("date") < window_start)
            .group_by("token_id")
            .agg(
                pl.col("total_fees_accrued_amount0").cast(pl.Float64).sum().alias("opening_fees_generated_amount0"),
                pl.col("total_fees_accrued_amount1").cast(pl.Float64).sum().alias("opening_fees_generated_amount1"),
            )
        )

    opening_generated = (
        liquidity_events.with_columns(pl.col("block_time").dt.date().alias("date"))
        .filter(pl.col("date") < window_start)
        .group_by("token_id")
        .agg(
            pl.when(pl.col("amount0").cast(pl.Float64) < 0)
            .then(-pl.col("amount0").cast(pl.Float64))
            .otherwise(0.0)
            .sum()
            .alias("opening_principal_generated_amount0"),
            pl.when(pl.col("amount1").cast(pl.Float64) < 0)
            .then(-pl.col("amount1").cast(pl.Float64))
            .otherwise(0.0)
            .sum()
            .alias("opening_principal_generated_amount1"),
        )
    )

    if lvr_daily is None or lvr_daily.is_empty():
        lvr_daily_frame = pl.DataFrame(
            schema={
                "pool": pl.String,
                "date": pl.Date,
                "lvr_total": pl.Float64,
            }
        )
    else:
        lvr_daily_frame = lvr_daily.with_columns(
            pl.col("pool").cast(pl.String),
            pl.col("date").cast(pl.Date),
            pl.col("lvr_total").cast(pl.Float64),
        )

    df = (
        positions_daily.join(liq_daily, on=["token_id", "date"], how="left")
        .sort(["token_id", "date"])
        .join(opening_liquidity, on="token_id", how="left")
        .join(opening_lots, on="token_id", how="left")
        .join(opening_collects, on="token_id", how="left")
        .join(opening_generated, on="token_id", how="left")
        .join(opening_fees_generated, on="token_id", how="left")
        .with_columns(
            pl.col("L_effective_event")
            .forward_fill()
            .over("token_id")
            .fill_null(pl.col("opening_liquidity"))
            .fill_null(0.0)
            .clip(lower_bound=0.0)
            .alias("L_effective")
        )
        .drop("L_effective_event", "opening_liquidity")
        .join(active_liquidity, on=["pool", "date"], how="left")
        .join(lvr_daily_frame, on=["pool", "date"], how="left")
        .join(lot_daily, on=["token_id", "date"], how="left")
        .join(collect_daily, on=["token_id", "date"], how="left")
        .join(tir_daily, on=["token_id", "date"], how="left")
        .join(fee_generated_daily, on=["token_id", "date"], how="left")
        .with_columns(
            pl.col("opening_lot_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_lot_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_lot_value1_in_token0").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_principal_generated_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_principal_generated_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_principal_collected_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_principal_collected_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_fees_collected_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_fees_collected_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_fees_generated_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("opening_fees_generated_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("active_liquidity").cast(pl.Float64).fill_null(0.0),
            pl.col("lvr_total").cast(pl.Float64).fill_null(0.0),
            pl.col("lot_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("lot_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("lot_value1_in_token0").cast(pl.Float64).fill_null(0.0),
            pl.col("principal_generated_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("principal_generated_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("principal_collected_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("principal_collected_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("fees_collected_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("fees_collected_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("total_fees_accrued_amount0").cast(pl.Float64).fill_null(0.0),
            pl.col("total_fees_accrued_amount1").cast(pl.Float64).fill_null(0.0),
            pl.col("time_in_range_pct").cast(pl.Float64).fill_null(0.0),
        )
        .with_columns(
            (1.0 / pl.col("close_price").cast(pl.Float64)).alias("price"),
            pl.struct(["close_price", "token0_decimals", "token1_decimals"]).map_elements(
                lambda row: float(
                    sqrt_price_from_human_price(
                        float(row["close_price"]),
                        int(row["token0_decimals"]),
                        int(row["token1_decimals"]),
                    )
                ),
                return_dtype=pl.Float64,
            ).alias("sqrt_price"),
            pl.struct("tick_lower").map_elements(
                lambda row: float(tick_to_sqrt_price(int(row["tick_lower"]))),
                return_dtype=pl.Float64,
            ).alias("sqrt_pa"),
            pl.struct("tick_upper").map_elements(
                lambda row: float(tick_to_sqrt_price(int(row["tick_upper"]))),
                return_dtype=pl.Float64,
            ).alias("sqrt_pb"),
            pl.col("close_tick").cast(pl.Int32).alias("tick"),
        )
        .with_columns(
            (pl.col("opening_lot_amount0") + pl.col("lot_amount0").cum_sum().over("token_id")).alias("cum_hodl_amount0"),
            (pl.col("opening_lot_amount1") + pl.col("lot_amount1").cum_sum().over("token_id")).alias("cum_hodl_amount1"),
            (
                pl.col("opening_lot_value1_in_token0")
                + (pl.col("lot_amount0") + pl.col("lot_value1_in_token0")).cum_sum().over("token_id")
            ).alias("initial_value_token0"),
            (
                pl.col("opening_principal_generated_amount0")
                + pl.col("principal_generated_amount0").cum_sum().over("token_id")
            ).alias("cum_principal_generated_amount0"),
            (
                pl.col("opening_principal_generated_amount1")
                + pl.col("principal_generated_amount1").cum_sum().over("token_id")
            ).alias("cum_principal_generated_amount1"),
            (
                pl.col("opening_principal_collected_amount0")
                + pl.col("principal_collected_amount0").cum_sum().over("token_id")
            ).alias("cum_principal_collected_amount0"),
            (
                pl.col("opening_principal_collected_amount1")
                + pl.col("principal_collected_amount1").cum_sum().over("token_id")
            ).alias("cum_principal_collected_amount1"),
            (
                pl.col("opening_fees_collected_amount0")
                + pl.col("fees_collected_amount0").cum_sum().over("token_id")
            ).alias("cum_fees_amount0"),
            (
                pl.col("opening_fees_collected_amount1")
                + pl.col("fees_collected_amount1").cum_sum().over("token_id")
            ).alias("cum_fees_amount1"),
            (
                pl.col("opening_fees_generated_amount0")
                + pl.col("total_fees_accrued_amount0").cum_sum().over("token_id")
            ).alias("cum_fees_generated_amount0"),
            (
                pl.col("opening_fees_generated_amount1")
                + pl.col("total_fees_accrued_amount1").cum_sum().over("token_id")
            ).alias("cum_fees_generated_amount1"),
        )
        .with_columns(
            pl.when(pl.col("sqrt_price") < pl.col("sqrt_pa"))
            .then(pl.col("sqrt_pa"))
            .when(pl.col("sqrt_price") > pl.col("sqrt_pb"))
            .then(pl.col("sqrt_pb"))
            .otherwise(pl.col("sqrt_price"))
            .alias("sqrt_price_clamped"),
            (
                (pl.col("tick_lower") <= pl.col("tick"))
                & (pl.col("tick") < pl.col("tick_upper"))
            ).alias("is_in_range"),
            # share_of_pool is the fee-share weight when the position is in-range.
            # Zero when out-of-range — OOR positions earn no fees / accrue no LVR.
            # Without the in-range guard, a large OOR L_effective compared to the
            # pool's active_liquidity (which excludes this OOR position) yields ratios > 1.
            pl.when(
                (pl.col("active_liquidity") > 0)
                & (pl.col("tick_lower") <= pl.col("tick"))
                & (pl.col("tick") < pl.col("tick_upper"))
            )
            .then(pl.col("L_effective") / pl.col("active_liquidity"))
            .otherwise(0.0)
            .alias("share_of_pool"),
        )
        .with_columns(
            pl.struct(
                [
                    "L_effective",
                    "sqrt_price_clamped",
                    "sqrt_pb",
                    "token0_decimals",
                ]
            ).map_elements(
                lambda row: float(
                    amount0_from_liquidity(
                        float(row["L_effective"]),
                        float(row["sqrt_price_clamped"]),
                        float(row["sqrt_pb"]),
                        int(row["token0_decimals"]),
                    )
                ),
                return_dtype=pl.Float64,
            ).alias("reserve_x"),
            pl.struct(
                [
                    "L_effective",
                    "sqrt_price_clamped",
                    "sqrt_pa",
                    "token1_decimals",
                ]
            ).map_elements(
                lambda row: float(
                    amount1_from_liquidity(
                        float(row["L_effective"]),
                        float(row["sqrt_price_clamped"]),
                        float(row["sqrt_pa"]),
                        int(row["token1_decimals"]),
                    )
                ),
                return_dtype=pl.Float64,
            ).alias("reserve_y"),
        )
        .with_columns(
            (pl.col("reserve_x") + pl.col("reserve_y") * pl.col("close_price")).alias("position_value"),
            (pl.col("cum_hodl_amount0") + pl.col("cum_hodl_amount1") * pl.col("close_price")).alias("hodl_value"),
            (
                (pl.col("cum_principal_generated_amount0") - pl.col("cum_principal_collected_amount0"))
                + (pl.col("cum_principal_generated_amount1") - pl.col("cum_principal_collected_amount1"))
                * pl.col("close_price")
            ).clip(lower_bound=0.0).alias("principal_owed_value"),
            (
                pl.col("cum_principal_collected_amount0")
                + pl.col("cum_principal_collected_amount1") * pl.col("close_price")
            ).alias("principal_collected_value"),
            (pl.col("cum_fees_amount0") + pl.col("cum_fees_amount1") * pl.col("close_price")).alias("fees_collected_value"),
        )
        .with_columns(
            (
                (
                    pl.col("cum_fees_generated_amount0")
                    - pl.col("cum_fees_amount0")
                )
                + (
                    pl.col("cum_fees_generated_amount1")
                    - pl.col("cum_fees_amount1")
                ) * pl.col("close_price")
            ).clip(lower_bound=0.0).alias("fees_uncollected_est"),
        )
        .with_columns(
            (
                pl.col("position_value")
                + pl.col("principal_owed_value")
                + pl.col("principal_collected_value")
            ).alias("principal_wealth"),
        )
        .with_columns(
            (
                pl.col("principal_wealth")
                + pl.col("fees_collected_value")
                + pl.col("fees_uncollected_est")
            ).alias("total_wealth"),
            (pl.col("principal_wealth") - pl.col("hodl_value")).alias("il"),
        )
        .with_columns(
            (pl.col("total_wealth") - pl.col("initial_value_token0")).alias("pnl_net"),
            (pl.col("total_wealth") - pl.col("hodl_value")).alias("pnl_vs_hodl"),
            (
                (pl.col("lvr_total") * pl.col("share_of_pool") * pl.col("time_in_range_pct"))
                .cum_sum()
                .over("token_id")
            ).alias("lvr_cumulative"),
        )
        .select(
            "token_id",
            pl.col("date").alias("day"),
            "price",
            "sqrt_price",
            "tick",
            "L_effective",
            "reserve_x",
            "reserve_y",
            "position_value",
            "hodl_value",
            "il",
            "fees_collected_value",
            "fees_uncollected_est",
            "principal_owed_value",
            "principal_collected_value",
            "principal_wealth",
            "total_wealth",
            "pnl_net",
            "pnl_vs_hodl",
            "time_in_range_pct",
            "share_of_pool",
            "lvr_cumulative",
            "is_in_range",
            "pool",
            "tick_lower",
            "tick_upper",
            "token0_decimals",
            "token1_decimals",
            "cum_hodl_amount0",
            "cum_hodl_amount1",
            "cum_principal_generated_amount0",
            "cum_principal_generated_amount1",
            "cum_principal_collected_amount0",
            "cum_principal_collected_amount1",
            "cum_fees_amount0",
            "cum_fees_amount1",
            "cum_fees_generated_amount0",
            "cum_fees_generated_amount1",
        )
    )
    return df.sort(["token_id", "day"])


def run_position_performance(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    token_ids: list[int] | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
    write: bool = False,
    output_table: str = "py_position_performance_daily",
) -> pl.DataFrame:
    inputs = _read_perf_inputs(
        db,
        pool=pool,
        token_ids=token_ids,
        start_date=start_date,
        end_date=end_date,
    )
    perf = build_position_performance_daily(**inputs)
    if write and not perf.is_empty():
        db.write_table(
            perf,
            output_table,
            create_if_missing=True,
            order_by=["token_id", "day"],
        )
    return perf


def compare_terminal_values_to_dbt(
    db: ClickHouseDB,
    perf: pl.DataFrame,
    *,
    pool: str | None = None,
    token_ids: list[int] | None = None,
    tolerance: float = 1e-3,
) -> pl.DataFrame:
    if perf.is_empty():
        return pl.DataFrame()
    terminal = perf.sort(["token_id", "day"]).group_by("token_id").tail(1)
    terminal_pools = terminal.get_column("pool").unique().to_list()
    quoted_pools = ", ".join(f"'{pool_value.lower()}'" for pool_value in terminal_pools)
    current_state = db.read_table(
        "int_current_state",
        columns=[
            "lower(pool) AS pool",
            "current_tick",
            "price_token1_in_token0",
        ],
        where=f"lower(pool) IN ({quoted_pools})",
    )
    dbt_scope = " AND ".join(
        [
            _pool_filter("pool", pool),
            _id_filter("toUInt64(token_id)", token_ids),
        ]
    )
    dbt = db.read_table(
        "mart_nfpm_position_pnl_current",
        columns=[
            "toUInt64(token_id) AS token_id",
            "lower(pool) AS pool",
            "current_deployed_principal_token0",
            "principal_owed_token0_equiv_current",
            "principal_collected_token0_equiv_current",
            "current_collected_fee_wealth_token0",
            "current_uncollected_fee_wealth_token0",
            "current_fee_wealth_token0",
            "current_total_wealth_token0",
            "pnl_vs_hodl_token0",
            "current_price_token1_in_token0",
        ],
        where=dbt_scope,
    )
    if dbt.is_empty():
        return pl.DataFrame()
    comparison = (
        terminal.join(current_state, on="pool", how="left")
        .with_columns(
            pl.struct(["price_token1_in_token0", "token0_decimals", "token1_decimals"]).map_elements(
                lambda row: float(
                    sqrt_price_from_human_price(
                        float(row["price_token1_in_token0"]),
                        int(row["token0_decimals"]),
                        int(row["token1_decimals"]),
                    )
                ),
                return_dtype=pl.Float64,
            ).alias("sqrt_price_current"),
            pl.struct("tick_lower").map_elements(
                lambda row: float(tick_to_sqrt_price(int(row["tick_lower"]))),
                return_dtype=pl.Float64,
            ).alias("sqrt_pa_current"),
            pl.struct("tick_upper").map_elements(
                lambda row: float(tick_to_sqrt_price(int(row["tick_upper"]))),
                return_dtype=pl.Float64,
            ).alias("sqrt_pb_current"),
        )
        .with_columns(
            pl.when(pl.col("sqrt_price_current") < pl.col("sqrt_pa_current"))
            .then(pl.col("sqrt_pa_current"))
            .when(pl.col("sqrt_price_current") > pl.col("sqrt_pb_current"))
            .then(pl.col("sqrt_pb_current"))
            .otherwise(pl.col("sqrt_price_current"))
            .alias("sqrt_price_current_clamped"),
        )
        .with_columns(
            pl.struct(
                [
                    "L_effective",
                    "sqrt_price_current_clamped",
                    "sqrt_pb_current",
                    "token0_decimals",
                ]
            ).map_elements(
                lambda row: float(
                    amount0_from_liquidity(
                        float(row["L_effective"]),
                        float(row["sqrt_price_current_clamped"]),
                        float(row["sqrt_pb_current"]),
                        int(row["token0_decimals"]),
                    )
                ),
                return_dtype=pl.Float64,
            ).alias("current_amount0_py"),
            pl.struct(
                [
                    "L_effective",
                    "sqrt_price_current_clamped",
                    "sqrt_pa_current",
                    "token1_decimals",
                ]
            ).map_elements(
                lambda row: float(
                    amount1_from_liquidity(
                        float(row["L_effective"]),
                        float(row["sqrt_price_current_clamped"]),
                        float(row["sqrt_pa_current"]),
                        int(row["token1_decimals"]),
                    )
                ),
                return_dtype=pl.Float64,
            ).alias("current_amount1_py"),
        )
        .with_columns(
            (
                pl.col("current_amount0_py")
                + pl.col("current_amount1_py") * pl.col("price_token1_in_token0")
            ).alias("current_deployed_principal_token0_py"),
            (
                (
                    pl.col("cum_principal_generated_amount0")
                    - pl.col("cum_principal_collected_amount0")
                ).clip(lower_bound=0.0)
                + (
                    (
                        pl.col("cum_principal_generated_amount1")
                        - pl.col("cum_principal_collected_amount1")
                    ).clip(lower_bound=0.0)
                    * pl.col("price_token1_in_token0")
                )
            ).alias("principal_owed_token0_equiv_current_py"),
            (
                pl.col("cum_principal_collected_amount0")
                + pl.col("cum_principal_collected_amount1") * pl.col("price_token1_in_token0")
            ).alias("principal_collected_token0_equiv_current_py"),
            (
                pl.col("cum_fees_amount0")
                + pl.col("cum_fees_amount1") * pl.col("price_token1_in_token0")
            ).alias("current_collected_fee_wealth_token0_py"),
            (
                (
                    pl.col("cum_fees_generated_amount0")
                    - pl.col("cum_fees_amount0")
                ).clip(lower_bound=0.0)
                + (
                    (
                        pl.col("cum_fees_generated_amount1")
                        - pl.col("cum_fees_amount1")
                    ).clip(lower_bound=0.0)
                    * pl.col("price_token1_in_token0")
                )
            ).alias("current_uncollected_fee_wealth_token0_py"),
            (
                pl.col("cum_hodl_amount0")
                + pl.col("cum_hodl_amount1") * pl.col("price_token1_in_token0")
            ).alias("hodl_value_token0_py"),
        )
        .with_columns(
            (
                pl.col("current_collected_fee_wealth_token0_py")
                + pl.col("current_uncollected_fee_wealth_token0_py")
            ).alias("current_fee_wealth_token0_py"),
            (
                pl.col("current_deployed_principal_token0_py")
                + pl.col("principal_owed_token0_equiv_current_py")
                + pl.col("principal_collected_token0_equiv_current_py")
            ).alias("current_principal_wealth_token0_py"),
        )
        .with_columns(
            (
                pl.col("current_principal_wealth_token0_py")
                + pl.col("current_fee_wealth_token0_py")
            ).alias("current_total_wealth_token0_py"),
            (
                pl.col("current_principal_wealth_token0_py")
                + pl.col("current_fee_wealth_token0_py")
                - pl.col("hodl_value_token0_py")
            ).alias("pnl_vs_hodl_token0_py"),
        )
        .join(dbt, on="token_id", how="inner")
        .with_columns(
            (
                (pl.col("current_deployed_principal_token0_py") - pl.col("current_deployed_principal_token0"))
                / pl.col("current_deployed_principal_token0").abs().clip(lower_bound=1e-12)
            ).alias("deployed_principal_rel_error"),
            (
                (
                    pl.col("principal_owed_token0_equiv_current_py")
                    - pl.col("principal_owed_token0_equiv_current")
                )
                / pl.col("principal_owed_token0_equiv_current").abs().clip(lower_bound=1e-12)
            ).alias("principal_owed_rel_error"),
            (
                (
                    pl.col("principal_collected_token0_equiv_current_py")
                    - pl.col("principal_collected_token0_equiv_current")
                )
                / pl.col("principal_collected_token0_equiv_current").abs().clip(lower_bound=1e-12)
            ).alias("principal_collected_rel_error"),
            (
                (
                    pl.col("current_collected_fee_wealth_token0_py")
                    - pl.col("current_collected_fee_wealth_token0")
                )
                / pl.col("current_collected_fee_wealth_token0").abs().clip(lower_bound=1e-12)
            ).alias("collected_fee_rel_error"),
            (
                (
                    pl.col("current_uncollected_fee_wealth_token0_py")
                    - pl.col("current_uncollected_fee_wealth_token0")
                )
                / pl.col("current_uncollected_fee_wealth_token0").abs().clip(lower_bound=1e-12)
            ).alias("uncollected_fee_rel_error"),
            (
                (pl.col("current_fee_wealth_token0_py") - pl.col("current_fee_wealth_token0"))
                / pl.col("current_fee_wealth_token0").abs().clip(lower_bound=1e-12)
            ).alias("fee_wealth_rel_error"),
            (
                (pl.col("current_total_wealth_token0_py") - pl.col("current_total_wealth_token0"))
                / pl.col("current_total_wealth_token0").abs().clip(lower_bound=1e-12)
            ).alias("wealth_rel_error"),
            (
                (pl.col("pnl_vs_hodl_token0_py") - pl.col("pnl_vs_hodl_token0"))
                / pl.col("pnl_vs_hodl_token0").abs().clip(lower_bound=1e-12)
            ).alias("pnl_vs_hodl_rel_error"),
        )
        .with_columns(
            (pl.col("wealth_rel_error").abs() <= tolerance).alias("wealth_within_tolerance"),
            (pl.col("pnl_vs_hodl_rel_error").abs() <= tolerance).alias("pnl_vs_hodl_within_tolerance"),
        )
    )
    return comparison


def summarize_terminal_comparison(comparison: pl.DataFrame) -> dict[str, float | int]:
    if comparison.is_empty():
        return {
            "matched_positions": 0,
            "wealth_within_tolerance_count": 0,
            "pnl_vs_hodl_within_tolerance_count": 0,
            "avg_abs_deployed_principal_rel_error": 0.0,
            "avg_abs_principal_owed_rel_error": 0.0,
            "avg_abs_principal_collected_rel_error": 0.0,
            "avg_abs_collected_fee_rel_error": 0.0,
            "avg_abs_uncollected_fee_rel_error": 0.0,
            "avg_abs_fee_wealth_rel_error": 0.0,
            "avg_abs_wealth_rel_error": 0.0,
            "median_abs_wealth_rel_error": 0.0,
            "avg_abs_pnl_vs_hodl_error_token0": 0.0,
            "avg_abs_pnl_vs_hodl_rel_error": 0.0,
        }
    return {
        "matched_positions": comparison.height,
        "wealth_within_tolerance_count": int(comparison["wealth_within_tolerance"].sum()),
        "pnl_vs_hodl_within_tolerance_count": int(comparison["pnl_vs_hodl_within_tolerance"].sum()),
        "avg_abs_deployed_principal_rel_error": float(comparison["deployed_principal_rel_error"].abs().mean()),
        "avg_abs_principal_owed_rel_error": float(comparison["principal_owed_rel_error"].abs().mean()),
        "avg_abs_principal_collected_rel_error": float(comparison["principal_collected_rel_error"].abs().mean()),
        "avg_abs_collected_fee_rel_error": float(comparison["collected_fee_rel_error"].abs().mean()),
        "avg_abs_uncollected_fee_rel_error": float(comparison["uncollected_fee_rel_error"].abs().mean()),
        "avg_abs_fee_wealth_rel_error": float(comparison["fee_wealth_rel_error"].abs().mean()),
        "avg_abs_wealth_rel_error": float(comparison["wealth_rel_error"].abs().mean()),
        "median_abs_wealth_rel_error": float(comparison["wealth_rel_error"].abs().median()),
        "avg_abs_pnl_vs_hodl_error_token0": float(
            (comparison["pnl_vs_hodl_token0_py"] - comparison["pnl_vs_hodl_token0"]).abs().mean()
        ),
        "avg_abs_pnl_vs_hodl_rel_error": float(comparison["pnl_vs_hodl_rel_error"].abs().mean()),
    }
