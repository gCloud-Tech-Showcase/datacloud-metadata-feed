# Schema Changes

Break the schema contracts on purpose, watch the catalog react, then fix them.

---

In this scenario, the **sales team** owns the golden tables and the **marketing team** builds a view on them. You make the changes as the producer. Every change is an edit in `infra/` and a `tofu apply`, the same way a producer ships a change in real life.

Run all commands from the repository root, with `PROJECT_ID` set to your project:

```bash
PROJECT_ID=<your-project-id>
```

Allow about 10 seconds after each apply for the feeds and functions to finish. Times in the output are UTC.

| Step | Change | `orders` | `customer_orders` | Data product | Notification |
| --- | --- | --- | --- | --- | --- |
| 0 | None | `READY` | `READY` | `READY` | None |
| 1 | Add a column to `orders` | `READY` (`COLUMN_ADDED`) | `READY` | `READY` | `REVIEW` |
| 2 | Drop a column from `orders` | `BLOCKED` | `READY` | `BLOCKED` | `BREAKING` |
| 3 | Change a type in `customer_orders` | `BLOCKED` | `BLOCKED` | `BLOCKED` | `BREAKING` |
| 4 | Revise both contracts | `READY` | `READY` | `READY` | `RESOLVED` (twice) |
| 5 | Reset | `READY` | `READY` | `READY` | Possibly a brief `BREAKING`, then `RESOLVED` |

---

## Step 0: Start from READY

```bash
./scripts/verify.sh --expect READY
./scripts/show-feed.sh --clear
```

In the console, open **Knowledge Catalog**, then the **Sales Orders** data product. Its aspects show `Product readiness`. If you set access groups in `infra/terraform.tfvars`, they include `data-stewards`. Open `orders` from the data product's **Assets** tab.

On the `orders` entry, the **Details** tab shows `Schema contract` and `Asset readiness` among the aspects. The same entry also carries the scan results that `tofu apply` started (verified on 2026-10-20):

| Tab | Scan | Shows |
| --- | --- | --- |
| **Data profile** | `orders-profile` | Null rate, distinct values and top values per column |
| **Data quality** | `orders-quality` | 6 rules, all passing |
| **Insights** | `orders-insights` | Gemini-generated sample questions with SQL, grounded in the profile |

`customer_orders` has profile and quality results too. Its catalog page has no **Insights** tab because it is a view. To see its insights, open it in BigQuery Studio.

---

## Step 1: Add a column (not breaking)

In `infra/data_product.tf`, add `gender` to the `orders` query:

```sql
SELECT order_id, user_id, status, created_at, num_of_item, gender
FROM `${var.project_id}.raw.thelook_orders`
```

```bash
(cd infra && tofu apply)
./scripts/verify.sh
```

`orders` stays `READY`, with the reason `COLUMN_ADDED gender`. Consumers are not affected by a new column, so nothing is blocked.

Look at the feed message that triggered the check. The `-demo` subscription has its own copy of every message, so reading it here does not affect the functions:

```bash
./scripts/show-feed.sh
```

The message names the entry and lists the aspects that changed. It does not say what changed in the schema. That is why `check-contract` compares the live schema with the contract.

The stewards still hear about it, because the contract is broken and the new column may need review:

```bash
./scripts/show-feed.sh notifications
```

---

## Step 2: Drop a column (breaking)

Remove `num_of_item` from the same query:

```sql
SELECT order_id, user_id, status, created_at, gender
FROM `${var.project_id}.raw.thelook_orders`
```

```bash
(cd infra && tofu apply)
./scripts/verify.sh
```

`orders` is `BLOCKED` with `COLUMN_DROPPED num_of_item`. A few seconds later, the second feed fires and the data product is `BLOCKED` too, naming `sales.orders`.

To see the new aspect values, refresh both entries in the console.

```bash
./scripts/show-feed.sh readiness-changes
./scripts/show-feed.sh notifications
```

The notification is `BREAKING` and lists `COLUMN_DROPPED num_of_item` as new. It goes to the `data-stewards` access group. Without access groups, the `to:` line says there is no recipient.

The quality scan gives a second, slower signal for the same change. Re-run it:

```bash
gcloud dataplex datascans run orders-quality --location=us-central1 --project="$PROJECT_ID"
```

After about a minute, the run fails as a whole, with the message "column `num_of_item` configured in DataQualityRule doesn't exist in entity" (verified on 2026-10-20).

The failed run is in the scan's **Jobs history**. The feed flagged the change within seconds. The scan only catches it when it runs, and it stops evaluating the other rules.

---

## Step 3: Change a type in the consumer view (breaking)

In `infra/data_product.tf`, in the `customer_orders_view` query, cast the count to `NUMERIC`:

```sql
SELECT c.user_id, c.country, CAST(COUNT(o.order_id) AS NUMERIC) AS order_count
```

```bash
(cd infra && tofu apply)
./scripts/verify.sh
./scripts/show-feed.sh notifications
```

`customer_orders` is `BLOCKED` with `TYPE_CHANGED order_count`, from `INTEGER` to `NUMERIC`. The data product now lists two blocked assets, and the stewards get a `BREAKING` notification for `customer_orders`.

---

## Step 4: Revise the contracts

The producers agree the new schemas with their consumers. In `infra/contracts.tf`:

- **`orders`:** set `version = "2"`, remove the `num_of_item` field, and add `{ name = "gender", dataType = "STRING", mode = "NULLABLE" }`.
- **`customer_orders`:** set `version = "2"`, and change `order_count` to `dataType = "NUMERIC"`.

```bash
(cd infra && tofu apply)
./scripts/verify.sh --expect READY
```

Updating the contract aspect is itself a catalog change, so the `schema-changes` feed fires and `check-contract` re-evaluates. Both assets return to `READY`, and then the data product does too.

The `RESOLVED` notifications list what was resolved:

```bash
./scripts/show-feed.sh notifications
```

To see the history, run these queries in BigQuery Studio, with your project selected:

```sql
SELECT logged_at, level, name, status, contract_version, reasons
FROM contract_monitoring.readiness_log
ORDER BY logged_at DESC
LIMIT 20;

SELECT notified_at, asset, severity, status, recipient, new_reasons
FROM contract_monitoring.notification_log
ORDER BY notified_at DESC;
```

---

## Step 5: Reset

Warning: `git checkout` discards every uncommitted edit in these two files, not only the edits from this guide.

```bash
git checkout infra/data_product.tf infra/contracts.tf
(cd infra && tofu apply)
gcloud dataplex datascans run orders-quality --location=us-central1 --project="$PROJECT_ID"
./scripts/verify.sh --expect READY
./scripts/show-feed.sh --clear
```

The apply reverts the SQL a moment before the contracts, so an asset can show `BLOCKED` for a few seconds before it settles on `READY`. You may see a matching `BREAKING` and `RESOLVED` notification. If the asset is `READY` again before `notify-stewards` reads it, there is no notification. Re-running the quality scan replaces the failed run from step 2. Clearing the `-demo` subscriptions means you see only the messages from your next change.

---

## Key Takeaways

| Capability | Technology | Business value |
| --- | --- | --- |
| Detect a breaking schema change within seconds | Metadata change feeds, Cloud Functions | Consumers hear about a breaking change before they build on it |
| Report an added column without blocking | Schema contract aspect | New columns get a review, and nothing downstream stops |
| Mark the whole data product `BLOCKED` | Data product, `product-readiness` aspect | One status tells consumers whether the data product is safe to use |
| Notify the stewards once per change | Pub/Sub, data product access groups | The right people get the alert, without repeats |
| Keep every change in a table | BigQuery | The history is one query away |

---

## What's Next

Try these on your own. Predict the result first, then check it with `./scripts/verify.sh` and `./scripts/show-feed.sh notifications`.

| Experiment | How |
| --- | --- |
| Break a contract on the mode | In `infra/contracts.tf`, set `mode = "REQUIRED"` on `country` in the `customers` contract, then apply. The live column is `NULLABLE`, so you get `MODE_CHANGED`. |
| Change a table outside Tofu | Run `bq --project_id="$PROJECT_ID" query --nouse_legacy_sql 'ALTER TABLE sales.customers DROP COLUMN last_name'`. To rebuild the table, run `tofu apply -replace='terraform_data.golden_table["customers"]'` in `infra/`. |
| Put a contract on a table outside the data product | Add a contract for `raw.thelook_orders` to `local.contracts` in `infra/contracts.tf`, with only some of its columns. Then check which functions react, and which do not. Undo steps are below the table. |

To undo the contract on `raw.thelook_orders`, remove it from `infra/contracts.tf` and apply. Tofu cannot delete aspects from an entry that BigQuery owns, so remove the contract and readiness aspects yourself:

```bash
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
gcloud dataplex entries update "bigquery.googleapis.com/projects/$PROJECT_ID/datasets/raw/tables/thelook_orders" \
  --entry-group=@bigquery --location=us-central1 --project="$PROJECT_ID" \
  --remove-aspects="$PROJECT_NUMBER.us-central1.schema-contract@*,$PROJECT_NUMBER.us-central1.asset-readiness@*"
```

The rows in `contract_monitoring.readiness_log` stay, so `current_readiness` still lists the table.

To learn how the pieces fit together, read the [architecture](architecture.md).

---

## Navigation

[← Overview](README.md) | [Quick Reference](quick.md) | [Architecture](architecture.md)
