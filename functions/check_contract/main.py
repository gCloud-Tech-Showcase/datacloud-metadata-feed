"""Compare a BigQuery asset's live schema with its schema contract.

Receives Pub/Sub pushes from the `schema-changes` metadata feed. For each event
it reads the asset's catalog entry, compares the system `schema` aspect with
the `schema-contract` aspect, and writes the result to the `asset-readiness`
aspect. Every status change is also appended to BigQuery.
"""

import base64
import datetime
import json
import logging
import os

import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession
from google.cloud import bigquery

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PROJECT_NUMBER = os.environ["PROJECT_NUMBER"]
LOG_TABLE = os.environ["LOG_TABLE"]
DATAPLEX = "https://dataplex.googleapis.com/v1"
CHECKED_ENTRY_TYPES = ("/entryTypes/bigquery-table", "/entryTypes/bigquery-view")
TRIGGER_ASPECT_TYPES = ("/aspectTypes/schema", "/aspectTypes/schema-contract")

_credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
session = AuthorizedSession(_credentials)
bq = bigquery.Client()


@functions_framework.http
def check_contract(request):
    envelope = request.get_json(silent=True) or {}
    message = envelope.get("message", {})
    attributes = message.get("attributes", {})
    event = json.loads(base64.b64decode(message.get("data", "")) or b"{}")

    if not _is_relevant(attributes, event):
        return ("", 204)

    location = event["entryName"].split("/")[3]
    entry_name = _entry_name_from_fqn(event["fullQualifiedName"], location)
    aspects = _get_entry(entry_name).get("aspects", {})

    contract = _find_aspect(aspects, ".schema-contract")
    if contract is None:
        logger.info("No schema contract on %s, nothing to check", event["fullQualifiedName"])
        return ("", 204)

    live_schema = _find_aspect(aspects, ".global.schema") or {}
    reasons = compare_schemas(contract.get("fields", []), live_schema.get("fields", []))
    status = "BLOCKED" if any(r["breaking"] for r in reasons) else "READY"
    readiness = {
        "status": status,
        "contractVersion": contract.get("version", ""),
        "reasons": reasons,
    }

    current = _find_aspect(aspects, ".asset-readiness")
    if _same_readiness(current, readiness):
        logger.info("%s is still %s, no update", event["fullQualifiedName"], status)
        return ("", 204)

    readiness["checkedAt"] = _now()
    _write_aspect(entry_name, f"{PROJECT_NUMBER}.{location}.asset-readiness", readiness)
    _log(event["fullQualifiedName"], readiness)
    logger.info("%s is now %s with %d reason(s)", event["fullQualifiedName"], status, len(reasons))
    return ("", 204)


def compare_schemas(contract_fields: list[dict], live_fields: list[dict]) -> list[dict]:
    """Return one reason per difference between the agreed and the live schema.

    Dropped columns and type or mode changes break consumers. Added columns
    do not, so they are reported but do not block.
    """
    agreed = _flatten(contract_fields)
    live = _flatten(live_fields)
    reasons = []

    for name, field in agreed.items():
        actual = live.get(name)
        if actual is None:
            reasons.append(
                _reason(
                    "COLUMN_DROPPED",
                    name,
                    f"Column was removed (agreed {field['dataType']}).",
                    True,
                )
            )
            continue
        if actual["dataType"] != field["dataType"]:
            reasons.append(
                _reason(
                    "TYPE_CHANGED",
                    name,
                    f"Type changed from {field['dataType']} to {actual['dataType']}.",
                    True,
                )
            )
        if _mode(actual) != _mode(field):
            reasons.append(
                _reason(
                    "MODE_CHANGED",
                    name,
                    f"Mode changed from {_mode(field)} to {_mode(actual)}.",
                    True,
                )
            )

    for name in live.keys() - agreed.keys():
        reasons.append(
            _reason(
                "COLUMN_ADDED",
                name,
                f"New {live[name]['dataType']} column is not in the contract.",
                False,
            )
        )

    return sorted(reasons, key=lambda r: (not r["breaking"], r["column"]))


def _is_relevant(attributes: dict, event: dict) -> bool:
    if attributes.get("entry_change_type") == "DELETE":
        return False
    if not attributes.get("entry_type", "").endswith(CHECKED_ENTRY_TYPES):
        return False
    # The feed filter already selects these aspect types. Checking again keeps a
    # readiness write from ever re-triggering this function.
    changed = event.get("updatedAspects", []) + event.get("createdAspects", [])
    return any(a.endswith(TRIGGER_ASPECT_TYPES) for a in changed)


def _entry_name_from_fqn(fqn: str, location: str) -> str:
    # The event's entryName uses an opaque ID that GetEntry rejects, so the
    # readable entry name is rebuilt from `bigquery:<project>.<dataset>.<table>`.
    project, dataset, table = fqn.removeprefix("bigquery:").split(".")
    return (
        f"projects/{project}/locations/{location}/entryGroups/@bigquery/entries/"
        f"bigquery.googleapis.com/projects/{project}/datasets/{dataset}/tables/{table}"
    )


def _find_aspect(aspects: dict, key_suffix: str) -> dict | None:
    # Aspect keys look like `<project>.<location>.<type>`. Keys containing `@`
    # are attached to a single column and are skipped.
    for key, aspect in aspects.items():
        if key.endswith(key_suffix) and "@" not in key:
            return aspect.get("data", {})
    return None


def _flatten(fields: list[dict], prefix: str = "") -> dict[str, dict]:
    flat = {}
    for field in fields:
        name = f"{prefix}{field['name']}"
        flat[name] = field
        flat.update(_flatten(field.get("fields", []), f"{name}."))
    return flat


def _mode(field: dict) -> str:
    return field.get("mode") or "NULLABLE"


def _reason(change: str, column: str, detail: str, breaking: bool) -> dict:
    return {"change": change, "column": column, "detail": detail, "breaking": breaking}


def _same_readiness(current: dict | None, new: dict) -> bool:
    if current is None:
        return False
    return (
        current.get("status") == new["status"]
        and current.get("contractVersion", "") == new["contractVersion"]
        and current.get("reasons", []) == new["reasons"]
    )


def _get_entry(entry_name: str) -> dict:
    response = session.get(f"{DATAPLEX}/{entry_name}", params={"view": "ALL"})
    response.raise_for_status()
    return response.json()


def _write_aspect(entry_name: str, aspect_key: str, data: dict) -> None:
    response = session.patch(
        f"{DATAPLEX}/{entry_name}",
        params={"updateMask": "aspects", "aspectKeys": aspect_key},
        json={"aspects": {aspect_key: {"data": data}}},
    )
    response.raise_for_status()


def _log(fqn: str, readiness: dict) -> None:
    errors = bq.insert_rows_json(
        LOG_TABLE,
        [
            {
                "logged_at": readiness["checkedAt"],
                "level": "ASSET",
                "name": fqn,
                "status": readiness["status"],
                "reasons": json.dumps(readiness["reasons"]),
                "contract_version": readiness["contractVersion"],
            }
        ],
    )
    if errors:
        raise RuntimeError(f"BigQuery insert failed: {errors}")


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
