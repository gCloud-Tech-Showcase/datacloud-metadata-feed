#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# [addon:unstructured] Seed the committed corpus into the BigLake bucket.
#
# The frozen corpus lives in git as a single NDJSON (one JSON record per line).
# A BigLake object table is ONE ROW PER FILE, so using the NDJSON directly would
# collapse the whole corpus to a single row. This script explodes it back into
# one <id>.json per record and uploads them — reproducing the exact object-table
# state without needing a Cloud Function or Eventarc.
#
# Invoked by `terraform_data.seed_data` during `tofu apply`, before the Dataform
# pipeline runs. Idempotent: `gsutil rsync -d` reconciles the bucket to exactly
# the committed set every run.
#
# TEMPLATE — set the three values under CONFIGURE below, then delete this line.
#
# Deps: python3 + gsutil (both already required by the rest of the stack).
# Env:  PROJECT   (the GCP project; bucket is <PROJECT>-multimodal-data)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${PROJECT:?PROJECT is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- CONFIGURE ---------------------------------------------------------------
# The committed corpus file.
CORPUS="${SCRIPT_DIR}/../data/__CORPUS_FILE__"
# Path under the bucket. Keep it descriptive — it ends up in the object table's
# `uris` glob in definitions/raw/.
DEST="gs://${PROJECT}-multimodal-data/__CORPUS_PREFIX__"
# JSON key used as the per-file name. MUST be unique and stable across runs, or
# rsync churns and the object table's row identity changes between applies.
ID_FIELD="__CORPUS_ID_FIELD__"
# -----------------------------------------------------------------------------

if [ ! -f "$CORPUS" ]; then
  echo "ERROR: corpus not found at $CORPUS" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Splitting $(wc -l < "$CORPUS") records into individual JSON files..."
python3 - "$CORPUS" "$TMP" "$ID_FIELD" <<'PY'
import sys, json, os
corpus, out, id_field = sys.argv[1], sys.argv[2], sys.argv[3]
n, seen = 0, set()
with open(corpus) as f:
    for lineno, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if id_field not in obj:
            sys.exit(f"ERROR: line {lineno} has no '{id_field}' field")
        rid = str(obj[id_field])
        # A collision would silently drop records — the object table would come
        # up short and nothing would say why.
        if rid in seen:
            sys.exit(f"ERROR: duplicate {id_field} {rid!r} at line {lineno}")
        seen.add(rid)
        with open(os.path.join(out, f"{rid}.json"), "w") as w:
            json.dump(obj, w, ensure_ascii=False)
        n += 1
print(f"  wrote {n} files")
PY

echo "Uploading to ${DEST}/ (rsync -d, idempotent)..."
gsutil -m rsync -d "$TMP" "$DEST"
echo "Seed complete: $(gsutil ls "${DEST}/*.json" | wc -l) objects in bucket."
