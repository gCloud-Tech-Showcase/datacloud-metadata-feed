#!/usr/bin/env bash
# Check that the demo is healthy by reading Knowledge Catalog directly.
#
#   1. Every data product asset has an asset-readiness aspect, and its status.
#   2. The data product's product-readiness status.
#   3. Nothing is waiting in the dead-letter subscription.
#   4. With --smoke: create a throwaway table with a contract it breaks, and
#      wait for check-contract to mark it BLOCKED. This proves the feed, the
#      push subscription and the function work end to end.
#
# Usage:
#   ./scripts/verify.sh                         # report current readiness
#   ./scripts/verify.sh --expect READY          # exit 1 unless everything is READY
#   ./scripts/verify.sh --smoke                 # also run the end-to-end smoke test
#   ./scripts/verify.sh --project=my-proj       # override project

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ID="$(sed -n '/variable "project_id"/,/^}/{ s/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p; }' "${REPO_DIR}/infra/variables.tf")"
REGION="$(sed -n '/variable "region"/,/^}/{ s/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p; }' "${REPO_DIR}/infra/variables.tf")"
EXPECT=""
SMOKE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project=*) PROJECT_ID="${1#*=}"; shift ;;
    --expect)    EXPECT="$2"; shift 2 ;;
    --smoke)     SMOKE=true; shift ;;
    -h|--help)   sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

DATAPLEX="https://dataplex.googleapis.com/v1"
TOKEN="$(gcloud auth print-access-token)"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
FAILED=0

api() {
  local method=$1 url=$2 body=${3:-}
  curl -sS -X "$method" -H "Authorization: Bearer ${TOKEN}" -H "x-goog-user-project: ${PROJECT_ID}" \
    -H "Content-Type: application/json" ${body:+-d "$body"} "$url"
}

# Prints "<status> <reasons>" for one aspect type on one entry, or "MISSING".
readiness() {
  local entry=$1 aspect_type=$2
  api GET "${DATAPLEX}/${entry}?view=ALL" | python3 -I -c '
import json, sys
suffix = "." + sys.argv[1]
aspects = json.load(sys.stdin).get("aspects", {})
data = next((a.get("data", {}) for k, a in aspects.items() if k.endswith(suffix) and "@" not in k), None)
if data is None:
    print("MISSING")
else:
    labels = [
        " ".join(filter(None, [r.get("change") or r.get("asset"), r.get("column")]))
        + ": " + r.get("detail", "")
        for r in data.get("reasons", [])
    ]
    reasons = "; ".join(labels)
    print(data.get("status", "MISSING"), reasons)
' "$aspect_type"
}

check() {
  local label=$1 result=$2
  printf '  %-34s %s\n' "$label" "$result"
  local status="${result%% *}"
  if [[ "$status" == "MISSING" ]] || [[ -n "$EXPECT" && "$status" != "$EXPECT" ]]; then
    FAILED=1
  fi
}

echo "Project: ${PROJECT_ID} (${REGION})"
echo ""
echo "==> Asset readiness"
ASSETS="$(api GET "${DATAPLEX}/projects/${PROJECT_ID}/locations/${REGION}/dataProducts/sales-orders/dataAssets" \
  | python3 -I -c 'import json,sys; [print(a["resource"].removeprefix("//")) for a in json.load(sys.stdin).get("dataAssets", [])]')"
if [[ -z "$ASSETS" ]]; then
  echo "  ERROR: data product sales-orders has no assets" >&2
  exit 1
fi
for resource in $ASSETS; do
  entry="projects/${PROJECT_ID}/locations/${REGION}/entryGroups/@bigquery/entries/${resource}"
  check "$(echo "$resource" | awk -F/ '{print $(NF-2)"."$NF}')" "$(readiness "$entry" asset-readiness)"
done

echo ""
echo "==> Product readiness"
product_entry="projects/${PROJECT_NUMBER}/locations/${REGION}/entryGroups/@dataplex/entries/projects/${PROJECT_NUMBER}/locations/${REGION}/dataProducts/sales-orders"
check "sales-orders" "$(readiness "$product_entry" product-readiness)"

echo ""
echo "==> Dead-letter subscription"
# Pull without acking, so the messages stay for inspection.
DEAD="$(gcloud pubsub subscriptions pull feed-dead-letter-pull --project="$PROJECT_ID" --limit=10 --format='value(message.messageId)' 2>/dev/null | wc -l)"
if [[ "$DEAD" -gt 0 ]]; then
  echo "  ${DEAD} undelivered message(s): check the function logs"
  FAILED=1
else
  echo "  empty"
fi

if [[ "$SMOKE" == true ]]; then
  echo ""
  echo "==> Smoke test"
  table="smoke_$(date +%s)"
  entry="projects/${PROJECT_ID}/locations/${REGION}/entryGroups/@bigquery/entries/bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/contract_monitoring/tables/${table}"
  trap 'bq --project_id="$PROJECT_ID" rm -f -t "${PROJECT_ID}:contract_monitoring.${table}" >/dev/null 2>&1 || true' EXIT

  bq --project_id="$PROJECT_ID" query --nouse_legacy_sql --location="$REGION" \
    "CREATE TABLE contract_monitoring.${table} AS SELECT 1 AS a" >/dev/null
  echo "  created contract_monitoring.${table} with a INTEGER column"

  for _ in $(seq 1 12); do
    [[ "$(api GET "${DATAPLEX}/${entry}" | python3 -I -c 'import json,sys; print("name" in json.load(sys.stdin))')" == "True" ]] && break
    sleep 5
  done

  key="${PROJECT_NUMBER}.${REGION}.schema-contract"
  api PATCH "${DATAPLEX}/${entry}?updateMask=aspects&aspectKeys=${key}" \
    "{\"aspects\":{\"${key}\":{\"data\":{\"version\":\"smoke\",\"fields\":[{\"name\":\"a\",\"dataType\":\"STRING\",\"mode\":\"NULLABLE\"}]}}}}" >/dev/null
  echo "  attached a contract that expects a STRING column"

  result="MISSING"
  for _ in $(seq 1 24); do
    result="$(readiness "$entry" asset-readiness)"
    [[ "${result%% *}" == "BLOCKED" ]] && break
    sleep 5
  done
  if [[ "${result%% *}" == "BLOCKED" ]]; then
    echo "  PASS: ${result}"
  else
    echo "  FAIL: no BLOCKED status after 120 s (got: ${result})"
    FAILED=1
  fi
fi

echo ""
if [[ "$FAILED" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "OK"
