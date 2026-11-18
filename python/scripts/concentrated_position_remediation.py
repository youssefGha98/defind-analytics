"""Remediation: daily-rebalanced concentrated v3 positions vs fitted-wide.

Fix: in this codebase `close_price` = USDC per WETH (~$3000), so
`sqrt_p = sqrt(close_price)` is the inverse of v3's native sqrt(P_v3).
The v3 amount formulas must therefore be applied with token0/token1 swapped:

    amount_USDC (token0)         = L_h * (sp_clamped - sqrt(Pa))
    amount_WETH (token1)         = L_h * (sqrt(Pb) - sp_clamped) / (sp_clamped * sqrt(Pb))
    capital_USD                  = amount_USDC + amount_WETH * close_price

For full range Pa->0, Pb->inf this reduces to capital = 2 * L_h * sqrt(close_price)
which matches the gsr_engine convention (TVL_FR_usd = 2 * L_h * sqrt_p).
"""
from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.db import ClickHouseDB, ClickHouseSettings

POOL = "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640"
START = date(2025, 11, 5)
END = date(2026, 5, 3)


def load_intraday(db: ClickHouseDB) -> pd.DataFrame:
    sql = f"""
    SELECT
        date,
        hour AS hour_ts,
        open_price, high_price, low_price, close_price,
        log_return_hourly
    FROM mart_price_intraday
    WHERE lower(pool) = lower('{POOL}')
      AND date BETWEEN toDate('{START}') AND toDate('{END}')
    ORDER BY hour
    """
    return db.read_query(sql).to_pandas()


def load_daily(db: ClickHouseDB) -> pd.DataFrame:
    sql = f"""
    SELECT
        c.date AS date,
        c.close_price AS close_price,
        toFloat64(al.active_liquidity) AS l_active_raw,
        atv.active_tvl_token0 AS active_tvl_usd,
        v.fees_token0_equiv AS fees_daily,
        v.volume_token0_equiv AS volume_daily,
        p.token0_decimals AS d0,
        p.token1_decimals AS d1
    FROM int_daily_close_dense c
    INNER JOIN int_active_liquidity_daily al
        ON al.pool = c.pool AND al.date = c.date
    INNER JOIN int_active_tvl_daily atv
        ON atv.pool = c.pool AND atv.date = c.date
    INNER JOIN mart_volume_daily v
        ON v.pool = c.pool AND v.date = c.date
    INNER JOIN stg_pools p ON p.pool = c.pool
    WHERE lower(c.pool) = lower('{POOL}')
      AND c.date BETWEEN toDate('{START}') AND toDate('{END}')
    ORDER BY c.date
    """
    df = db.read_query(sql).to_pandas()
    df["l_human"] = df["l_active_raw"] / (10.0 ** ((df["d0"] + df["d1"]) / 2.0))
    df["sqrt_p"] = np.sqrt(df["close_price"])
    df["tvl_fr_usd"] = 2.0 * df["l_human"] * df["sqrt_p"]
    return df


def amounts_in_range(L_h: float, sp: float, sqrt_pa: float, sqrt_pb: float, close_price: float) -> tuple[float, float, float]:
    """Return (amount_token0_usdc, amount_token1_weth, capital_usd) for one observation.

    close_price = USDC per WETH; sp = sqrt(close_price); Pa, Pb in close_price units.
    """
    sp_c = max(sqrt_pa, min(sp, sqrt_pb))
    amount_usdc = L_h * (sp_c - sqrt_pa)
    amount_weth = L_h * (sqrt_pb - sp_c) / (sp_c * sqrt_pb)
    capital = amount_usdc + amount_weth * close_price
    return amount_usdc, amount_weth, capital


def simulate_position(
    daily: pd.DataFrame,
    intraday: pd.DataFrame,
    *,
    half_width_pct: float | None,
    label: str,
) -> dict:
    """Simulate a daily-rebalanced concentrated position.

    half_width_pct=0.10 means range = [0.9*P, 1.1*P], rebalanced at start of each day.
    half_width_pct=None means fitted-wide (range = [min(close)*0.5, max(close)*1.5]).

    Returns dict of daily series + summary stats.
    """
    pool_l = daily["l_human"].values  # pool active L per day
    pool_share = 1.0  # we set position L = pool active L (apples-to-apples)

    out_rows = []
    for _, drow in daily.iterrows():
        d = drow["date"]
        P0 = float(drow["close_price"])  # opening price for the day = close of prior day
        L_h = float(drow["l_human"]) * pool_share

        if half_width_pct is None:
            # Fitted-wide: span the full window's price extremes with 50% headroom.
            Pa = float(daily["close_price"].min()) * 0.5
            Pb = float(daily["close_price"].max()) * 1.5
        else:
            Pa = P0 * (1.0 - half_width_pct)
            Pb = P0 * (1.0 + half_width_pct)

        sqrt_pa = np.sqrt(Pa)
        sqrt_pb = np.sqrt(Pb)
        # Capital deployed at start of day, computed at opening price.
        _, _, capital_open = amounts_in_range(L_h, np.sqrt(P0), sqrt_pa, sqrt_pb, P0)

        # Intraday integration of |Gamma|*P^2*r^2 / 2, gated on in-range.
        ih = intraday[intraday["date"] == pd.Timestamp(d).date()] if "date" in intraday.columns else pd.DataFrame()
        if ih.empty:
            ih = intraday[intraday["hour_ts"].dt.date == d]
        if ih.empty:
            continue

        P_h = ih["close_price"].values
        r_h = ih["log_return_hourly"].fillna(0.0).values
        in_range_h = (P_h >= Pa) & (P_h <= Pb)
        # |Γ| for v3 concentrated position when active = L_h / (2 * P^1.5);
        # here P = close_price (USDC/WETH), and gamma_cost is in USD via L_h * sqrt(P) being USD.
        # Standard formula: dV ≈ -0.5 * |Γ| * dP^2, |Γ| = L / (2 * sqrt(P)^3) for v3 active LP
        abs_gamma = np.where(in_range_h, L_h / (2.0 * np.power(P_h, 1.5)), 0.0)
        gc_realized_h = 0.5 * abs_gamma * np.power(P_h, 2.0) * np.power(r_h, 2.0)
        gc_realized_d = float(gc_realized_h.sum())

        # Diffusion vs jump split via daily BV (excluding the hour with max |r|).
        rv_d = float(np.sum(r_h * r_h))
        # Bipower variation
        bv_d = 0.0
        for i in range(1, len(r_h)):
            bv_d += abs(r_h[i]) * abs(r_h[i - 1])
        bv_d *= (np.pi / 2.0)
        jump_d = max(rv_d - bv_d, 0.0)
        jump_share = jump_d / rv_d if rv_d > 0 else 0.0
        diff_share = 1.0 - jump_share
        gc_diff_d = gc_realized_d * diff_share
        gc_jump_d = gc_realized_d * jump_share

        # Time-in-range fraction (hourly granularity)
        tir = float(in_range_h.sum()) / max(len(in_range_h), 1)

        # Position fees: pool fees * (L_position / L_pool_active) gated on TIR.
        # We're using L_position = L_pool_active, but TIR < 1 means position earned only when in range.
        # Approximation: fees_position = fees_pool_daily * tir (since L is the same).
        fees_pos_d = float(drow["fees_daily"]) * tir

        # Capital-weighted V_FR (full-range equivalent of THIS position, ignoring concentration)
        # V_FR_pos = 2 * L_h * sqrt(P)
        v_fr_d = 2.0 * L_h * np.sqrt(P0)
        leverage_d = v_fr_d / capital_open if capital_open > 0 else 0.0

        out_rows.append({
            "date": d,
            "P0": P0,
            "Pa": Pa, "Pb": Pb,
            "L_h": L_h,
            "capital_open": capital_open,
            "v_fr_pos": v_fr_d,
            "leverage": leverage_d,
            "tir": tir,
            "rv_d": rv_d, "bv_d": bv_d, "jump_share_d": jump_share,
            "fees_pos_d": fees_pos_d,
            "gc_realized_d": gc_realized_d,
            "gc_diff_d": gc_diff_d,
            "gc_jump_d": gc_jump_d,
            "pnl_d": fees_pos_d - gc_realized_d,
        })

    df = pd.DataFrame(out_rows)
    if df.empty:
        return {"label": label, "df": df, "summary": {}}

    summary = {
        "label": label,
        "n_days": len(df),
        "tir_mean": float(df["tir"].mean()),
        "days_oor": int((df["tir"] < 1.0).sum()),
        "days_fully_oor": int((df["tir"] == 0.0).sum()),
        "capital_mean_usd": float(df["capital_open"].mean()),
        "v_fr_mean_usd": float(df["v_fr_pos"].mean()),
        "leverage_mean": float(df["leverage"].mean()),
        "fees_mean_d": float(df["fees_pos_d"].mean()),
        "gc_mean_d": float(df["gc_realized_d"].mean()),
        "gc_diff_mean_d": float(df["gc_diff_d"].mean()),
        "gc_jump_mean_d": float(df["gc_jump_d"].mean()),
        "FGY_total": float(df["fees_pos_d"].sum() / max(df["gc_realized_d"].sum(), 1e-9)),
        "FGY_diffusion": float(df["fees_pos_d"].sum() / max(df["gc_diff_d"].sum(), 1e-9)),
        "pnl_total": float(df["pnl_d"].sum()),
        "pnl_mean_d": float(df["pnl_d"].mean()),
        "jump_share_pnl": float(df["gc_jump_d"].sum() / max(df["gc_realized_d"].sum(), 1e-9)),
    }
    return {"label": label, "df": df, "summary": summary}


def main() -> None:
    db = ClickHouseDB.from_settings(ClickHouseSettings())
    print(f"Loading daily + intraday for pool {POOL[:10]}... [{START} → {END}]")
    daily = load_daily(db)
    intraday = load_intraday(db)
    intraday["hour_ts"] = pd.to_datetime(intraday["hour_ts"])
    if "date" in intraday.columns:
        intraday["date"] = pd.to_datetime(intraday["date"]).dt.date
    print(f"  daily: {len(daily)} rows, intraday: {len(intraday)} rows")
    db.close()

    runs = [
        simulate_position(daily, intraday, half_width_pct=0.03, label="±3% daily-rebal"),
        simulate_position(daily, intraday, half_width_pct=0.05, label="±5% daily-rebal"),
        simulate_position(daily, intraday, half_width_pct=0.10, label="±10% daily-rebal"),
        simulate_position(daily, intraday, half_width_pct=0.20, label="±20% daily-rebal"),
        simulate_position(daily, intraday, half_width_pct=None, label="fitted-wide [0.5×min, 1.5×max]"),
    ]

    print("\n" + "=" * 110)
    print(f"{'label':32s} {'TIR%':>5s} {'OOR':>4s} {'cap$M':>10s} {'lev×':>6s} {'FGY':>6s} {'FGYd':>6s} {'gcμ$':>10s} {'PnLΣ$':>14s}")
    print("=" * 110)
    for r in runs:
        s = r["summary"]
        if not s:
            print(f"{r['label']:32s} (no data)")
            continue
        print(
            f"{s['label']:32s} "
            f"{s['tir_mean']*100:5.1f} "
            f"{s['days_oor']:>4d} "
            f"{s['capital_mean_usd']/1e6:10.2f} "
            f"{s['leverage_mean']:6.2f} "
            f"{s['FGY_total']:6.3f} "
            f"{s['FGY_diffusion']:6.3f} "
            f"{s['gc_mean_d']:10,.0f} "
            f"{s['pnl_total']:14,.0f}"
        )
    print("=" * 110)
    print("Notes: cap = mean opening capital_USD; lev = V_FR_pos / capital (concentration leverage);")
    print("       FGY = Σfees/Σgc; FGYd = Σfees/Σgc_diff. PnL = Σ(fees - gc).")
    print("       Position L = pool active L per day (apples-to-apples).")


if __name__ == "__main__":
    main()
