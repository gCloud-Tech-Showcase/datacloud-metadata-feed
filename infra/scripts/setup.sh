#!/usr/bin/env bash
# Prepare a GCP project for `tofu apply`, then initialize the backend.
#
# Handles the things that cannot live inside the Terraform run itself:
#   1. The bootstrap APIs (Cloud Resource Manager / Service Usage) the provider
#      needs before it can manage ANY service on a fresh project.
#   2. On a PRIVATE domain, Dataform's SSH deploy key — generated here so the
#      private half never becomes a Terraform-managed value, and therefore never
#      lands in state. Skipped entirely on a public domain.
#   3. The remote-state bucket — a chicken-and-egg, since the backend must exist
#      before `tofu init` and can't be stored in the state it holds.
#   4. Injecting that bucket into the backend, because backend blocks cannot read
#      variables (so the name is derived here instead of duplicated in .tf).
#
# Config comes from ONE place: the defaults in infra/variables.tf. Override with
# flags if you're deploying somewhere else.
#
# Usage:
#   ./infra/scripts/setup.sh                      # prepare project + init
#   ./infra/scripts/setup.sh --migrate            # also move existing LOCAL state to GCS
#   ./infra/scripts/setup.sh --project=my-proj    # override project
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
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# Read a variable's default out of variables.tf — the single source of truth.
tf_default() {
  sed -n "/variable \"$1\"/,/^}/{ s/^[[:space:]]*default[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p; }" "$VARS_FILE"
}

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(tf_default project_id)"
fi
if [[ -z "$LOCATION" ]]; then
  # State bucket follows dataset_location (US multiregion), NOT region: state is
  # the one artifact that can't be rebuilt, so it gets the most durable home.
  LOCATION="$(tf_default dataset_location)"
  LOCATION="${LOCATION:-US}"
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
#
# dataform is here for a subtler reason: terraform_data.repository and
# run_pipeline call the Dataform REST API from local-exec provisioners. If
# Terraform enables that API in the same apply, the call races enablement and
# fails with PERMISSION_DENIED on dataform.repositories.create — Terraform's
# own ordering can't help, because the REST call happens outside its graph.
# Rule of thumb: any API a provisioner touches must be pre-enabled here.
# -----------------------------------------------------------------------------
echo "==> Enabling bootstrap APIs"
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  dataform.googleapis.com \
  --project="$PROJECT_ID"

# Enablement is eventually consistent — a fresh project can still 403 for a
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
# 2. Dataform deploy key — private domains only.
# The presence of dataform_git_private.tf is what makes a domain private: init.sh
# keeps exactly one of the two git-link files, so there's nothing to pass in.
#
# The key is generated here rather than by Tofu on purpose. The provider takes a
# Secret Manager version NAME, never key material, so nothing in the graph needs
# the private half as a value — and a tls_private_key resource would write it to
# state in plaintext for no gain.
#
# Caveat worth knowing: `gh` associates the deploy key with the authenticated
# token, so de-authorizing the GitHub CLI removes keys it created. Rotate by
# deleting the secret and re-running this script.
# -----------------------------------------------------------------------------
if [[ -f "${INFRA_DIR}/dataform_git_private.tf" ]]; then
  SECRET_ID="$(tf_default deploy_key_secret_id)"
  SECRET_ID="${SECRET_ID:-dataform-github-deploy-key}"

  echo ""
  echo "==> Enabling Secret Manager (private domain)"
  gcloud services enable secretmanager.googleapis.com --project="$PROJECT_ID"

  if gcloud secrets describe "$SECRET_ID" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "==> Deploy key secret ${SECRET_ID} already exists — leaving it alone"
    # The secret and the GitHub key are two halves of one credential created in
    # one shot. If only the secret survives, Dataform will fail to pull and the
    # error surfaces at compile time, far from the cause — so say so now.
    if command -v gh >/dev/null 2>&1 \
       && ! gh repo deploy-key list --json title --jq '.[].title' 2>/dev/null \
            | grep -qx "$SECRET_ID"; then
      echo "    WARNING: no deploy key titled '${SECRET_ID}' on the GitHub repo." >&2
      echo "             The two halves are out of sync. Delete the secret and" >&2
      echo "             re-run to reissue both." >&2
    fi
  else
    if ! command -v gh >/dev/null 2>&1; then
      echo "ERROR: gh is required to register the deploy key on GitHub." >&2
      exit 1
    fi

    echo "==> Generating Dataform's SSH deploy key"
    KEYDIR="$(mktemp -d)"
    trap 'rm -rf "$KEYDIR"' EXIT
    ssh-keygen -t ed25519 -N '' -C "dataform@${PROJECT_ID}" -f "${KEYDIR}/id" >/dev/null

    gcloud secrets create "$SECRET_ID" \
      --project="$PROJECT_ID" --replication-policy=automatic >/dev/null
    gcloud secrets versions add "$SECRET_ID" \
      --project="$PROJECT_ID" --data-file="${KEYDIR}/id" >/dev/null
    echo "    private half stored as secret ${SECRET_ID}"

    # Read-only is the default and all Dataform needs; there is no
    # --allow-write=false, so the flag is simply omitted rather than negated.
    gh repo deploy-key add "${KEYDIR}/id.pub" --title "$SECRET_ID" >/dev/null
    echo "    public half registered on the GitHub repo (read-only)"

    rm -rf "$KEYDIR"
    trap - EXIT
  fi
fi

# -----------------------------------------------------------------------------
# 3. State bucket — versioned so a bad apply or a deleted object is recoverable.
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
# 4. Backend init — bucket injected here rather than hardcoded in providers.tf.
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
