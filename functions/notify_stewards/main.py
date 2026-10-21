"""Publish a schema change notification for every data product containing an asset.

Receives Pub/Sub pushes from the `readiness-changes` metadata feed. Whenever the
set of differences between an asset's live schema and its schema contract
changes, it publishes one message per data product that lists the asset. The
message names the Google Group of the data product's notify access group as the
recipient. Every notification is recorded in BigQuery, which is also how a
repeated event is recognised and skipped.

Severity:
    BREAKING  at least one dropped, retyped or mode-changed column
    REVIEW    only added columns: the contract is broken, nothing breaks yet
    RESOLVED  no differences left
"""

import base64
import datetime
import json
import logging
import os

import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession
from google.cloud import bigquery, pubsub_v1

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PROJECT_ID = os.environ["PROJECT_ID"]
NOTIFICATION_TOPIC = os.environ["NOTIFICATION_TOPIC"]
NOTIFICATION_LOG = os.environ["NOTIFICATION_LOG"]
NOTIFY_ACCESS_GROUP = os.environ["NOTIFY_ACCESS_GROUP"]
DATAPLEX = "https://dataplex.googleapis.com/v1"

_credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
session = AuthorizedSession(_credentials)
bq = bigquery.Client()
publisher = pubsub_v1.PublisherClient()


@functions_framework.http
def notify_stewards(request):
    envelope = request.get_json(silent=True) or {}
    message = envelope.get("message", {})
    attributes = message.get("attributes", {})
    event = json.loads(base64.b64decode(message.get("data", "")) or b"{}")

    fqn = event.get("fullQualifiedName", "")
    if attributes.get("entry_change_type") == "DELETE" or not fqn.startswith("bigquery:"):
        return ("", 204)

    location = event["entryName"].split("/")[3]
    project, dataset, table = fqn.removeprefix("bigquery:").split(".")
    resource = f"//bigquery.googleapis.com/projects/{project}/datasets/{dataset}/tables/{table}"
    entry_name = (
        f"projects/{project}/locations/{location}/entryGroups/@bigquery/entries/"
        f"{resource.removeprefix('//')}"
    )

    readiness = _find_aspect(_get_entry(entry_name).get("aspects", {}), ".asset-readiness")
    if readiness is None:
        return ("", 204)

    for product in _list(
        f"projects/{PROJECT_ID}/locations/{location}/dataProducts", "dataProducts"
    ):
        assets = [a["resource"] for a in _list(f"{product['name']}/dataAssets", "dataAssets")]
        if resource in assets:
            _notify(product, f"{dataset}.{table}", readiness)

    return ("", 204)


def _notify(product: dict, asset: str, readiness: dict) -> None:
    product_id = product["name"].rsplit("/", 1)[1]
    reasons = readiness.get("reasons", [])
    last = _last_notification(product_id, asset)
    last_reasons = last["reasons"] if last else []

    # Equal sets cover duplicate deliveries, unrelated readiness writes, and the
    # first READY state with nothing to report.
    if _keys(reasons) == _keys(last_reasons):
        logger.info("No new differences for %s in %s, no notification", asset, product_id)
        return

    severity = _severity(reasons)
    recipient = (
        product.get("accessGroups", {})
        .get(NOTIFY_ACCESS_GROUP, {})
        .get("principal", {})
        .get("googleGroup")
    )
    notification = {
        "severity": severity,
        "dataProduct": product_id,
        "dataProductName": product.get("displayName", product_id),
        "asset": asset,
        "status": readiness.get("status"),
        "previousStatus": last["status"] if last else "READY",
        "contractVersion": readiness.get("contractVersion"),
        "checkedAt": readiness.get("checkedAt"),
        "newReasons": [r for r in reasons if _key(r) not in _keys(last_reasons)],
        "resolvedReasons": [r for r in last_reasons if _key(r) not in _keys(reasons)],
        "allReasons": reasons,
        "recipient": {"accessGroup": NOTIFY_ACCESS_GROUP, "googleGroup": recipient},
    }
    if recipient is None:
        notification["note"] = (
            f"No '{NOTIFY_ACCESS_GROUP}' access group on this data product, so there is no recipient."
        )

    message_id = publisher.publish(
        NOTIFICATION_TOPIC,
        json.dumps(notification).encode(),
        severity=severity,
        data_product=product_id,
        asset=asset,
    ).result()
    _log(notification, message_id)
    logger.info("Published %s notification for %s in %s", severity, asset, product_id)


def _severity(reasons: list[dict]) -> str:
    if not reasons:
        return "RESOLVED"
    return "BREAKING" if any(r.get("breaking") for r in reasons) else "REVIEW"


def _key(reason: dict) -> tuple[str, str]:
    return (reason.get("change", ""), reason.get("column", ""))


def _keys(reasons: list[dict]) -> set[tuple[str, str]]:
    return {_key(r) for r in reasons}


def _last_notification(product_id: str, asset: str) -> dict | None:
    rows = list(
        bq.query(
            f"""
            SELECT status, TO_JSON_STRING(all_reasons) AS reasons
            FROM `{NOTIFICATION_LOG}`
            WHERE data_product = @product AND asset = @asset
            ORDER BY notified_at DESC
            LIMIT 1
            """,
            job_config=bigquery.QueryJobConfig(
                query_parameters=[
                    bigquery.ScalarQueryParameter("product", "STRING", product_id),
                    bigquery.ScalarQueryParameter("asset", "STRING", asset),
                ]
            ),
        ).result()
    )
    if not rows:
        return None
    return {"status": rows[0]["status"], "reasons": json.loads(rows[0]["reasons"] or "[]")}


def _log(notification: dict, message_id: str) -> None:
    errors = bq.insert_rows_json(
        NOTIFICATION_LOG,
        [
            {
                "notified_at": datetime.datetime.now(datetime.UTC).isoformat(),
                "data_product": notification["dataProduct"],
                "asset": notification["asset"],
                "severity": notification["severity"],
                "status": notification["status"],
                "recipient": notification["recipient"]["googleGroup"],
                "new_reasons": json.dumps(notification["newReasons"]),
                "all_reasons": json.dumps(notification["allReasons"]),
                "message_id": message_id,
            }
        ],
    )
    if errors:
        raise RuntimeError(f"BigQuery insert failed: {errors}")


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
        params = {"pageToken": page_token} if page_token else None
        response = session.get(f"{DATAPLEX}/{parent}", params=params)
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
