# datacloud-metadata-feed

Standalone domain: Schema Drift Alerts with Metadata Change Feeds. Knowledge Catalog metadata change feeds push BigQuery schema changes to Pub/Sub. Three Cloud Functions compare each asset's live schema with its schema contract, mark the asset and its data product `READY` or `BLOCKED`, and notify the data product's steward group. Source data is a copy of theLook eCommerce.

## Standing it up

```bash
./infra/scripts/setup.sh   # APIs + versioned state bucket + tofu init
cd infra && tofu apply     # zero required variables, ~15 min on first apply
./scripts/verify.sh --expect READY
```

**Tofu layout: flat.** Everything is in `infra/*.tf`, with one apply and no `bootstrap/` stage. `infra/modules/function/` is the one local module.

**No Dataform.** This is a deliberate exception to the domain template. Two tables and one view are not a pipeline, and keeping every change in Tofu makes the demo's producer workflow one edit and one apply.

**One project ID.** `project_id`'s default in `infra/variables.tf` drives the providers, the resources, the bucket names and `setup.sh`. Never hardcode it in `.tf` files or scripts. In commands, use a `PROJECT_ID` shell variable.

**Times are UTC** in logs, `scripts/show-feed.sh` output and the BigQuery history tables.

## Words

Use these terms consistently in code, docs and commit messages.

| Term | Meaning |
| --- | --- |
| Knowledge Catalog | The product. Its APIs, roles and `gcloud` commands are still named `dataplex`. |
| asset | A BigQuery table or view listed in the data product |
| schema contract | The `schema-contract` aspect: the agreed columns of one asset |
| live schema | The system `schema` aspect that Knowledge Catalog keeps on every BigQuery entry |
| readiness | `READY` or `BLOCKED`, held in `asset-readiness` and `product-readiness` |
| reason | One difference between the live schema and the schema contract |
| breaking | A reason that blocks: `COLUMN_DROPPED`, `TYPE_CHANGED`, `MODE_CHANGED` |
| feed | A Knowledge Catalog metadata change feed |
| notification | A message on `schema-change-notifications`, sent when an asset's set of reasons changes |
| severity | `BREAKING`, `REVIEW` (only added columns) or `RESOLVED` (no reasons left) |
| access group | A data product's named Google Group. `var.notify_access_group` (default `data-stewards`) names the notification recipient. |

## Object map

The single inventory of what the repo creates. Update it in the same change as the `.tf` file.

| Object | Type | Defined in |
| --- | --- | --- |
| `raw`, `sales`, `marketing`, `contract_monitoring` | BigQuery datasets in `us-central1` | `infra/datasets.tf` |
| `raw.thelook_orders`, `raw.thelook_users` | Tables (`bq cp` from theLook) | `infra/source_data.tf` |
| `sales.orders`, `sales.customers` | Tables (`CREATE OR REPLACE TABLE … AS SELECT`) | `infra/data_product.tf` |
| `marketing.customer_orders` | View (`CREATE OR REPLACE VIEW`) | `infra/data_product.tf` |
| `sales-orders` | Data product with 3 assets and optional access groups | `infra/data_product.tf` |
| `schema-contract`, `asset-readiness`, `product-readiness` | Aspect types, and the schema contracts | `infra/contracts.tf` |
| `schema-changes`, `readiness-changes` | Feeds and their topics | `infra/feeds.tf` |
| `<topic>-push`, `readiness-changes-notify` | Push subscriptions to the functions | `infra/feeds.tf` |
| `<topic>-demo` | Pull subscriptions for live demos. Nothing consumes them. | `infra/feeds.tf`, `infra/notifications.tf` |
| `feed-dead-letter`, `feed-dead-letter-pull` | Messages that failed 5 deliveries | `infra/feeds.tf` |
| `schema-change-notifications` | Topic for steward notifications | `infra/notifications.tf` |
| `check-contract`, `rollup-product`, `notify-stewards` | Cloud Functions (Python 3.12), deployed one after another | `infra/functions.tf`, `infra/modules/function/`, `functions/` |
| `drift-functions`, `function-builder`, `feed-push-invoker` | Service accounts: function runtime, function build, Pub/Sub push | `infra/functions.tf` |
| `<project>-function-source` | Bucket holding the zipped function source | `infra/functions.tf` |
| `contract_monitoring.readiness_log`, `current_readiness` | Table of every readiness change, and a view of the latest per asset and product | `infra/monitoring.tf` |
| `contract_monitoring.notification_log` | Table of every notification sent. Also how repeats are skipped. | `infra/notifications.tf` |
| `<asset>-profile`, `<asset>-quality`, `<asset>-insights` | Data scans on all three assets, results published to the catalog | `infra/scans.tf` |
| `data-scanner` | Service account the scans run as | `infra/scans.tf` |

## Checking a change

```bash
cd infra && tofu fmt -recursive && tofu validate && tofu plan
ruff format --line-length 100 functions/ && ruff check --line-length 100 functions/
bash -n scripts/*.sh infra/scripts/*.sh
```

There are no unit tests. After an apply:

```bash
./scripts/verify.sh --expect READY   # all assets and the data product READY, dead-letter empty
./scripts/verify.sh --smoke          # a throwaway table with a broken contract becomes BLOCKED
bq --project_id="$PROJECT_ID" query --nouse_legacy_sql 'SELECT * FROM contract_monitoring.current_readiness'
gcloud dataplex datascans run orders-quality --location=us-central1 --project="$PROJECT_ID"   # re-run a scan
```

## Gotchas

Each line is a guardrail. The reasons and the observed feed behaviour behind them are in [`docs/architecture.md`](docs/architecture.md#design-decisions).

- **Build golden tables and views with `CREATE OR REPLACE` from a `terraform_data`,** never with `google_bigquery_table` or `google_bigquery_job`.
- **Set the insights labels in every `CREATE OR REPLACE` statement** (`OPTIONS(labels=…)`). The statement drops labels, and the console's Insights tab needs them.
- **Use the project-number form in feed filters** (`projects/655216118709/locations/global/...`). The `dataplex-types` alias matches nothing.
- **Rebuild entry names from `fullQualifiedName`.** The event's `entryName` is an opaque ID on updates.
- **Never treat `updatedAspects` as a schema-change signal.** It lists `schema` on every table update.
- **Keep the two readiness aspect types separate,** or `rollup-product` triggers itself.
- **Make anything a feed must see on first apply depend on `time_sleep.feed_activation`.**
- **Keep every resource in `var.region`.** A data product and its assets must share a location.
- **Never import across `functions/<name>/` directories.** Each deploys on its own, so helpers are repeated.
- **Keep access groups in `infra/terraform.tfvars`** (gitignored). Never commit real group or user emails.
- **Non-interactive shells don't load `.envrc`**, so pass `--project` to `bq` and `gcloud`.

## Teardown

```bash
cd infra && tofu destroy
```

Removes the domain, including dataset contents. What stays behind, and how to remove it, is listed in [`README.md`](README.md#cleanup). The schema contract aspects are dropped from state but not deleted. They go away with their tables.

## More

| Doc | Covers |
| --- | --- |
| [`README.md`](README.md) | Human-facing overview, prerequisites, quickstart, cleanup |
| [`docs/01-demo.md`](docs/01-demo.md) | The live walkthrough |
| [`docs/architecture.md`](docs/architecture.md) | Data flow, design decisions, observed feed behaviour, failure modes |
