"""Roll asset readiness up to every data product that contains the asset.

Receives Pub/Sub pushes from the `readiness-changes` metadata feed. For each
event it finds the data products that list the changed asset, reads the
`asset-readiness` aspect of each of their assets, and writes the result to the
data product's `product-readiness` aspect. A product is READY only when every
asset is READY. Every status change is also appended to BigQuery.
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

PROJECT_ID = os.environ["PROJECT_ID"]
PROJECT_NUMBER = os.environ["PROJECT_NUMBER"]
LOG_TABLE = os.environ["LOG_TABLE"]
DATAPLEX = "https://dataplex.googleapis.com/v1"
BIGQUERY_RESOURCE_PREFIX = "//bigquery.googleapis.com/"

_credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
session = AuthorizedSession(_credentials)
bq = bigquery.Client()


@functions_framework.http
def rollup_product(request):
    envelope = request.get_json(silent=True) or {}
    message = envelope.get("message", {})
    attributes = message.get("attributes", {})
    event = json.loads(base64.b64decode(message.get("data", "")) or b"{}")

    fqn = event.get("fullQualifiedName", "")
    if attributes.get("entry_change_type") == "DELETE" or not fqn.startswith("bigquery:"):
        return ("", 204)

    location = event["entryName"].split("/")[3]
    project, dataset, table = fqn.removeprefix("bigquery:").split(".")
    changed_resource = (
        f"{BIGQUERY_RESOURCE_PREFIX}projects/{project}/datasets/{dataset}/tables/{table}"
    )

    for product in _list(
        f"projects/{PROJECT_ID}/locations/{location}/dataProducts", "dataProducts"
    ):
        assets = [a["resource"] for a in _list(f"{product['name']}/dataAssets", "dataAssets")]
        if changed_resource in assets:
            _rollup(product, assets, location)

    return ("", 204)


def _rollup(product: dict, asset_resources: list[str], location: str) -> None:
    product_id = product["name"].rsplit("/", 1)[1]
    reasons = []
    for resource in sorted(asset_resources):
        detail = _blocking_detail(resource, location)
        if detail:
            reasons.append({"asset": _short_name(resource), "detail": detail})

    readiness = {"status": "BLOCKED" if reasons else "READY", "reasons": reasons}
    entry_name = (
        f"projects/{PROJECT_NUMBER}/locations/{location}/entryGroups/@dataplex/entries/"
        f"projects/{PROJECT_NUMBER}/locations/{location}/dataProducts/{product_id}"
    )
    current = _find_aspect(_get_entry(entry_name).get("aspects", {}), ".product-readiness")
    if (
        current
        and current.get("status") == readiness["status"]
        and current.get("reasons", []) == reasons
    ):
        logger.info("Data product %s is still %s, no update", product_id, readiness["status"])
        return

    readiness["checkedAt"] = _now()
    _write_aspect(entry_name, f"{PROJECT_NUMBER}.{location}.product-readiness", readiness)
    _log(product_id, readiness)
    logger.info("Data product %s is now %s", product_id, readiness["status"])


def _blocking_detail(resource: str, location: str) -> str | None:
    """Return why an asset blocks its product, or None if it is READY."""
    if not resource.startswith(BIGQUERY_RESOURCE_PREFIX):
        return "Only BigQuery assets are checked against a schema contract."

    entry_name = (
        f"projects/{PROJECT_ID}/locations/{location}/entryGroups/@bigquery/entries/"
        f"{resource.removeprefix('//')}"
    )
    readiness = _find_aspect(_get_entry(entry_name).get("aspects", {}), ".asset-readiness")
    if readiness is None:
        return "No schema contract has been checked for this asset."
    if readiness.get("status") == "READY":
        return None

    breaking = [r for r in readiness.get("reasons", []) if r.get("breaking")]
    return "; ".join(f"{r['change']} {r['column']}" for r in breaking) or "Asset is BLOCKED."


def _short_name(resource: str) -> str:
    parts = resource.split("/")
    return f"{parts[-3]}.{parts[-1]}" if "/datasets/" in resource else resource


def _find_aspect(aspects: dict, key_suffix: str) -> dict | None:
    # Aspect keys look like `<project>.<location>.<type>`. Keys containing `@`
    # are attached to a single column and are skipped.
    for key, aspect in aspects.items():
        if key.endswith(key_suffix) and "@" not in key:
            return aspect.get("data", {})
    return None


def _list(parent: str, field: str) -> list[dict]:
    items, page_token = [], None
    while True:
        response = session.get(
            f"{DATAPLEX}/{parent}", params={"pageToken": page_token} if page_token else None
        )
        response.raise_for_status()
        body = response.json()
        items.extend(body.get(field, []))
        page_token = body.get("nextPageToken")
        if not page_token:
            return items


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


def _log(product_id: str, readiness: dict) -> None:
    errors = bq.insert_rows_json(
        LOG_TABLE,
        [
            {
                "logged_at": readiness["checkedAt"],
                "level": "PRODUCT",
                "name": product_id,
                "status": readiness["status"],
                "reasons": json.dumps(readiness["reasons"]),
            }
        ],
    )
    if errors:
        raise RuntimeError(f"BigQuery insert failed: {errors}")


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
