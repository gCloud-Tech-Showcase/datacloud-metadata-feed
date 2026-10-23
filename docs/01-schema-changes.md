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

In the console, open **Knowledge Catalog**, then the **Sales Orders** data product. Its **Aspects** tab shows `Product readiness`. If you set access groups in `infra/terraform.tfvars`, the **Access groups & permissions** tab includes `data-stewards`.

The data product's **Contract** tab stays empty. It holds Knowledge Catalog's own contract for the whole data product, which this demo does not use. The schema contracts in this demo are aspects on each asset.

Open `orders` from the data product's **Assets** tab.

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

### Optional: look inside the feed message

Do this before you run `show-feed.sh`, which acknowledges the messages it prints. The feed sends a plain Pub/Sub message, so you can read it like any other.

In the console, open **Pub/Sub**, then **Subscriptions**, then `schema-changes-demo`. On the **Messages** tab, leave **Enable ack messages** cleared and click **Pull**. The console decodes the payload into **Message body**, and lists the attributes next to it (verified on 2026-10-23).

In the terminal, pull the raw message:

```bash
gcloud pubsub subscriptions pull schema-changes-demo --project="$PROJECT_ID" --limit=1 --format=json
```

```json
[
  {
    "ackId": "...",
    "message": {
      "attributes": {
        "entry_change_type": "UPDATE",
        "entry_type": "projects/655216118709/locations/global/entryTypes/bigquery-table",
        "feed_name": "projects/<project-number>/locations/us-central1/metadataFeeds/schema-changes",
        "timestamp": "2026-10-23T18:15:50.794431Z"
      },
      "data": "eyJlbnRyeU5hbWUiOiJwcm9qZWN0cy8...",
      "messageId": "22440586900560602",
      "publishTime": "2026-10-23T18:15:51.054Z"
    }
  }
]
```

The payload in `data` is base64-encoded JSON. To decode it:

```bash
gcloud pubsub subscriptions pull schema-changes-demo --project="$PROJECT_ID" --limit=1 \
  --format='value(message.data.decode(base64))'
```

```json
{
  "entryName": "projects/<project-number>/locations/us-central1/entryGroups/@bigquery/entries/d80e9b91-5763-4a55-bb07-241569859e6f",
  "fullQualifiedName": "bigquery:<project>.sales.orders",
  "updatedAspects": [
    "projects/655216118709/locations/global/aspectTypes/schema",
    "projects/655216118709/locations/global/aspectTypes/storage",
    "projects/655216118709/locations/global/aspectTypes/bigquery-policy",
    "projects/655216118709/locations/global/aspectTypes/bigquery-table"
  ]
}
```

Neither command acknowledges the message, so it comes back after 10 seconds and `show-feed.sh` still prints it. Three things to notice:

| What you see | What it means for the functions |
| --- | --- |
| The message names the entry and the aspects that changed, but not what changed | `check-contract` reads the entry and compares the live schema with the contract |
| `updatedAspects` lists `schema` and three other system aspects | BigQuery lists them on every table update, even when the schema did not change. It is not a schema-change signal. |
| `entryName` ends in an opaque ID, not the table path | The functions rebuild the entry name from `fullQualifiedName` |

The format of every message in this demo is in [Message Formats](architecture.md#message-formats).

Now look at the same message with `show-feed.sh`, which prints one line per message. The `-demo` subscription has its own copy of every message, so reading it here does not affect the functions:

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

The quality scan gives a second, slower signal for the same change. Two of the six `orders` quality rules check `num_of_item`. Re-run the scan:

```bash
gcloud dataplex datascans run orders-quality --location=us-central1 --project="$PROJECT_ID"
```

After about a minute, the run fails as a whole. The two rules refer to a column that no longer exists, so the scan does not evaluate any of the six rules. To see the failed run and its message:

```bash
JOB_ID=$(gcloud dataplex datascans jobs list --datascan=orders-quality --location=us-central1 --project="$PROJECT_ID" --limit=1 --format='value(name)')
gcloud dataplex datascans jobs describe "$JOB_ID" --datascan=orders-quality --location=us-central1 --project="$PROJECT_ID" --format='value(state,message)'
```

```text
FAILED	column `num_of_item` configured in DataQualityRule doesn't exist in entity `<project>.sales.orders`
```

The **Data Quality** tab on the `orders` entry does not change. It shows the latest published result, and a failed run publishes none, so the tab still shows the last successful run at 100% (verified on 2026-10-23).

Compare the two signals. The feed flagged the change within seconds and named the column. The scan only catches it when it runs, and then no rule gives a result.

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

The apply reverts the SQL a moment before the contracts, so an asset can show `BLOCKED` for a few seconds before it settles on `READY`. You may see a matching `BREAKING` and `RESOLVED` notification. If the asset is `READY` again before `notify-stewards` reads it, there is no notification. Re-running the quality scan gives a new successful run, so the latest job is no longer the failed one from Step 2. Clearing the `-demo` subscriptions means you see only the messages from your next change.

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
