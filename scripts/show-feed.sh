#!/usr/bin/env bash
# Print metadata change feed messages from a `-demo` pull subscription, one
# readable line each. Nothing else consumes these subscriptions, so acking here
# never takes a message away from the functions.
#
# Usage:
#   ./scripts/show-feed.sh                       # schema-changes-demo, up to 20 messages
#   ./scripts/show-feed.sh readiness-changes     # the readiness feed instead
#   ./scripts/show-feed.sh notifications         # schema change notifications for stewards
#   ./scripts/show-feed.sh --clear               # drop the backlog on all three, before a demo
#   ./scripts/show-feed.sh --project=my-proj     # override project

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ID="$(sed -n '/variable "project_id"/,/^}/{ s/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p; }' "${REPO_DIR}/infra/variables.tf")"
FEED="schema-changes"
CLEAR=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project=*) PROJECT_ID="${1#*=}"; shift ;;
    --clear)     CLEAR=true; shift ;;
    -h|--help)   sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           FEED="$1"; shift ;;
  esac
done

if [[ "$CLEAR" == true ]]; then
  for feed in schema-changes readiness-changes schema-change-notifications; do
    gcloud pubsub subscriptions seek "${feed}-demo" --project="$PROJECT_ID" \
      --time="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --format=none
    echo "Cleared ${feed}-demo"
  done
  exit 0
fi

if [[ "$FEED" == "notifications" ]]; then
  gcloud pubsub subscriptions pull schema-change-notifications-demo --project="$PROJECT_ID" --auto-ack --limit=20 --format=json \
    | python3 -I -c '
import base64, json, sys

messages = json.load(sys.stdin)
if not messages:
    print("No new notifications.")
for m in sorted(messages, key=lambda m: m["message"]["publishTime"]):
    n = json.loads(base64.b64decode(m["message"]["data"]))
    recipient = n["recipient"]["googleGroup"] or "(none: " + n.get("note", "") + ")"
    print(
        m["message"]["publishTime"][11:19],
        n["severity"].ljust(8),
        n["dataProductName"] + " / " + n["asset"],
        " " + n["previousStatus"] + " -> " + n["status"],
    )
    print("         to:", recipient)
    for label, key in (("new", "newReasons"), ("resolved", "resolvedReasons")):
        for r in n[key]:
            print("        ", label.ljust(8), r["change"], r["column"] + ":", r["detail"])
'
  exit 0
fi

gcloud pubsub subscriptions pull "${FEED}-demo" --project="$PROJECT_ID" --auto-ack --limit=20 --format=json \
  | python3 -I -c '
import base64, json, sys

messages = json.load(sys.stdin)
if not messages:
    print("No new messages.")
for m in sorted(messages, key=lambda m: m["message"]["publishTime"]):
    msg = m["message"]
    attributes = msg.get("attributes", {})
    data = json.loads(base64.b64decode(msg.get("data", "")) or b"{}")
    changed = [a.rsplit("/", 1)[-1] for a in data.get("updatedAspects", []) + data.get("createdAspects", [])]
    print(
        msg["publishTime"][11:19],
        attributes.get("entry_change_type", "").ljust(6),
        attributes.get("entry_type", "").rsplit("/", 1)[-1].ljust(14),
        data.get("fullQualifiedName", data.get("entryName", "").rsplit("/", 1)[-1]).ljust(48),
        ", ".join(changed),
    )
'
