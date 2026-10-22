# Schema Drift Alerts Quick Reference

Copy-paste commands and queries, with sample output. Run them from the repository root, with `PROJECT_ID` set to your project:

```bash
PROJECT_ID=<your-project-id>
```

> **Sample output only.** Times, table names and history rows change with every run. All times are UTC. Check the shape of the output, not the exact values.

---

## 1. Check readiness

```bash
./scripts/verify.sh --expect READY
```

```text
Project: <your-project-id> (us-central1)

==> Asset readiness
  sales.orders                       READY
  sales.customers                    READY
  marketing.customer_orders          READY

==> Product readiness
  sales-orders                       READY

==> Dead-letter subscription
  empty

OK
```

Without `--expect`, the script prints the readiness and the reasons, and does not fail on `BLOCKED`.

---

## 2. Run the end-to-end check

```bash
./scripts/verify.sh --smoke
```

The script creates a throwaway table, attaches a contract that does not match, and waits up to 120 seconds for `BLOCKED`:

```text
==> Smoke test
  created contract_monitoring.smoke_1792682951 with a INTEGER column
  attached a contract that expects a STRING column
  PASS: BLOCKED TYPE_CHANGED a: Type changed from STRING to INTEGER.
```

The script deletes the table when it finishes.

---

## 3. Show the feed messages

```bash
./scripts/show-feed.sh                     # schema-changes feed
./scripts/show-feed.sh readiness-changes   # readiness-changes feed
```

One line per message: time, change type, entry type, entry, and the aspects that changed.

```text
15:29:15 CREATE bigquery-table bigquery:<project>.contract_monitoring.smoke_1792682951 schema, storage, bigquery-policy, bigquery-table
15:29:16 UPDATE bigquery-table bigquery:<project>.contract_monitoring.smoke_1792682951 schema-contract
15:29:18 UPDATE bigquery-table bigquery:<project>.contract_monitoring.smoke_1792682951 asset-readiness
```

The message lists the aspects that changed, but not what changed in them. That is why `check-contract` compares the live schema with the contract.

---

## 4. Show the steward notifications

```bash
./scripts/show-feed.sh notifications
```

```text
14:02:56 BREAKING Sales Orders / sales.orders  READY -> BLOCKED
         to: sales-orders-stewards@example.com
         new      COLUMN_DROPPED num_of_item: Column was removed (agreed INTEGER).
```

If you did not set access groups in `infra/terraform.tfvars`, the recipient line is:

```text
         to: (none: No 'data-stewards' access group on this data product, so there is no recipient.)
```

---

## 5. Query the current readiness

```bash
bq --project_id="$PROJECT_ID" query --nouse_legacy_sql \
  "SELECT level, name, status, contract_version, reasons
   FROM contract_monitoring.current_readiness
   WHERE level = 'PRODUCT' OR name NOT LIKE '%.contract_monitoring.%'
   ORDER BY level, name"
```

```text
+---------+-----------------------------------------------------+--------+------------------+---------+
|  level  |                        name                         | status | contract_version | reasons |
+---------+-----------------------------------------------------+--------+------------------+---------+
| ASSET   | bigquery:<project>.marketing.customer_orders        | READY  | 1                | []      |
| ASSET   | bigquery:<project>.sales.customers                  | READY  | 1                | []      |
| ASSET   | bigquery:<project>.sales.orders                     | READY  | 1                | []      |
| PRODUCT | sales-orders                                        | READY  | NULL             | []      |
+---------+-----------------------------------------------------+--------+------------------+---------+
```

The `WHERE` clause hides the throwaway tables from `verify.sh --smoke`.

---

## 6. Query the notification history

```bash
bq --project_id="$PROJECT_ID" query --nouse_legacy_sql \
  "SELECT notified_at, asset, severity, status, recipient
   FROM contract_monitoring.notification_log
   ORDER BY notified_at DESC
   LIMIT 10"
```

```text
+---------------------+---------------------------+----------+---------+-----------------------------------+
|     notified_at     |           asset           | severity | status  |             recipient             |
+---------------------+---------------------------+----------+---------+-----------------------------------+
| 2026-10-21 18:07:01 | marketing.customer_orders | RESOLVED | READY   | sales-orders-stewards@example.com |
| 2026-10-21 18:02:56 | marketing.customer_orders | BREAKING | BLOCKED | sales-orders-stewards@example.com |
| 2026-10-21 18:02:32 | marketing.customer_orders | REVIEW   | READY   | sales-orders-stewards@example.com |
+---------------------+---------------------------+----------+---------+-----------------------------------+
```

---

## 7. Re-run a data scan

```bash
gcloud dataplex datascans run orders-quality --location=us-central1 --project="$PROJECT_ID"
```

The results show on the asset's **Data quality** tab in Knowledge Catalog after about a minute. The other scans are `<asset>-profile` and `<asset>-insights`, where `<asset>` is `orders`, `customers` or `customer-orders`.

---

## 8. Clear the demo subscriptions

```bash
./scripts/show-feed.sh --clear
```

```text
Cleared schema-changes-demo
Cleared readiness-changes-demo
Cleared schema-change-notifications-demo
```

Do this before a demo, so that the audience sees only their own messages.

---

## Navigation

[← Overview](README.md) | [Demo guide](01-demo.md) | [Architecture](architecture.md)
