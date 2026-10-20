#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Trigger a Dataform pipeline run and block until it finishes.
#
# Invoked by the `terraform_data.run_pipeline` local-exec provisioner as the
# final step of `tofu apply`, so a fresh apply leaves the domain fully built
# (model trained, tables materialized) instead of waiting for the hourly cron.
#
# Uses the Dataform REST API directly (no Dataform CLI): compile `main` into a
# compilation result, create a workflow invocation that executes as the runner
# SA, then poll to completion. Auth is the caller's gcloud token; the pipeline
# itself still runs as RUNNER_SA (named in invocationConfig).
#
# Deps: gcloud (already required), curl, python3 (gcloud depends on it anyway).
# Env:  PROJECT, REGION, REPO, RUNNER_SA  (set by the provisioner).
#
# Retries the whole compile+invoke on permission/token failures, which on a
# freshly created project can appear for ~1-2 min until the runner SA's
# serviceAccountTokenCreator grant propagates to the token-minting backend.
# -----------------------------------------------------------------------------
set -uo pipefail

: "${PROJECT:?PROJECT is required}"
: "${REGION:?REGION is required}"
: "${REPO:?REPO is required}"
: "${RUNNER_SA:?RUNNER_SA is required}"

API_ROOT="https://dataform.googleapis.com/v1beta1"
BASE="$API_ROOT/projects/$PROJECT/locations/$REGION/repositories/$REPO"

MAX_ATTEMPTS=8      # outer retries for IAM propagation
RETRY_SLEEP=30      # seconds between outer retries
POLL_TRIES=80       # ~20 min ceiling for the run itself
POLL_SLEEP=15       # seconds between state polls

# Extract a top-level string field from a JSON object on stdin.
json_field() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }

token() { gcloud auth print-access-token 2>/dev/null; }

# Returns: 0 success | 1 retryable (permission/token/transient) | 2 fatal (no auth / real pipeline failure)
run_once() {
  local tok cr crname wi winame state query
  tok="$(token)"
  if [ -z "$tok" ]; then
    echo "  ! could not get an access token — is gcloud authenticated?"
    return 2
  fi

  # 1. Compile main -> compilation result
  cr="$(curl -sS -X POST "$BASE/compilationResults" \
        -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
        -d '{"gitCommitish":"main"}')"
  crname="$(printf '%s' "$cr" | json_field name)"
  if [ -z "$crname" ]; then
    echo "  ! compilation request failed: $cr"
    return 1
  fi
  echo "  compiled main: ${crname##*/}"

  # 2. Create a workflow invocation that runs as the runner SA
  wi="$(curl -sS -X POST "$BASE/workflowInvocations" \
        -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
        -d "{\"compilationResult\":\"$crname\",\"invocationConfig\":{\"serviceAccount\":\"$RUNNER_SA\",\"transitiveDependenciesIncluded\":true}}")"
  winame="$(printf '%s' "$wi" | json_field name)"
  if [ -z "$winame" ]; then
    echo "  ! invocation request failed (may be IAM propagation): $wi"
    return 1
  fi
  echo "  invocation started: ${winame##*/}"

  # 3. Poll to completion
  local i
  for ((i = 1; i <= POLL_TRIES; i++)); do
    tok="$(token)"
    state="$(curl -sS "$API_ROOT/$winame" -H "Authorization: Bearer $tok" | json_field state)"
    case "$state" in
      SUCCEEDED)
        echo "  pipeline SUCCEEDED"
        return 0
        ;;
      FAILED | CANCELLED)
        query="$(curl -sS "$API_ROOT/$winame:query" -H "Authorization: Bearer $tok")"
        echo "  pipeline $state — details:"
        printf '%s\n' "$query"
        # Retry only the IAM-propagation race. Match against the extracted
        # failureReason fields ONLY — grepping the whole payload matches
        # Dataform's own generated SQL, which embeds the literal string
        # "User does not have bigquery.datasets.create permission" in its
        # CREATE SCHEMA wrapper, making every failure look retryable forever.
        reasons="$(printf '%s' "$query" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in d.get("workflowInvocationActions", []):
    r = a.get("failureReason")
    if r:
        print(r)
' 2>/dev/null)"
        printf '  failure reasons:\n%s\n' "${reasons:-  (none reported)}"
        if printf '%s' "$reasons" | grep -qiE 'permission|generate tokens|PERMISSION_DENIED|token creator'; then
          return 1
        fi
        return 2
        ;;
      "")
        echo "  ! could not read invocation state; retrying poll"
        ;;
      *)
        echo "  state=$state ($i/$POLL_TRIES)"
        ;;
    esac
    sleep "$POLL_SLEEP"
  done
  echo "  ! timed out waiting for the invocation to finish"
  return 1
}

echo "Triggering Dataform pipeline for $REPO (runs as $RUNNER_SA)..."
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
  echo "Attempt $attempt/$MAX_ATTEMPTS:"
  run_once
  rc=$?
  case "$rc" in
    0) echo "Done — domain is live."; exit 0 ;;
    2) echo "Fatal error; not retrying."; exit 1 ;;
    *)
      if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        echo "Retryable failure; waiting ${RETRY_SLEEP}s (IAM may still be propagating)..."
        sleep "$RETRY_SLEEP"
      fi
      ;;
  esac
done

echo "Gave up after $MAX_ATTEMPTS attempts."
exit 1
