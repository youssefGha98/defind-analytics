"""Sequential swap-by-swap LVR engine."""

from __future__ import annotations

from datetime import date

import polars as pl

from core.db import ClickHouseDB


_LVR_PER_SWAP_SCHEMA: dict[str, pl.DataType] = {
    "pool": pl.String,
    "tx_hash": pl.String,
    "log_index": pl.UInt32,
    "block_number": pl.UInt64,
    "block_time": pl.Datetime("us"),
    "sqrt_price_before": pl.Float64,
    "sqrt_price_after": pl.Float64,
    "liquidity_active": pl.Float64,
    "lvr": pl.Float64,
    "fee_amount": pl.Float64,
}

_LVR_DAILY_SCHEMA: dict[str, pl.DataType] = {
    "pool": pl.String,
    "day": pl.Date,
    "lvr_total": pl.Float64,
    "fees_total": pl.Float64,
    "fee_lvr_ratio": pl.Float64,
    "swap_count": pl.UInt32,
}


def _empty_lvr_per_swap() -> pl.DataFrame:
    return pl.DataFrame(schema=_LVR_PER_SWAP_SCHEMA)


def _empty_lvr_daily() -> pl.DataFrame:
    return pl.DataFrame(schema=_LVR_DAILY_SCHEMA)


def _date_filter(column: str, start_date: date | None, end_date: date | None) -> str:
    predicates: list[str] = []
    if start_date is not None:
        predicates.append(f"toDate({column}) >= toDate('{start_date.isoformat()}')")
    if end_date is not None:
        predicates.append(f"toDate({column}) <= toDate('{end_date.isoformat()}')")
    return " AND ".join(predicates) if predicates else "1 = 1"


def _pool_filter(column: str, pool: str | None) -> str:
    if not pool:
        return "1 = 1"
    return f"lower({column}) = lower('{pool}')"


def _write_filter(
    *,
    pool: str | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
    day_column: str,
) -> str:
    predicates: list[str] = []
    if pool:
        predicates.append(_pool_filter("pool", pool))
    if start_date is not None:
        predicates.append(f"{day_column} >= toDate('{start_date.isoformat()}')")
    if end_date is not None:
        predicates.append(f"{day_column} <= toDate('{end_date.isoformat()}')")
    return " AND ".join(predicates) if predicates else "1 = 1"


def _read_lvr_inputs(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
) -> pl.DataFrame:
    where = " AND ".join(
        [
            _pool_filter("se.pool", pool),
            _date_filter("se.block_time", start_date, end_date),
        ]
    )
    query = f"""
        SELECT
            lower(se.pool) AS pool,
            sw.tx_hash AS tx_hash,
            toUInt32(se.log_index) AS log_index,
            toUInt64(se.block_number) AS block_number,
            se.block_time AS block_time,
            se.tick_before AS tick_before,
            se.tick_after AS tick_after,
            toFloat64(se.price_before) AS price_before,
            toFloat64(se.active_liquidity_at_swap) AS liquidity_active,
            toFloat64(se.price_after) AS price_after,
            toFloat64(se.fees_generated_token0_equiv) AS fee_amount_token0,
            p.token0_decimals AS token0_decimals,
            p.token1_decimals AS token1_decimals
        FROM {db.qualify('int_swaps_enriched')} se
        INNER JOIN {db.qualify('stg_swaps')} sw
            ON sw.pool = se.pool
            AND sw.block_number = se.block_number
            AND toUInt64(sw.log_index) = toUInt64(se.log_index)
        INNER JOIN {db.qualify('stg_pools')} p
            ON p.pool = se.pool
        WHERE {where}
        ORDER BY pool, block_number, log_index
    """
    frame = db.read_query(query)
    if frame.is_empty():
        return pl.DataFrame(
            schema={
                "pool": pl.String,
                "tx_hash": pl.String,
                "log_index": pl.UInt32,
                "block_number": pl.UInt64,
                "block_time": pl.Datetime("us"),
                "tick_before": pl.Int32,
                "tick_after": pl.Int32,
                "price_before": pl.Float64,
                "liquidity_active": pl.Float64,
                "price_after": pl.Float64,
                "fee_amount_token0": pl.Float64,
                "token0_decimals": pl.Int64,
                "token1_decimals": pl.Int64,
            }
        )
    return frame


def build_lvr_per_swap(swaps: pl.DataFrame) -> pl.DataFrame:
    if swaps.is_empty():
        return _empty_lvr_per_swap()

    cleaned = (
        swaps.filter(
            pl.col("tick_before").is_not_null()
            & pl.col("tick_after").is_not_null()
            & (pl.col("liquidity_active").cast(pl.Float64) >= 0.0)
            & (pl.col("price_before").cast(pl.Float64) > 0.0)
            & (pl.col("price_after").cast(pl.Float64) > 0.0)
        )
        .with_columns(
            pl.col("tick_before").cast(pl.Int32),
            pl.col("tick_after").cast(pl.Int32),
            pl.col("liquidity_active").cast(pl.Float64),
            pl.col("price_before").cast(pl.Float64),
            pl.col("price_after").cast(pl.Float64),
            pl.col("fee_amount_token0").cast(pl.Float64),
            pl.col("token0_decimals").cast(pl.Int64),
            pl.col("token1_decimals").cast(pl.Int64),
        )
    )

    if cleaned.is_empty():
        return _empty_lvr_per_swap()

    return (
        cleaned.with_columns(
            pl.col("price_before").sqrt().alias("sqrt_price_before"),
            pl.col("price_after").sqrt().alias("sqrt_price_after"),
            (
                pl.col("liquidity_active")
                / (
                    pl.lit(10.0).pow(
                        (pl.col("token0_decimals") + pl.col("token1_decimals")).cast(pl.Float64) / 2.0
                    )
                )
            ).alias("liquidity_human"),
        )
        .with_columns(
            # LVR per swap in token0_human (USDC for USDC/WETH).
            #
            # Derivation: for a full-range LP active over a price move ε = Δp/p (small),
            #   V_HODL(p₁) - V_LP(p₁) = L_h × √p × ε² / 4   (full-range, small move)
            # Substituting Δsqrt(p) ≈ √p × ε/2  →  Δsqrt² ≈ p × ε²/4  →  ε² = 4 × Δsqrt²/p
            #   LVR ≈ L_h × √p × (4 Δsqrt²/p) / 4 = L_h × Δsqrt² / √p
            # so the divisor is √p_avg, NOT 2.
            #
            # The previous formula `L_h × Δsqrt² / 2` was wrong by a factor √p / 2,
            # which equals ~23× for USDC/WETH @ $2150. Confirmed numerically against
            # closed-form V_HODL - V_LP on tiny (0.1%) and large (49%) test swaps.
            (
                pl.col("liquidity_human")
                * (pl.col("sqrt_price_after") - pl.col("sqrt_price_before")).pow(2)
                / ((pl.col("sqrt_price_before") + pl.col("sqrt_price_after")) / 2.0)
            ).alias("lvr"),
            pl.col("fee_amount_token0").alias("fee_amount"),
        )
        .select(
            "pool",
            "tx_hash",
            "log_index",
            "block_number",
            "block_time",
            "sqrt_price_before",
            "sqrt_price_after",
            "liquidity_active",
            "lvr",
            "fee_amount",
        )
        .sort(["pool", "block_number", "log_index"])
    )


def build_lvr_daily(lvr_per_swap: pl.DataFrame) -> pl.DataFrame:
    if lvr_per_swap.is_empty():
        return _empty_lvr_daily()

    return (
        lvr_per_swap.with_columns(pl.col("block_time").dt.date().alias("day"))
        .group_by(["pool", "day"])
        .agg(
            pl.col("lvr").sum().alias("lvr_total"),
            pl.col("fee_amount").sum().alias("fees_total"),
            pl.len().cast(pl.UInt32).alias("swap_count"),
        )
        .with_columns(
            pl.when(pl.col("lvr_total") > 0)
            .then(pl.col("fees_total") / pl.col("lvr_total"))
            .otherwise(None)
            .alias("fee_lvr_ratio")
        )
        .select("pool", "day", "lvr_total", "fees_total", "fee_lvr_ratio", "swap_count")
        .sort(["pool", "day"])
    )


def summarize_lvr_daily(lvr_daily: pl.DataFrame) -> dict[str, float | int | str | None]:
    if lvr_daily.is_empty():
        return {
            "pool_count": 0,
            "day_count": 0,
            "swap_count_total": 0,
            "lvr_total": 0.0,
            "fees_total": 0.0,
            "fee_lvr_ratio_overall": None,
        }
    lvr_total = float(lvr_daily.get_column("lvr_total").sum())
    fees_total = float(lvr_daily.get_column("fees_total").sum())
    return {
        "pool_count": int(lvr_daily.get_column("pool").n_unique()),
        "day_count": int(lvr_daily.height),
        "swap_count_total": int(lvr_daily.get_column("swap_count").sum()),
        "lvr_total": lvr_total,
        "fees_total": fees_total,
        "fee_lvr_ratio_overall": None if lvr_total == 0 else fees_total / lvr_total,
    }


def validate_fee_lvr_ratio(
    lvr_daily: pl.DataFrame,
    *,
    min_ratio: float = 1.0,
    max_ratio: float = 1.5,
) -> dict[str, float | int | None]:
    if lvr_daily.is_empty():
        return {
            "days_in_range": 0,
            "days_out_of_range": 0,
            "avg_fee_lvr_ratio": None,
            "median_fee_lvr_ratio": None,
        }
    non_null = lvr_daily.filter(pl.col("fee_lvr_ratio").is_not_null())
    if non_null.is_empty():
        return {
            "days_in_range": 0,
            "days_out_of_range": 0,
            "avg_fee_lvr_ratio": None,
            "median_fee_lvr_ratio": None,
        }
    in_range = non_null.filter(
        (pl.col("fee_lvr_ratio") >= min_ratio) & (pl.col("fee_lvr_ratio") <= max_ratio)
    )
    return {
        "days_in_range": int(in_range.height),
        "days_out_of_range": int(non_null.height - in_range.height),
        "avg_fee_lvr_ratio": float(non_null.get_column("fee_lvr_ratio").mean()),
        "median_fee_lvr_ratio": float(non_null.get_column("fee_lvr_ratio").median()),
    }


def run_lvr(
    db: ClickHouseDB,
    *,
    pool: str | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
    write: bool = False,
    per_swap_table: str = "py_lvr_per_swap",
    daily_table: str = "py_lvr_daily",
) -> tuple[pl.DataFrame, pl.DataFrame]:
    swaps = _read_lvr_inputs(
        db,
        pool=pool,
        start_date=start_date,
        end_date=end_date,
    )
    lvr_per_swap = build_lvr_per_swap(swaps)
    lvr_daily = build_lvr_daily(lvr_per_swap)
    if write:
        if not lvr_per_swap.is_empty():
            if db.table_exists(per_swap_table):
                db.delete_where(
                    per_swap_table,
                    _write_filter(
                        pool=pool,
                        start_date=start_date,
                        end_date=end_date,
                        day_column="toDate(block_time)",
                    ),
                )
            db.write_table(
                lvr_per_swap,
                per_swap_table,
                create_if_missing=True,
                order_by=["pool", "block_number", "log_index"],
            )
        if not lvr_daily.is_empty():
            if db.table_exists(daily_table):
                db.delete_where(
                    daily_table,
                    _write_filter(
                        pool=pool,
                        start_date=start_date,
                        end_date=end_date,
                        day_column="day",
                    ),
                )
            db.write_table(
                lvr_daily,
                daily_table,
                create_if_missing=True,
                order_by=["pool", "day"],
            )
    return lvr_per_swap, lvr_daily
