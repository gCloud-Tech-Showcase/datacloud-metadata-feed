#!/usr/bin/env bash
# Create or delete the managed Dataform repository via the REST API.
#
# We do this out-of-band (from a terraform_data provisioner) rather than with the
# google_dataform_repository resource because the provider enforces
# ExactlyOneOf(token / ssh / developer-connect) on git_remote_settings and cannot
# express a tokenless (anonymous) git link — but the REST API accepts one, which
# is all a PUBLIC repo needs. No PAT, no Secret Manager.
#
# Usage: manage_repository.sh create|delete
# Env:   PROJECT, REGION, REPO   (URL also required for create)
set -uo pipefail

ACTION="${1:-create}"
: "${PROJECT:?PROJECT is required}"
: "${REGION:?REGION is required}"
: "${REPO:?REPO is required}"

API="https://dataform.googleapis.com/v1beta1/projects/${PROJECT}/locations/${REGION}/repositories"

token() { gcloud auth print-access-token 2>/dev/null; }

case "$ACTION" in
  create)
    : "${URL:?URL is required for create}"
    T="$(token)"
    if [ -z "$T" ]; then
      echo "ERROR: could not get an access token (run: gcloud auth application-default login)" >&2
      exit 1
    fi

    code="$(curl -sS -o /tmp/df_repo_get.json -w '%{http_code}' \
      "${API}/${REPO}" -H "Authorization: Bearer ${T}")"
    if [ "$code" = "200" ]; then
      echo "Dataform repository '${REPO}' already exists — nothing to do."
      exit 0
    fi
    if [ "$code" != "404" ]; then
      echo "WARN: unexpected GET status ${code}: $(cat /tmp/df_repo_get.json)" >&2
    fi

    echo "Creating Dataform repository '${REPO}' with anonymous git link to ${URL} ..."
    resp="$(curl -sS -X POST "${API}?repositoryId=${REPO}" \
      -H "Authorization: Bearer ${T}" \
      -H "Content-Type: application/json" \
      -d "{\"gitRemoteSettings\":{\"url\":\"${URL}\",\"defaultBranch\":\"main\"}}")"
    name="$(printf '%s' "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)"
    if [ -z "$name" ]; then
      echo "ERROR: repository create failed: ${resp}" >&2
      exit 1
    fi
    echo "Created ${name}"
    ;;

  delete)
    T="$(token)"
    if [ -z "$T" ]; then
      echo "WARN: no access token; skipping repository delete (may already be gone)." >&2
      exit 0
    fi
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
      "${API}/${REPO}?force=true" -H "Authorization: Bearer ${T}")"
    echo "Delete '${REPO}' -> HTTP ${code}"
    # Never fail destroy: a 404 (already gone) is success for our purposes.
    ;;

  *)
    echo "ERROR: unknown action '${ACTION}' (expected create|delete)" >&2
    exit 1
    ;;
esac
