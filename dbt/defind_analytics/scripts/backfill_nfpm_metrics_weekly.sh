#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DBT_BIN="${DBT_DIR}/../../.venv/bin/dbt"

FEE_MODELS=(
  int_nfpm_position_fee_daily
  int_nfpm_position_fee_summary
)

TIR_MODELS=(
  int_nfpm_position_time_in_range_daily
  int_nfpm_position_time_in_range_summary
)

PNL_MODELS=(
  mart_nfpm_position_pnl_current
)

TARGET="local"
START_DATE=""
END_DATE=""
LOOKBACK_DAYS="3"
FULL_REFRESH_FIRST="0"
RUN_TESTS_AT_END="0"
DRY_RUN="0"

run_dbt_phase() {
  local full_refresh="$1"
  shift
  local vars_json="$1"
  shift
  local models=("$@")

  local cmd=(
    "${DBT_BIN}" run
    --target "${TARGET}"
  )

  if [[ "${full_refresh}" == "1" ]]; then
    cmd+=(--full-refresh)
  fi

  cmd+=(
    --select "${models[@]}"
    --vars "${vars_json}"
  )

  run_cmd "${cmd[@]}"
}

usage() {
  cat <<'EOF'
Usage:
  bash dbt/defind_analytics/scripts/backfill_nfpm_metrics_weekly.sh \
    --start-date YYYY-MM-DD \
    --end-date YYYY-MM-DD \
    [--target local] \
    [--lookback-days 3] \
    [--full-refresh-first] \
    [--run-tests-at-end] \
    [--dry-run]

What it does:
  - backfills NFPM fee / time-in-range / pnl models week by week
  - passes nfpm_metrics_start_date / nfpm_metrics_end_date vars to dbt
  - optionally does --full-refresh on the first weekly chunk only
  - optionally runs a final targeted dbt test pack once all chunks are done

Examples:
  bash dbt/defind_analytics/scripts/backfill_nfpm_metrics_weekly.sh \
    --start-date 2021-05-05 \
    --end-date 2021-06-30

  bash dbt/defind_analytics/scripts/backfill_nfpm_metrics_weekly.sh \
    --start-date 2021-05-05 \
    --end-date 2021-06-30 \
    --full-refresh-first \
    --run-tests-at-end

  bash dbt/defind_analytics/scripts/backfill_nfpm_metrics_weekly.sh \
    --start-date 2021-05-05 \
    --end-date 2021-05-31 \
    --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-date)
      START_DATE="${2:-}"
      shift 2
      ;;
    --end-date)
      END_DATE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --lookback-days)
      LOOKBACK_DAYS="${2:-}"
      shift 2
      ;;
    --full-refresh-first)
      FULL_REFRESH_FIRST="1"
      shift
      ;;
    --run-tests-at-end)
      RUN_TESTS_AT_END="1"
      shift
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${START_DATE}" || -z "${END_DATE}" ]]; then
  echo "Both --start-date and --end-date are required." >&2
  usage
  exit 1
fi

if [[ ! -x "${DBT_BIN}" ]]; then
  echo "dbt binary not found or not executable: ${DBT_BIN}" >&2
  exit 1
fi

if ! date -d "${START_DATE}" +%F >/dev/null 2>&1; then
  echo "Invalid --start-date: ${START_DATE}" >&2
  exit 1
fi

if ! date -d "${END_DATE}" +%F >/dev/null 2>&1; then
  echo "Invalid --end-date: ${END_DATE}" >&2
  exit 1
fi

if [[ "$(date -d "${START_DATE}" +%s)" -gt "$(date -d "${END_DATE}" +%s)" ]]; then
  echo "--start-date must be <= --end-date" >&2
  exit 1
fi

if ! [[ "${LOOKBACK_DAYS}" =~ ^[0-9]+$ ]]; then
  echo "--lookback-days must be a non-negative integer" >&2
  exit 1
fi

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] %q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

current_start="${START_DATE}"
chunk_index=0

echo "Backfill NFPM metrics"
echo "  target: ${TARGET}"
echo "  start : ${START_DATE}"
echo "  end   : ${END_DATE}"
echo "  lookback_days: ${LOOKBACK_DAYS}"
echo "  full_refresh_first: ${FULL_REFRESH_FIRST}"
echo "  run_tests_at_end  : ${RUN_TESTS_AT_END}"
echo "  dry_run           : ${DRY_RUN}"
echo

while [[ "$(date -d "${current_start}" +%s)" -le "$(date -d "${END_DATE}" +%s)" ]]; do
  chunk_end="$(date -d "${current_start} +6 days" +%F)"
  if [[ "$(date -d "${chunk_end}" +%s)" -gt "$(date -d "${END_DATE}" +%s)" ]]; then
    chunk_end="${END_DATE}"
  fi

  vars_json=$(printf '{"nfpm_metrics_start_date":"%s","nfpm_metrics_end_date":"%s","nfpm_metrics_incremental_lookback_days":%s}' \
    "${current_start}" \
    "${chunk_end}" \
    "${LOOKBACK_DAYS}")

  echo "==> Chunk $((chunk_index + 1)) : ${current_start} -> ${chunk_end}"
  if [[ "${chunk_index}" == "0" && "${FULL_REFRESH_FIRST}" == "1" ]]; then
    run_dbt_phase "1" "${vars_json}" "${FEE_MODELS[@]}"
  else
    run_dbt_phase "0" "${vars_json}" "${FEE_MODELS[@]}"
  fi
  run_dbt_phase "0" "${vars_json}" "${TIR_MODELS[@]}"
  run_dbt_phase "0" "${vars_json}" "${PNL_MODELS[@]}"
  echo

  current_start="$(date -d "${chunk_end} +1 day" +%F)"
  chunk_index=$((chunk_index + 1))
done

if [[ "${RUN_TESTS_AT_END}" == "1" ]]; then
  echo "==> Final targeted tests"
  run_cmd \
    "${DBT_BIN}" test \
    --target "${TARGET}" \
    --select \
    test_int_nfpm_position_fee_daily_unique_token_id_date \
    test_int_nfpm_position_fee_summary_unique_token_id \
    test_int_nfpm_position_fee_summary_reconciles_daily \
    test_int_nfpm_position_time_in_range_daily_unique_token_id_date \
    test_int_nfpm_position_time_in_range_summary_unique_token_id \
    test_int_nfpm_position_time_in_range_summary_reconciles_daily \
    test_mart_nfpm_position_pnl_current_fee_wealth_reconciles \
    test_mart_nfpm_position_pnl_current_unique_token_id \
    test_mart_nfpm_position_pnl_current_wealth_reconciles \
    test_mart_nfpm_position_pnl_current_invalid_benchmark_nulls
fi

echo
echo "Done."
