# Demo walkthrough

The demo plays two roles. The **sales team** owns the golden tables and changes their SQL. The **platform team** watches readiness in Knowledge Catalog. Every change goes through `tofu apply`, the same way a producer ships a change in real life.

Run all commands from the repository root. Allow about 10 seconds after each apply for the feeds and functions to finish.

| Step | Change | `orders` | `customer_orders` | Data product |
| --- | --- | --- | --- | --- |
| 0 | None | `READY` | `READY` | `READY` |
| 1 | Add a column to `orders` | `READY` (`COLUMN_ADDED`) | `READY` | `READY` |
| 2 | Drop a column from `orders` | `BLOCKED` | `READY` | `BLOCKED` |
| 3 | Change a type in `customer_orders` | `BLOCKED` | `BLOCKED` | `BLOCKED` |
| 4 | Revise both contracts | `READY` | `READY` | `READY` |
| 5 | Reset | `READY` | `READY` | `READY` |

## 0. Start from READY

```bash
./scripts/verify.sh --expect READY
./scripts/show-feed.sh --clear
```

In the console, open **Knowledge Catalog**, then the **Sales Orders** data product. Its aspects show `Product readiness`. Open `orders` from the data product's **Assets** tab.

On the `orders` entry, the **Details** tab shows `Schema contract` and `Asset readiness` among the aspects. The same entry also carries the scan results that `tofu apply` started:

| Tab | Scan | Shows |
| --- | --- | --- |
| **Data profile** | `orders-profile` | Null rate, distinct values and top values per column |
| **Data quality** | `orders-quality` | 6 rules, all passing |
| **Insights** | `orders-insights` | Gemini-generated sample questions with SQL, grounded in the profile |

`customer_orders` has profile and quality results too. Its catalog page has no **Insights** tab because it is a view. Open it in BigQuery Studio to show its insights.

## 1. Non-breaking change: add a column

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

Show the feed message that triggered the check. The `-demo` subscription has its own copy of every message, so acking here does not affect the functions:

```bash
./scripts/show-feed.sh
```

The message names the entry and lists the aspects that changed. It does not say what changed in the schema. That is why `check-contract` compares the live schema with the contract.

## 2. Breaking change: drop a column

Remove `num_of_item` from the same query:

```sql
SELECT order_id, user_id, status, created_at, gender
FROM `${var.project_id}.raw.thelook_orders`
```

```bash
(cd infra && tofu apply)
./scripts/verify.sh
```

`orders` is `BLOCKED` with `COLUMN_DROPPED num_of_item`. A few seconds later, the second feed fires and the data product is `BLOCKED` too, naming `sales.orders`. Refresh both entries in the console to show the aspects.

```bash
./scripts/show-feed.sh readiness-changes
```

The quality scan gives a second, slower signal for the same change. Re-run it:

```bash
gcloud dataplex datascans run orders-quality --location=us-central1 --project=datacloud-metadata-feed
```

After about a minute, the run fails as a whole, with the message "column `num_of_item` configured in DataQualityRule doesn't exist in entity". Show it in the scan's **Jobs history**. The feed flagged the change within seconds. The scan only catches it when it runs, and it stops evaluating the other rules.

## 3. Breaking change on the consumer side: change a type

In the `customer_orders_view` query, cast the count to `NUMERIC`:

```sql
SELECT c.user_id, c.country, CAST(COUNT(o.order_id) AS NUMERIC) AS order_count
```

```bash
(cd infra && tofu apply)
./scripts/verify.sh
```

`customer_orders` is `BLOCKED` with `TYPE_CHANGED order_count`, from `INTEGER` to `NUMERIC`. The data product now lists two blocked assets.

## 4. Deliberate change: revise the contracts

The producers agree the new schemas with their consumers. In `infra/contracts.tf`:

- **`orders`:** set `version = "2"`, remove the `num_of_item` field, and add `{ name = "gender", dataType = "STRING", mode = "NULLABLE" }`.
- **`customer_orders`:** set `version = "2"`, and change `order_count` to `dataType = "NUMERIC"`.

```bash
(cd infra && tofu apply)
./scripts/verify.sh --expect READY
```

Updating the contract aspect is itself a catalog change, so the `schema-changes` feed fires and `check-contract` re-evaluates. Both assets return to `READY`, and then the data product does too.

Show the history:

```sql
SELECT logged_at, level, name, status, contract_version, reasons
FROM `datacloud-metadata-feed.contract_monitoring.readiness_log`
ORDER BY logged_at DESC
LIMIT 20;
```

## 5. Reset for the next run

```bash
git checkout infra/data_product.tf infra/contracts.tf
(cd infra && tofu apply)
gcloud dataplex datascans run orders-quality --location=us-central1 --project=datacloud-metadata-feed
./scripts/verify.sh --expect READY
./scripts/show-feed.sh --clear
```

The apply reverts the SQL a moment before the contract, so `orders` can show `BLOCKED` for a few seconds before it settles on `READY`. Re-running the quality scan replaces the failed run from step 2. Clearing the `-demo` subscriptions means the next audience sees only their own messages.
