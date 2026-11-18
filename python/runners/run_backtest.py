"""Runner for the parametric backtest engine."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import typer

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.db import ClickHouseDB, ClickHouseSettings
from engines.backtest_engine import (
    compare_backtest_summary_to_dbt,
    run_backtest,
    summarize_backtest_comparison,
)


def _load_scenarios(
    *,
    scenario_file: str | None,
    scenario_id: str | None,
    pool: str | None,
    start_block: int | None,
    end_block: int | None,
    tick_lower: int | None,
    tick_upper: int | None,
    capital_committed_token0: float | None,
    rebalance_strategy: str | None,
) -> list[dict[str, object]]:
    if scenario_file:
        payload = json.loads(Path(scenario_file).read_text())
        if isinstance(payload, dict):
            return [payload]
        return list(payload)
    required = {
        "pool": pool,
        "start_block": start_block,
        "end_block": end_block,
        "tick_lower": tick_lower,
        "tick_upper": tick_upper,
        "capital_committed_token0": capital_committed_token0,
    }
    missing = [name for name, value in required.items() if value is None]
    if missing:
        raise ValueError(
            "Missing scenario inputs: " + ", ".join(missing)
        )
    scenario = {
        "pool": pool,
        "start_block": start_block,
        "end_block": end_block,
        "tick_lower": tick_lower,
        "tick_upper": tick_upper,
        "capital_committed_token0": capital_committed_token0,
        "rebalance_strategy": rebalance_strategy or "none",
    }
    if scenario_id:
        scenario["scenario_id"] = scenario_id
    return [scenario]


app = typer.Typer(add_completion=False)


@app.command()
def main(
    scenario_file: str | None = typer.Option(default=None),
    scenario_id: str | None = typer.Option(default=None),
    pool: str | None = typer.Option(default=None),
    start_block: int | None = typer.Option(default=None),
    end_block: int | None = typer.Option(default=None),
    tick_lower: int | None = typer.Option(default=None),
    tick_upper: int | None = typer.Option(default=None),
    capital_committed_token0: float | None = typer.Option(default=None),
    rebalance_strategy: str = typer.Option(default="none"),
    write: bool = typer.Option(default=False),
    validate_summary: bool = typer.Option(default=False),
) -> None:
    scenarios = _load_scenarios(
        scenario_file=scenario_file,
        scenario_id=scenario_id,
        pool=pool,
        start_block=start_block,
        end_block=end_block,
        tick_lower=tick_lower,
        tick_upper=tick_upper,
        capital_committed_token0=capital_committed_token0,
        rebalance_strategy=rebalance_strategy,
    )
    db = ClickHouseDB.from_settings(ClickHouseSettings())
    results, summary = run_backtest(db, scenarios, write=write)
    print(f"results_rows={results.height}")
    print(f"summary_rows={summary.height}")
    if validate_summary:
        comparison = compare_backtest_summary_to_dbt(db, summary)
        print(summarize_backtest_comparison(comparison))
    db.close()


if __name__ == "__main__":
    app()
