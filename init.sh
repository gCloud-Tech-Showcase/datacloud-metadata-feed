#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-time initialisation for a domain repo generated from
# gcp-data-domain-template.
#
# Substitutes the __PLACEHOLDER__ tokens, picks the Dataform git-link path,
# optionally strips the unstructured data add-on, then deletes itself and
# INIT.md. Run it once, immediately after generating the repo, before the first
# `tofu apply`.
#
#   ./init.sh --project datacloud-foo \
#             --repo    datacloud-foo-analysis \
#             --org     gCloud-Tech-Showcase \
#             --slug    foo-analysis \
#             --title   "Foo Analysis" \
#             --domain  foo_analysis \
#             [--unstructured]        # keep the GCS + BigLake + Gemini add-on
#             [--private]             # the GitHub repo is private
#
# --private must match how the repo was actually created: a public repo is
# pulled anonymously, a private one over an SSH deploy key, and the two paths
# share no code. Getting it wrong fails at apply, not here.
#
# Idempotent only in the sense that it refuses to run twice — once the
# placeholders are gone there is nothing left to substitute.
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PROJECT="" ; REPO="" ; ORG="" ; SLUG="" ; TITLE="" ; DOMAIN=""
UNSTRUCTURED=false ; PRIVATE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)      PROJECT="$2"; shift 2 ;;
    --repo)         REPO="$2";    shift 2 ;;
    --org)          ORG="$2";     shift 2 ;;
    --slug)         SLUG="$2";    shift 2 ;;
    --title)        TITLE="$2";   shift 2 ;;
    --domain)       DOMAIN="$2";  shift 2 ;;
    --unstructured) UNSTRUCTURED=true; shift ;;
    --private)      PRIVATE=true; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed -e 's/^#//' -e 's/^ //'; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# NB: no bash-4 constructs anywhere in this script (${var,,}, mapfile, declare -A)
# — macOS still ships bash 3.2 and this has to run there.
for v in PROJECT REPO ORG SLUG TITLE DOMAIN; do
  if [[ -z "${!v}" ]]; then
    echo "ERROR: --$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]') is required" >&2
    exit 1
  fi
done

if ! grep -rql '__PROJECT_ID__' . --exclude-dir=.git 2>/dev/null; then
  echo "ERROR: no placeholders found — this repo looks already initialised." >&2
  exit 1
fi

echo "Initialising ${ORG}/${REPO}"
echo "  project : ${PROJECT}"
echo "  slug    : ${SLUG} · domain tag: ${DOMAIN}"
echo "  add-on  : $([[ "$UNSTRUCTURED" == true ]] && echo 'unstructured (GCS + BigLake + Gemini)' || echo 'none')"
echo "  repo is : $([[ "$PRIVATE" == true ]] && echo 'private (Dataform pulls over an SSH deploy key)' || echo 'public (Dataform pulls anonymously)')"
echo ""

# Drop lines carrying $1 from the files that follow. A tag on its own line marks
# the whole following brace-balanced block; an inline tag marks just that line.
# One mechanism, two labels: [addon:unstructured] for the optional add-on, and
# [visibility:public] / [visibility:private] for the mutually exclusive git-link
# paths. Whichever variant is KEPT keeps its tags — they document why the line
# is there, and re-running is refused anyway.
strip_tag() {
  tag="$1"; shift
  TAG="$tag" FILES="$*" python3 - <<'PY'
import os, pathlib

tag = os.environ["TAG"]
for f in os.environ["FILES"].split():
    p = pathlib.Path(f)
    if not p.exists():
        continue  # already removed by an earlier phase
    lines = p.read_text().splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        ln = lines[i]
        if tag in ln:
            if ln.strip() == "# " + tag:
                i += 1
                depth, started = 0, False
                while i < len(lines):
                    depth += lines[i].count("{") - lines[i].count("}")
                    started = started or "{" in lines[i]
                    i += 1
                    if started and depth <= 0:
                        break
                continue
            i += 1
            continue
        out.append(ln)
        i += 1
    p.write_text("".join(out))
PY
}

# --- 1. strip the add-on, if unwanted ----------------------------------------
# Done BEFORE substitution so the [addon:unstructured] tags are still intact.
if [[ "$UNSTRUCTURED" != true ]]; then
  echo "==> Removing the unstructured add-on"
  rm -f  infra/storage.tf infra/seed.tf
  rm -rf scripts data

  strip_tag '[addon:unstructured]' infra/apis.tf infra/variables.tf infra/outputs.tf

  # Remove the two add-on ordering edges that follow the marker in run_pipeline.
  python3 - <<'PY'
import pathlib, re

p = pathlib.Path("infra/dataform.tf")
t = p.read_text()
t2 = re.sub(r"[ \t]*# __ADDON_PIPELINE_DEPS__\n([ \t]*[a-z_].*\n){2}", "", t)
if t2 == t:
    raise SystemExit("ERROR: __ADDON_PIPELINE_DEPS__ marker not found in dataform.tf")
p.write_text(t2)
print("    stripped add-on lines from apis/variables/outputs/dataform")
PY

  echo "    NOTE: also delete the 'raw' entry in infra/datasets.tf and the"
  echo "          raw_dataset_id output if this domain lands no raw data."
fi

# --- 2. keep exactly one Dataform git-link path -------------------------------
# The two paths share no code — one is a REST provisioner with no credential at
# all, the other a declarative resource reading a Secret Manager version — so
# this deletes rather than parameterises.
if [[ "$PRIVATE" == true ]]; then
  echo "==> Wiring the private git link (SSH deploy key)"
  rm -f infra/dataform_git_public.tf infra/scripts/manage_repository.sh
  strip_tag '[visibility:public]' infra/apis.tf infra/variables.tf infra/dataform.tf
  GIT_LINK_PREREQ='This repo is private, so the Dataform repository pulls over SSH using a read-only **deploy key**. `setup.sh` generates it, stores the private half in Secret Manager and registers the public half on this repo — there is no token to create and nothing to paste. It needs [`gh`](https://cli.github.com) authenticated against this repo.'
  GIT_LINK_SHORT='git-linked over SSH with a read-only deploy key, pulls from `main`'
  PUSH_NOTE='That pull uses an SSH deploy key, which setup.sh
     issues for you in step 3.'
else
  echo "==> Wiring the public git link (anonymous, tokenless)"
  rm -f infra/dataform_git_private.tf
  strip_tag '[visibility:private]' infra/apis.tf infra/variables.tf infra/dataform.tf
  GIT_LINK_PREREQ='No GitHub token is needed: the Dataform repository pulls over an *anonymous* git link, which works because this repo is public.'
  GIT_LINK_SHORT='git-linked anonymously, pulls from `main`'
  PUSH_NOTE='That pull is anonymous and tokenless, which is what
     requires the repo to be public.'
fi

# `tofu fmt` aligns trailing comments across adjacent lines, so the two tagged
# depends_on entries are padded to match each other. Once one is gone the
# survivor is alone and wants a single space — collapse it here, so a generated
# repo is fmt-clean without init.sh having to shell out to tofu.
python3 - <<'PY'
import pathlib, re

p = pathlib.Path("infra/dataform.tf")
p.write_text(re.sub(r",[ \t]+(# \[visibility:)", r", \1", p.read_text()))
PY

# --- 3. substitute placeholders ----------------------------------------------
echo "==> Substituting placeholders"
# python3 rather than `sed -i`: BSD/macOS sed requires an argument to -i and
# `grep -Z` isn't portable either. python3 is already a dependency of this
# stack (run_pipeline.sh, seed_data.sh), and it sidesteps shell-escaping of the
# substituted values entirely.
PROJECT="$PROJECT" REPO="$REPO" ORG="$ORG" SLUG="$SLUG" TITLE="$TITLE" DOMAIN="$DOMAIN" \
GIT_LINK_PREREQ="$GIT_LINK_PREREQ" GIT_LINK_SHORT="$GIT_LINK_SHORT" python3 - <<'PY'
import os, pathlib

repl = {
    "__PROJECT_ID__": os.environ["PROJECT"],
    "__REPO_NAME__":  os.environ["REPO"],
    "__GITHUB_ORG__": os.environ["ORG"],
    "__DOMAIN_SLUG__":  os.environ["SLUG"],
    "__DOMAIN_TITLE__": os.environ["TITLE"],
    "__DOMAIN_TAG__": os.environ["DOMAIN"],
    # Prose that differs between the public and private git link. Substituted
    # rather than tag-stripped because the tag rail only understands comments,
    # and markdown has none.
    "__GIT_LINK_PREREQ__": os.environ["GIT_LINK_PREREQ"],
    "__GIT_LINK_SHORT__":  os.environ["GIT_LINK_SHORT"],
}

changed = 0
for p in pathlib.Path(".").rglob("*"):
    if not p.is_file() or ".git" in p.parts or p.name == "init.sh":
        continue
    try:
        t = p.read_text()
    except (UnicodeDecodeError, PermissionError):
        continue  # binary or unreadable — nothing to substitute
    new = t
    for k, v in repl.items():
        new = new.replace(k, v)
    if new != t:
        p.write_text(new)
        changed += 1
print(f"    rewrote {changed} files")
PY

# --- 4. report what's left ----------------------------------------------------
# __CORPUS_*__ are deliberately manual: they depend on the shape of your corpus,
# so init.sh can't know them. __ADDON_PIPELINE_DEPS__ is a marker comment that
# documents the add-on boundary and is meant to stay.
TODO="$(grep -rn '__CORPUS_[A-Z_]*__' . --exclude-dir=.git 2>/dev/null || true)"
LEFT="$(grep -rn '__[A-Z_]*__' . --exclude-dir=.git --exclude=init.sh 2>/dev/null \
        | grep -v '__CORPUS_' | grep -v '__ADDON_PIPELINE_DEPS__' || true)"

if [ -n "$TODO" ]; then
  echo ""
  echo "==> TODO before the first apply — set these for your corpus:"
  printf '%s\n' "$TODO" | sed 's/^/    /'
fi

if [ -n "$LEFT" ]; then
  echo ""
  echo "WARNING: unexpected unresolved placeholders — fill these in by hand:" >&2
  printf '%s\n' "$LEFT" | sed 's/^/    /' >&2
fi

# --- 5. GitHub labels ---------------------------------------------------------
# The issue templates in .github/ reference these; without them the labels are
# silently dropped when an issue is filed, and /lint-issues flags every issue.
# Best-effort: gh is not otherwise required by this stack, so a missing gh or a
# repo that doesn't exist yet is a warning, not a failure.
echo ""
if command -v gh >/dev/null 2>&1 && gh repo view >/dev/null 2>&1; then
  echo "==> Creating issue labels"
  # label|colour|description
  while IFS='|' read -r name colour desc; do
    [ -n "$name" ] || continue
    gh label create "$name" --color "$colour" --description "$desc" --force >/dev/null 2>&1 \
      && printf '    %s\n' "$name" \
      || printf '    %s (skipped)\n' "$name"
  done <<'LABELS'
type:bug|d73a4a|Something is broken
type:data-quality|e8b86d|Data wrong, missing or inconsistent (pipeline running)
type:feature|0e8a16|New functionality, new data, new capability
type:chore|cfd3d7|Maintenance, cleanup, dependency bumps
type:docs|0075ca|Documentation-only changes
area:ingestion|c2e0c6|Sources, seeding, raw-zone landing
area:pipeline|d4c5f9|Transformations, assertions, processed/serving stages
area:consumption|fef2c0|Queries, dashboards, downstream use
area:operations|bfd4f2|Infra/Tofu, IAM, cost, observability
priority:high|b60205|Drop other work, address now
priority:medium|fbca04|Important; this sprint/week
priority:low|c5def5|Nice to have / someday
LABELS
else
  echo "==> Skipping issue labels (gh not available, or no GitHub remote yet)"
  echo "    Re-run label creation later, or issues will file without labels."
fi

# --- 6. self-destruct ---------------------------------------------------------
rm -f INIT.md
rm -f "$ROOT/init.sh"

cat <<EOF

============================================================
Initialised. Next:

  1. Commit and push to main — the Dataform repo pulls from
     GitHub at apply time, so the code has to be on main first.
     ${PUSH_NOTE}
  2. Create the GCP project + link billing (one-time, manual).
  3. ./infra/scripts/setup.sh
  4. cd infra && tofu apply

The example_* pipeline should go green before you write any
domain SQL. Once it does, replace it with your own definitions.
EOF
