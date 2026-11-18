"""Runner for the Gamma Sharpe Ratio (GSR) engine."""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

import typer

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.db import ClickHouseDB, ClickHouseSettings
from engines.gsr_engine import run_pool_gsr, summarize_gsr

app = typer.Typer(add_completion=False)


@app.command()
def main(
    pool: str = typer.Option(..., help="Pool address (lowercase ok)"),
    start_date: str = typer.Option(..., help="YYYY-MM-DD"),
    end_date: str = typer.Option(..., help="YYYY-MM-DD"),
    write: bool = typer.Option(default=False, help="Persist into py_pool_gsr_daily"),
) -> None:
    sd = date.fromisoformat(start_date)
    ed = date.fromisoformat(end_date)
    db = ClickHouseDB.from_settings(ClickHouseSettings())
    gsr = run_pool_gsr(db, pool=pool, start_date=sd, end_date=ed, write=write)
    print(f"rows={gsr.height}")
    if not gsr.is_empty():
        summary = summarize_gsr(gsr)
        for k, v in summary.items():
            print(f"  {k:<28s}: {v}")
    db.close()


if __name__ == "__main__":
    app()
