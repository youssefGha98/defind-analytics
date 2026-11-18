"""Remediation v0.2 — capital-constant sweep + jump-rule audit.

Fixes from v0.1:
  - Capital is now FIXED ($1M reference). L_position is solved per (range, day)
    so the comparison is apples-to-apples on dollars at risk, not on L.
  - Adds jump-rule diagnostics: lookahead audit, autocorrelation, threshold
    sensitivity, and joint application of jump rule on each range.

All metrics computed on USDC/WETH 0.05% (only pool indexed in CH); the 0.3%
pool generalization is out of scope until that data lands.
"""
from __future__ import annotations

import sys
from datetime import date
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.db import ClickHouseDB, ClickHouseSettings

POOL = "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640"
START = date(2025, 11, 5)
END = date(2026, 5, 3)
CAPITAL_USD = 1_000_000.0  # reference capital per position


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
    df = db.read_query(sql).to_pandas()
    df["hour_ts"] = pd.to_datetime(df["hour_ts"])
    df["date"] = pd.to_datetime(df["date"]).dt.normalize()
    return df


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


def solve_L_for_capital(capital_usd: float, P0: float, Pa: float, Pb: float) -> tuple[float, float]:
    """Given target capital_USD at price P0 with range [Pa, Pb], return (L_h, capital_realized).

    Convention: close_price = USDC/WETH; sqrt_p = sqrt(close_price). Token0=USDC, token1=WETH.
    capital_USD(L) = L * [(sp - sqrt(Pa)) + (sqrt(Pb) - sp)/(sp*sqrt(Pb)) * P0]
    """
    sp = np.sqrt(P0)
    sqrt_pa = np.sqrt(Pa)
    sqrt_pb = np.sqrt(Pb)
    sp_c = max(sqrt_pa, min(sp, sqrt_pb))
    coef = (sp_c - sqrt_pa) + (sqrt_pb - sp_c) / (sp_c * sqrt_pb) * P0
    if coef <= 0:
        return 0.0, 0.0
    L_h = capital_usd / coef
    capital_realized = L_h * coef
    return L_h, capital_realized


def simulate_capital_constant(
    daily: pd.DataFrame,
    intraday: pd.DataFrame,
    *,
    half_width_pct: Optional[float],
    label: str,
    capital_usd: float = CAPITAL_USD,
) -> dict:
    """Simulate at FIXED capital with daily rebalancing.

    Each day at t we set capital_USD := target, solve L for that day's range,
    then earn fees ~ pool_fees * (L_position/L_pool) * TIR(hourly), and pay
    gc realized hourly with that L.
    """
    rows = []
    daily_local = daily.copy()
    daily_local["date"] = pd.to_datetime(daily_local["date"]).dt.normalize()
    for _, drow in daily_local.iterrows():
        d = drow["date"]
        P0 = float(drow["close_price"])
        L_pool = float(drow["l_human"])
        if half_width_pct is None:
            Pa = float(daily["close_price"].min()) * 0.5
            Pb = float(daily["close_price"].max()) * 1.5
        else:
            Pa = P0 * (1.0 - half_width_pct)
            Pb = P0 * (1.0 + half_width_pct)

        L_pos, cap_real = solve_L_for_capital(capital_usd, P0, Pa, Pb)
        if L_pos <= 0 or L_pool <= 0:
            continue
        share = L_pos / L_pool

        ih = intraday[intraday["date"] == d]
        if ih.empty:
            continue
        P_h = ih["close_price"].values
        r_h = ih["log_return_hourly"].fillna(0.0).values
        in_range_h = (P_h >= Pa) & (P_h <= Pb)
        # |Γ| for v3 active LP, in this convention = L_h / (2 * P^1.5) with P = USDC/WETH.
        abs_gamma = np.where(in_range_h, L_pos / (2.0 * np.power(P_h, 1.5)), 0.0)
        gc_h = 0.5 * abs_gamma * np.power(P_h, 2.0) * np.power(r_h, 2.0)
        gc_d = float(gc_h.sum())

        rv_d = float(np.sum(r_h * r_h))
        bv_d = 0.0
        for i in range(1, len(r_h)):
            bv_d += abs(r_h[i]) * abs(r_h[i - 1])
        bv_d *= (np.pi / 2.0)
        jump_d = max(rv_d - bv_d, 0.0)
        jump_share = jump_d / rv_d if rv_d > 0 else 0.0

        gc_diff_d = gc_d * (1.0 - jump_share)
        gc_jump_d = gc_d * jump_share

        tir = float(in_range_h.sum()) / max(len(in_range_h), 1)
        fees_pos_d = float(drow["fees_daily"]) * share * tir

        v_fr_pos = 2.0 * L_pos * np.sqrt(P0)
        leverage = v_fr_pos / cap_real if cap_real > 0 else 0.0

        rows.append({
            "date": d,
            "P0": P0,
            "Pa": Pa, "Pb": Pb,
            "L_pos": L_pos,
            "share_of_pool": share,
            "capital": cap_real,
            "v_fr_pos": v_fr_pos,
            "leverage": leverage,
            "tir": tir,
            "rv_d": rv_d,
            "bv_d": bv_d,
            "jump_share_d": jump_share,
            "fees_pos_d": fees_pos_d,
            "gc_d": gc_d,
            "gc_diff_d": gc_diff_d,
            "gc_jump_d": gc_jump_d,
            "pnl_d": fees_pos_d - gc_d,
        })

    df = pd.DataFrame(rows)
    if df.empty:
        return {"label": label, "df": df, "summary": {}}
    summary = {
        "label": label,
        "n_days": len(df),
        "tir_mean": float(df["tir"].mean()),
        "days_oor": int((df["tir"] < 1.0).sum()),
        "capital_mean": float(df["capital"].mean()),
        "L_pos_mean": float(df["L_pos"].mean()),
        "share_mean_pct": float(df["share_of_pool"].mean() * 100),
        "leverage_mean": float(df["leverage"].mean()),
        "fees_mean_d": float(df["fees_pos_d"].mean()),
        "gc_mean_d": float(df["gc_d"].mean()),
        "FGY_total": float(df["fees_pos_d"].sum() / max(df["gc_d"].sum(), 1e-9)),
        "FGY_diffusion": float(df["fees_pos_d"].sum() / max(df["gc_diff_d"].sum(), 1e-9)),
        "jump_share_pnl": float(df["gc_jump_d"].sum() / max(df["gc_d"].sum(), 1e-9)),
        "pnl_total": float(df["pnl_d"].sum()),
        "pnl_mean_d": float(df["pnl_d"].mean()),
    }
    return {"label": label, "df": df, "summary": summary}


def jump_rule_diagnostics(daily_diags: pd.DataFrame, run_df: pd.DataFrame) -> dict:
    """Audit + sensitivity for jump_intensity_lag1 > p_q_lookback_30d.

    daily_diags: DataFrame with columns [date, jump_share_d] from a chosen run
                  (the diagnostic is range-agnostic since jump_share is per-day).
    run_df:     DataFrame with [date, fees_pos_d, gc_d, pnl_d] for the run.
    """
    df = daily_diags.merge(run_df[["date", "fees_pos_d", "gc_d", "pnl_d"]], on="date", how="inner").sort_values("date")
    j = df["jump_share_d"].values
    n = len(j)
    # lookahead audit: define p75_30d strictly on past, with proper shift
    p75 = pd.Series(j).shift(1).rolling(30, min_periods=10).quantile(0.75).values
    j_lag1 = pd.Series(j).shift(1).values
    df["p_thresh_p75"] = p75
    df["j_lag1"] = j_lag1
    df["signal_skip_p75"] = (j_lag1 > p75) & np.isfinite(p75)

    # autocorrelation
    js = pd.Series(j).dropna()
    autocorrs = {f"acf_lag{k}": float(js.autocorr(lag=k)) for k in (1, 3, 7)}

    # threshold sensitivity
    sensitivity = []
    for q in [0.50, 0.60, 0.70, 0.75, 0.80, 0.90]:
        thresh = pd.Series(j).shift(1).rolling(30, min_periods=10).quantile(q).values
        skip = (j_lag1 > thresh) & np.isfinite(thresh)
        # Rule applied: pnl_active when not skipping, 0 when skipping
        pnl_rule = np.where(skip, 0.0, df["pnl_d"].values).sum()
        pnl_baseline = float(df["pnl_d"].sum())
        sensitivity.append({
            "quantile": q,
            "n_skipped": int(skip.sum()),
            "pnl_baseline": pnl_baseline,
            "pnl_with_rule": float(pnl_rule),
            "savings_vs_baseline": float(pnl_rule - pnl_baseline),
        })
    return {
        "n_days": n,
        "lookahead_check": "p75 computed via shift(1).rolling(30).quantile(0.75) — strictly causal.",
        "autocorrelations": autocorrs,
        "sensitivity": pd.DataFrame(sensitivity),
        "df_with_signal": df,
    }


def main() -> None:
    db = ClickHouseDB.from_settings(ClickHouseSettings())
    print(f"Pool: {POOL[:10]}... | Window: {START} → {END} | Capital fixed = ${CAPITAL_USD:,.0f}")
    daily = load_daily(db)
    intraday = load_intraday(db)
    print(f"daily: {len(daily)} rows | intraday: {len(intraday)} rows\n")
    db.close()

    runs = [
        simulate_capital_constant(daily, intraday, half_width_pct=0.03, label="±3%  daily-rebal"),
        simulate_capital_constant(daily, intraday, half_width_pct=0.05, label="±5%  daily-rebal"),
        simulate_capital_constant(daily, intraday, half_width_pct=0.10, label="±10% daily-rebal"),
        simulate_capital_constant(daily, intraday, half_width_pct=0.20, label="±20% daily-rebal"),
        simulate_capital_constant(daily, intraday, half_width_pct=None, label="fitted-wide"),
    ]

    print("=" * 124)
    print(f"§A. Capital-constant sweep — capital fixed at ${CAPITAL_USD:,.0f} per range, daily rebal")
    print("=" * 124)
    print(f"{'label':24s} {'TIR%':>5s} {'OOR':>4s} {'cap$':>10s} {'lev×':>6s} {'L_pos':>10s} {'share%':>7s} {'fμ$':>9s} {'gcμ$':>9s} {'FGY':>6s} {'FGYd':>6s} {'PnL_Σ':>14s}")
    print("-" * 124)
    for r in runs:
        s = r["summary"]
        if not s:
            continue
        print(
            f"{s['label']:24s} "
            f"{s['tir_mean']*100:5.1f} "
            f"{s['days_oor']:>4d} "
            f"{s['capital_mean']:10,.0f} "
            f"{s['leverage_mean']:6.2f} "
            f"{s['L_pos_mean']:10,.4f} "
            f"{s['share_mean_pct']:6.3f}% "
            f"{s['fees_mean_d']:9,.0f} "
            f"{s['gc_mean_d']:9,.0f} "
            f"{s['FGY_total']:6.3f} "
            f"{s['FGY_diffusion']:6.3f} "
            f"{s['pnl_total']:14,.0f}"
        )
    print("=" * 124)

    # Jump rule diagnostics — pick ±10% daily-rebal as the reference
    ref_run = next(r for r in runs if r["label"].startswith("±10%"))
    daily_diags = ref_run["df"][["date", "jump_share_d"]]
    run_df = ref_run["df"][["date", "fees_pos_d", "gc_d", "pnl_d"]]
    diag = jump_rule_diagnostics(daily_diags, run_df)

    print(f"\n§B. Jump-rule diagnostics (reference run: {ref_run['label']})")
    print(f"  Lookahead audit: {diag['lookahead_check']}")
    print(f"  Jump-intensity autocorrelations:")
    for k, v in diag["autocorrelations"].items():
        print(f"    {k}: {v:+.4f}")
    print(f"\n  Threshold sensitivity (skip day if jump_intensity_lag1 > p_q_lookback_30d):")
    print(diag["sensitivity"].to_string(index=False))

    # Apply each threshold across each range to get a synthesis matrix
    print("\n§C. Synthesis — PnL_Σ at capital=${0:,.0f}, with and without jump_rule(p75)".format(CAPITAL_USD))
    matrix = []
    for r in runs:
        if not r["summary"]:
            continue
        df = r["df"].copy()
        # apply jump_rule using p75 from the per-day jump_share series
        j = df["jump_share_d"].values
        j_lag1 = pd.Series(j).shift(1).values
        p75 = pd.Series(j).shift(1).rolling(30, min_periods=10).quantile(0.75).values
        skip = (j_lag1 > p75) & np.isfinite(p75)
        pnl_baseline = float(df["pnl_d"].sum())
        pnl_with_rule = float(np.where(skip, 0.0, df["pnl_d"].values).sum())
        matrix.append({
            "range": r["summary"]["label"],
            "TIR%": r["summary"]["tir_mean"] * 100,
            "lev×": r["summary"]["leverage_mean"],
            "FGY": r["summary"]["FGY_total"],
            "FGYd": r["summary"]["FGY_diffusion"],
            "PnL_baseline": pnl_baseline,
            "PnL_with_jump_rule": pnl_with_rule,
            "Δ_savings": pnl_with_rule - pnl_baseline,
            "n_skipped": int(skip.sum()),
        })
    print(pd.DataFrame(matrix).to_string(index=False))


if __name__ == "__main__":
    main()
