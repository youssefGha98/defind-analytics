"""EVC volatility surface: tick → moneyness bucketing, smoothing, daily output."""

from __future__ import annotations

import math
from datetime import date

import polars as pl

from core.db import ClickHouseDB
from core.position_math import tick_to_price

_LOG_1_0001 = math.log(1.0001)

_OUTPUT_SCHEMA: dict[str, pl.DataType] = {
    "pool": pl.String,
    "day": pl.Date,
    "moneyness_bucket": pl.Float64,
    "sigma_evc_raw": pl.Float64,
    "sigma_evc_smoothed": pl.Float64,
    "tick_count": pl.UInt32,
    "total_liquidity": pl.Float64,
    "rv_realized_7d": pl.Float64,
    "rv_realized_30d": pl.Float64,
}


def _empty_output() -> pl.DataFrame:
    return pl.DataFrame(schema=_OUTPUT_SCHEMA)


# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------


def _date_filter(column: str, start_date: date | None, end_date: date | None) -> str:
    parts: list[str] = []
    if start_date is not None:
        parts.append(f"{column} >= toDate('{start_date.isoformat()}')")
    if end_date is not None:
        parts.append(f"{column} <= toDate('{end_date.isoformat()}')")
    return " AND ".join(parts) if parts else "1 = 1"


def _pool_filter(column: str, pool: str | None) -> str:
    if not pool:
        return "1 = 1"
    return f"lower({column}) = lower('{pool}')"


def read_pool_decimals(db: ClickHouseDB) -> pl.DataFrame:
    query = f"""
        SELECT lower(pool) AS pool,
               toInt32(token0_decimals) AS token0_decimals,
               toInt32(token1_decimals) AS token1_decimals
        FROM {db.qualify('stg_pools')}
    """
    return db.read_query(query)


def read_sigma_evc_hourly(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
) -> pl.DataFrame:
    where = " AND ".join([
        _pool_filter("pool", pool),
        _date_filter("date", start_date, end_date),
        "sigma_evc_last IS NOT NULL",
        "tick_liquidity_end > 0",
    ])
    query = f"""
        SELECT
            lower(pool) AS pool,
            toDate(hour) AS date,
            tick,
            toFloat64(sigma_evc_last) AS sigma_evc,
            toFloat64(tick_liquidity_end) AS tick_liquidity
        FROM {db.qualify('mart_tick_sigma_evc_hourly')}
        WHERE {where}
    """
    return db.read_query(query)


def read_daily_close(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
) -> pl.DataFrame:
    where = " AND ".join([
        _pool_filter("pool", pool),
        _date_filter("date", start_date, end_date),
    ])
    query = f"""
        SELECT
            lower(pool) AS pool,
            date,
            toFloat64(close_price) AS close_price
        FROM {db.qualify('int_daily_close_dense')}
        WHERE {where}
    """
    return db.read_query(query)


def read_realized_vol(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
) -> pl.DataFrame:
    where = " AND ".join([
        _pool_filter("pool", pool),
        _date_filter("date", start_date, end_date),
    ])
    query = f"""
        SELECT
            lower(pool) AS pool,
            date,
            toFloat64(realized_vol_7d) AS rv_realized_7d,
            toFloat64(realized_vol_30d) AS rv_realized_30d
        FROM {db.qualify('mart_price_analytics_daily')}
        WHERE {where}
    """
    return db.read_query(query)


# ---------------------------------------------------------------------------
# Kernels
# ---------------------------------------------------------------------------


def tick_to_log_moneyness(
    tick: int,
    spot_price: float,
    token0_decimals: int = 0,
    token1_decimals: int = 0,
) -> float:
    """log(K/S) where K = decimal-adjusted price at tick, S = spot.

    1.0001^tick gives token1/token0 in raw units. After decimal adjustment
    (multiply by 10^(d0-d1)) we get token1-per-token0 in human units.
    Invert to get token0-per-token1, matching close_price denomination.
    """
    tick_price_t1_per_t0 = math.exp(tick * _LOG_1_0001) * 10 ** (token0_decimals - token1_decimals)
    strike = 1.0 / tick_price_t1_per_t0  # token0-per-token1, same as spot_price
    return math.log(strike / spot_price)


def assign_moneyness_bucket(log_moneyness: float, bucket_width: float = 0.05) -> float:
    """Round log-moneyness to the nearest bucket center."""
    return round(round(log_moneyness / bucket_width) * bucket_width, 10)


def build_daily_sigma_by_tick(hourly: pl.DataFrame) -> pl.DataFrame:
    """Aggregate hourly sigma_evc to daily, liquidity-weighted per tick."""
    if hourly.is_empty():
        return pl.DataFrame(schema={
            "pool": pl.String,
            "date": pl.Date,
            "tick": pl.Int32,
            "sigma_evc": pl.Float64,
            "tick_liquidity": pl.Float64,
        })

    return (
        hourly
        .with_columns(
            (pl.col("sigma_evc") * pl.col("tick_liquidity")).alias("weighted_sigma"),
        )
        .group_by(["pool", "date", "tick"])
        .agg(
            pl.col("weighted_sigma").sum().alias("weighted_sigma_sum"),
            pl.col("tick_liquidity").sum().alias("tick_liquidity"),
        )
        .with_columns(
            (pl.col("weighted_sigma_sum") / pl.col("tick_liquidity")).alias("sigma_evc"),
        )
        .drop("weighted_sigma_sum")
    )


def build_moneyness_surface(
    daily_sigma: pl.DataFrame,
    daily_close: pl.DataFrame,
    pool_decimals: pl.DataFrame,
    *,
    bucket_width: float = 0.05,
) -> pl.DataFrame:
    """Tick → moneyness bucketing with liquidity-weighted aggregation."""
    empty_schema = {
        "pool": pl.String,
        "day": pl.Date,
        "moneyness_bucket": pl.Float64,
        "sigma_evc_raw": pl.Float64,
        "tick_count": pl.UInt32,
        "total_liquidity": pl.Float64,
    }
    if daily_sigma.is_empty() or daily_close.is_empty():
        return pl.DataFrame(schema=empty_schema)

    joined = (
        daily_sigma
        .join(daily_close, on=["pool", "date"], how="inner")
        .join(pool_decimals, on="pool", how="inner")
    )

    if joined.is_empty():
        return pl.DataFrame(schema=empty_schema)

    with_moneyness = (
        joined
        .with_columns(
            pl.struct(["tick", "close_price", "token0_decimals", "token1_decimals"])
            .map_elements(
                lambda row: assign_moneyness_bucket(
                    tick_to_log_moneyness(
                        int(row["tick"]),
                        float(row["close_price"]),
                        int(row["token0_decimals"]),
                        int(row["token1_decimals"]),
                    ),
                    bucket_width,
                ),
                return_dtype=pl.Float64,
            )
            .alias("moneyness_bucket"),
        )
        .with_columns(
            (pl.col("sigma_evc") * pl.col("tick_liquidity")).alias("weighted_sigma"),
        )
    )

    return (
        with_moneyness
        .group_by(["pool", "date", "moneyness_bucket"])
        .agg(
            pl.col("weighted_sigma").sum().alias("weighted_sum"),
            pl.col("tick_liquidity").sum().alias("total_liquidity"),
            pl.len().cast(pl.UInt32).alias("tick_count"),
        )
        .with_columns(
            (pl.col("weighted_sum") / pl.col("total_liquidity")).alias("sigma_evc_raw"),
        )
        .drop("weighted_sum")
        .rename({"date": "day"})
        .select("pool", "day", "moneyness_bucket", "sigma_evc_raw", "tick_count", "total_liquidity")
        .sort(["pool", "day", "moneyness_bucket"])
    )


def smooth_surface(
    surface: pl.DataFrame,
    *,
    cross_section_window: int = 3,
    temporal_halflife_days: int = 3,
) -> pl.DataFrame:
    """Apply cross-section rolling mean then temporal EWMA smoothing.

    cross_section_window: number of neighboring buckets for rolling mean
                          (applied within each pool+day).
    temporal_halflife_days: EWMA half-life in days (applied within each
                           pool+moneyness_bucket across days).
    """
    if surface.is_empty():
        return surface.with_columns(pl.lit(None, dtype=pl.Float64).alias("sigma_evc_smoothed"))

    alpha = 1.0 - math.exp(-math.log(2.0) / temporal_halflife_days)

    # 1. Cross-section smoothing: rolling mean over neighboring buckets
    cross_smoothed = (
        surface
        .sort(["pool", "day", "moneyness_bucket"])
        .with_columns(
            pl.col("sigma_evc_raw")
            .rolling_mean(window_size=cross_section_window, center=True, min_samples=1)
            .over(["pool", "day"])
            .alias("sigma_cross"),
        )
    )

    # 2. Temporal EWMA: exponentially weighted moving average across days
    records = cross_smoothed.sort(["pool", "moneyness_bucket", "day"]).to_dicts()
    prev_key: tuple[str, float] | None = None
    prev_ewma: float = 0.0

    for row in records:
        key = (row["pool"], row["moneyness_bucket"])
        val = float(row["sigma_cross"])
        if key != prev_key:
            row["sigma_evc_smoothed"] = val
            prev_key = key
            prev_ewma = val
        else:
            ewma = alpha * val + (1.0 - alpha) * prev_ewma
            row["sigma_evc_smoothed"] = ewma
            prev_ewma = ewma

    return pl.DataFrame(records).select(
        surface.columns + ["sigma_evc_smoothed"]
    )


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def build_vol_surface(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
    bucket_width: float = 0.05,
    cross_section_window: int = 3,
    temporal_halflife_days: int = 3,
    write: bool = False,
    table_name: str = "py_vol_surface_daily",
) -> pl.DataFrame:
    hourly = read_sigma_evc_hourly(db, pool=pool, start_date=start_date, end_date=end_date)
    daily_close = read_daily_close(db, pool=pool, start_date=start_date, end_date=end_date)
    rv = read_realized_vol(db, pool=pool, start_date=start_date, end_date=end_date)
    pool_decimals = read_pool_decimals(db)

    if hourly.is_empty() or daily_close.is_empty():
        return _empty_output()

    daily_sigma = build_daily_sigma_by_tick(hourly)
    surface = build_moneyness_surface(daily_sigma, daily_close, pool_decimals, bucket_width=bucket_width)
    smoothed = smooth_surface(
        surface,
        cross_section_window=cross_section_window,
        temporal_halflife_days=temporal_halflife_days,
    )

    # Join realized vol
    result = smoothed.join(
        rv.rename({"date": "day"}),
        on=["pool", "day"],
        how="left",
    ).select(
        "pool", "day", "moneyness_bucket",
        "sigma_evc_raw", "sigma_evc_smoothed",
        "tick_count", "total_liquidity",
        "rv_realized_7d", "rv_realized_30d",
    ).sort(["pool", "day", "moneyness_bucket"])

    if write and not result.is_empty():
        if db.table_exists(table_name):
            parts: list[str] = []
            if pool:
                parts.append(_pool_filter("pool", pool))
            if start_date:
                parts.append(f"day >= toDate('{start_date.isoformat()}')")
            if end_date:
                parts.append(f"day <= toDate('{end_date.isoformat()}')")
            if parts:
                db.delete_where(table_name, " AND ".join(parts))
        db.write_table(
            result,
            table_name,
            create_if_missing=True,
            order_by=["pool", "day", "moneyness_bucket"],
        )

    return result
