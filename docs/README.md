# Schema Drift Alerts

Catch a breaking schema change in seconds, before it reaches the teams that use the data. Back to [`AGENTS.md`](../AGENTS.md) or the [repository README](../README.md).

## What You'll Build

A data mesh with one data product, governed by Knowledge Catalog:

1. **Schema contracts:** each asset carries the columns, types and modes that its producers and consumers agreed.
2. **Change detection:** a metadata change feed sends every catalog change to Pub/Sub, and a Cloud Function compares the live schema with the contract.
3. **Readiness:** the asset and its data product show `READY` or `BLOCKED` in the catalog, with one reason per difference.
4. **Notifications:** the data product's stewards get a message that lists the new and resolved reasons.

## Technologies

| Service | Purpose |
| --- | --- |
| Knowledge Catalog | Data product, schema contracts as aspects, readiness, data scans |
| Metadata change feeds | Send every catalog change to Pub/Sub, without polling |
| Pub/Sub | Push feed messages to the functions, and carry the notifications |
| Cloud Functions | Compare schemas, roll readiness up to the data product, notify stewards |
| BigQuery | The golden tables and view, and the history of readiness changes and notifications |

## Results

- **Seconds** from a schema change to a `BLOCKED` data product and a notification
- **3 breaking reasons** detected: `COLUMN_DROPPED`, `TYPE_CHANGED`, `MODE_CHANGED`
- **Added columns** reported for review, without blocking

## Guides

| Guide | Covers |
| --- | --- |
| [Schema Changes](01-schema-changes.md) | Break the contracts, watch the catalog react, then fix them |
| [Quick Reference](quick.md) | Copy-paste commands and queries, with sample output |
| [Architecture](architecture.md) | Pipeline diagram, data flow, components, observed feed behaviour |

The source data is a copy of theLook eCommerce, made by `tofu apply`. See the [repository README](../README.md) for setup.
