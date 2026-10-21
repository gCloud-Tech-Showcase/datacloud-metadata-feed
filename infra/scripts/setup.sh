#!/usr/bin/env bash
# Prepare a GCP project for `tofu apply`, then initialize the backend.
#
# Handles the things that cannot live inside the Terraform run itself:
#   1. The bootstrap APIs (Cloud Resource Manager, Service Usage, Cloud Storage)
#      the provider needs before it can manage any service on a fresh project.
#   2. The remote-state bucket. The backend must exist before `tofu init` and
#      cannot be stored in the state it holds.
#   3. Injecting that bucket into the backend, because backend blocks cannot read
#      variables (so the name is derived here instead of duplicated in .tf).
#
# The project ID comes from project_id's default in infra/variables.tf. To
# deploy elsewhere, change that default: it also drives every resource. The
# state bucket goes in the US multi-region unless --location says otherwise.
#
# Usage:
#   ./infra/scripts/setup.sh                      # prepare project + init
#   ./infra/scripts/setup.sh --migrate            # also move existing LOCAL state to GCS
#   ./infra/scripts/setup.sh --project=my-proj    # state bucket and init only, not the resources
#   ./infra/scripts/setup.sh --location=EU        # override state bucket location
#
# Idempotent: safe to re-run. Every step checks before acting.
# Prerequisite: the GCP project exists and has billing linked (one-time, manual).

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS_FILE="${INFRA_DIR}/variables.tf"

PROJECT_ID=""
LOCATION=""
MIGRATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT_ID="$2"; shift 2 ;;
    --project=*)  PROJECT_ID="${1#*=}"; shift ;;
    --location)   LOCATION="$2"; shift 2 ;;
    --location=*) LOCATION="${1#*=}"; shift ;;
    --migrate)    MIGRATE=true; shift ;;
    -h|--help)
      sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# Read a variable's default out of variables.tf, the single source of truth.
tf_default() {
  sed -n "/variable \"$1\"/,/^}/{ s/^[[:space:]]*default[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p; }" "$VARS_FILE"
}

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(tf_default project_id)"
fi
if [[ -z "$LOCATION" ]]; then
  # The state bucket goes in the US multi-region, not the demo region: state is
  # the one artifact that can't be rebuilt, so it gets the most durable home.
  LOCATION="US"
fi

if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: could not determine project_id from ${VARS_FILE}; pass --project=<id>" >&2
  exit 1
fi

BUCKET="${PROJECT_ID}-tfstate"

echo "Project      : ${PROJECT_ID}"
echo "State bucket : gs://${BUCKET} (${LOCATION})"
echo ""

# -----------------------------------------------------------------------------
# 1. Bootstrap APIs
# The provider drives google_project_service through Cloud Resource Manager, so
# CRM itself can't be enabled by Terraform on a fresh project. gcloud no-ops if
# they're already on.
# -----------------------------------------------------------------------------
echo "==> Enabling bootstrap APIs"
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  --project="$PROJECT_ID"

# Enablement is eventually consistent: a fresh project can still 403 for a
# minute afterwards. Poll CRM so the first apply doesn't fail on propagation.
echo -n "==> Waiting for Cloud Resource Manager to respond"
for _ in $(seq 1 30); do
  if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    echo " ok"
    break
  fi
  echo -n "."
  sleep 5
done

# -----------------------------------------------------------------------------
# 2. State bucket, versioned so a bad apply or a deleted object is recoverable.
# -----------------------------------------------------------------------------
echo ""
if gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "==> State bucket gs://${BUCKET} already exists"
else
  echo "==> Creating state bucket gs://${BUCKET}"
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

# Applied unconditionally: guarantees versioning even on a pre-existing bucket.
echo "==> Ensuring object versioning is enabled"
gcloud storage buckets update "gs://${BUCKET}" --versioning --project="$PROJECT_ID"

# -----------------------------------------------------------------------------
# 3. Backend init. The bucket is injected here, not hardcoded in providers.tf.
# -----------------------------------------------------------------------------
echo ""
cd "$INFRA_DIR"
if [[ "$MIGRATE" == true ]]; then
  echo "==> tofu init (migrating existing local state to gs://${BUCKET})"
  tofu init -backend-config="bucket=${BUCKET}" -migrate-state -force-copy
else
  echo "==> tofu init (backend bucket: ${BUCKET})"
  tofu init -backend-config="bucket=${BUCKET}" -reconfigure
fi

cat <<EOF

============================================================
Ready. State is now in gs://${BUCKET}/tf/infra/ (versioned).

Next:
  cd infra && tofu apply
EOF
