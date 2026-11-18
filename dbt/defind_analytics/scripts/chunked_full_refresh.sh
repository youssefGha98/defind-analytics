#!/usr/bin/env bash
#
# Chunked full-refresh for dbt incremental models that would OOM on a single pass.
#
# Instead of `dbt run --full-refresh`, this script:
#   1. DROPs the target table
#   2. Creates it empty via dbt (using a far-future date window)
#   3. Fills it incrementally in time-based chunks
#
# Model registry: each model declares its source table (for date-range detection),
# date column, and the dbt var names used for start/end windowing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DBT_BIN="${DBT_DIR}/../../.venv/bin/dbt"

TARGET="local"
MODEL=""
CHUNK_MONTHS=6
DRY_RUN="0"
CH_HOST="localhost"
CH_PORT="8124"
CH_USER="default"
CH_PASSWORD="1234"
CH_DATABASE="analytics"

# ── Model registry ──────────────────────────────────────────────────
# Each entry: source_table|date_column|var_start|var_end|date_format
# date_format: "date" for toDate columns, "datetime" for DateTime columns
declare -A MODEL_REGISTRY=(
  ["mart_tick_sigma_evc_hourly"]="int_tick_volume_hourly|hour|sigma_evc_start_hour|sigma_evc_end_hour|datetime"
  ["mart_tick_liquidity_volume_daily"]="int_tick_volume_daily|date|sigma_evc_start_date|sigma_evc_end_date|date"
  ["mart_tick_sigma_evc_weekly"]="int_tick_volume_weekly|week_start|sigma_evc_start_date|sigma_evc_end_date|date"
)

usage() {
  cat <<'EOF'
Usage:
  bash scripts/chunked_full_refresh.sh --model <model_name> [options]

Options:
  --model         dbt model name (required)
  --target        dbt target (default: local)
  --chunk-months  months per chunk (default: 6)
  --dry-run       print commands without executing
  --ch-port       ClickHouse HTTP port (default: 8124)
  --ch-password   ClickHouse password (default: 1234)
  -h, --help      show this help

Registered models:
EOF
  for m in "${!MODEL_REGISTRY[@]}"; do
    echo "  - $m"
  done | sort
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)       MODEL="${2:-}";       shift 2 ;;
    --target)      TARGET="${2:-}";      shift 2 ;;
    --chunk-months) CHUNK_MONTHS="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN="1";          shift ;;
    --ch-port)     CH_PORT="${2:-}";     shift 2 ;;
    --ch-password) CH_PASSWORD="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${MODEL}" ]]; then
  echo "ERROR: --model is required." >&2
  usage
  exit 1
fi

if [[ -z "${MODEL_REGISTRY[${MODEL}]+_}" ]]; then
  echo "ERROR: model '${MODEL}' not in registry." >&2
  echo "Registered models:"
  for m in "${!MODEL_REGISTRY[@]}"; do echo "  - $m"; done | sort
  exit 1
fi

IFS='|' read -r SOURCE_TABLE DATE_COL VAR_START VAR_END DATE_FMT <<< "${MODEL_REGISTRY[${MODEL}]}"

CH_URL="http://${CH_USER}:${CH_PASSWORD}@${CH_HOST}:${CH_PORT}"

ch_query() {
  curl -sf "${CH_URL}" --data "$1"
}

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# ── Step 0: detect date range from source ───────────────────────────
echo "=== Chunked full-refresh: ${MODEL} ==="
echo "  target: ${TARGET}, chunk_size: ${CHUNK_MONTHS} months"
echo ""

echo "Detecting date range from ${SOURCE_TABLE}.${DATE_COL}..."
RANGE=$(ch_query "SELECT min(${DATE_COL}), max(${DATE_COL}) FROM ${CH_DATABASE}.${SOURCE_TABLE} FORMAT TabSeparated")
MIN_DATE=$(echo "${RANGE}" | cut -f1 | cut -d' ' -f1)
MAX_DATE=$(echo "${RANGE}" | cut -f2 | cut -d' ' -f1)

if [[ -z "${MIN_DATE}" || "${MIN_DATE}" == "1970-01-01" ]]; then
  echo "ERROR: source table is empty or date range invalid." >&2
  exit 1
fi

echo "  Source range: ${MIN_DATE} → ${MAX_DATE}"
echo ""

# ── Step 1: DROP existing table ─────────────────────────────────────
echo "Step 1/3: DROP TABLE ${CH_DATABASE}.${MODEL}"
run_cmd ch_query "DROP TABLE IF EXISTS ${CH_DATABASE}.${MODEL}"

# ── Step 2: Create empty table via dbt ──────────────────────────────
echo "Step 2/3: Create empty table via dbt --full-refresh (far-future window)"

if [[ "${DATE_FMT}" == "datetime" ]]; then
  EMPTY_VARS="{\"${VAR_START}\": \"2099-01-01 00:00:00\", \"${VAR_END}\": \"2099-01-01 00:00:00\"}"
else
  EMPTY_VARS="{\"${VAR_START}\": \"2099-01-01\", \"${VAR_END}\": \"2099-01-01\"}"
fi

run_cmd "${DBT_BIN}" run --full-refresh --target "${TARGET}" \
  -s "${MODEL}" --vars "${EMPTY_VARS}" 2>&1 | tail -3

echo ""

# ── Step 3: Fill by chunks ──────────────────────────────────────────
echo "Step 3/3: Filling by ${CHUNK_MONTHS}-month chunks"

# Align to first-of-month
CURRENT=$(date -d "${MIN_DATE}" +%Y-%m-01)
END_EPOCH=$(date -d "${MAX_DATE}" +%s)

total_start=$(date +%s)
chunk_idx=0
errors=0

while [[ $(date -d "${CURRENT}" +%s) -le ${END_EPOCH} ]]; do
  CHUNK_END_DATE=$(date -d "$(date -d "${CURRENT} +${CHUNK_MONTHS} months" +%Y-%m-01) -1 day" +%F)

  # Cap at max date
  if [[ $(date -d "${CHUNK_END_DATE}" +%s) -gt ${END_EPOCH} ]]; then
    CHUNK_END_DATE="${MAX_DATE}"
  fi

  chunk_idx=$((chunk_idx + 1))

  if [[ "${DATE_FMT}" == "datetime" ]]; then
    VARS="{\"${VAR_START}\": \"${CURRENT} 00:00:00\", \"${VAR_END}\": \"${CHUNK_END_DATE} 23:59:59\"}"
  else
    VARS="{\"${VAR_START}\": \"${CURRENT}\", \"${VAR_END}\": \"${CHUNK_END_DATE}\"}"
  fi

  echo -n "  Chunk ${chunk_idx}: ${CURRENT} → ${CHUNK_END_DATE} ... "
  chunk_start=$(date +%s)

  chunk_log=$(mktemp)
  if run_cmd "${DBT_BIN}" run --target "${TARGET}" \
    -s "${MODEL}" --vars "${VARS}" > "${chunk_log}" 2>&1; then
    chunk_end=$(date +%s)
    echo "OK ($(( chunk_end - chunk_start ))s)"
  else
    echo "FAILED"
    tail -5 "${chunk_log}" | sed 's/^/    /'
    errors=$((errors + 1))
  fi
  rm -f "${chunk_log}"

  CURRENT=$(date -d "${CHUNK_END_DATE} +1 day" +%F)
done

total_end=$(date +%s)
echo ""
echo "=== Done: ${chunk_idx} chunks in $(( total_end - total_start ))s, ${errors} errors ==="

# Verify
if [[ "${DRY_RUN}" != "1" ]]; then
  ROW_COUNT=$(ch_query "SELECT count() FROM ${CH_DATABASE}.${MODEL}")
  echo "  Final row count: ${ROW_COUNT}"
fi
