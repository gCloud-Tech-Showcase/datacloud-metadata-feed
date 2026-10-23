# datacloud-metadata-feed

Standalone demo: Schema Drift Alerts with Metadata Change Feeds. Feeds push BigQuery schema changes to Pub/Sub. Three Cloud Functions compare each asset's live schema with its schema contract. They mark the asset and its data product `READY` or `BLOCKED`, and notify the `data-stewards` access group. Source data is a copy of theLook eCommerce.

## Standing it up

```bash
./infra/scripts/setup.sh   # APIs + versioned state bucket + tofu init
cd infra && tofu apply     # zero required variables
./scripts/verify.sh --expect READY
```

**Tofu layout: flat.** Everything is in `infra/*.tf`, with one apply and no `bootstrap/` stage. `infra/modules/function/` is the one local module.

**No Dataform.** This is a deliberate exception to the domain template. Two tables and one view are not a pipeline, and keeping every change in Tofu makes the producer workflow one edit and one apply.

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

## Data model

Everything is in `us-central1`. The full resource list is in [`README.md`](README.md#what-gets-created).

| Dataset | Object | What |
| --- | --- | --- |
| `raw` | `thelook_orders`, `thelook_users` | Copies of theLook, made with `bq cp` (`infra/source_data.tf`) |
| `sales` | `orders`, `customers` | Golden tables, built with `CREATE OR REPLACE TABLE … AS SELECT` (`infra/data_product.tf`) |
| `marketing` | `customer_orders` | Consumer view, built with `CREATE OR REPLACE VIEW` (`infra/data_product.tf`) |
| `contract_monitoring` | `readiness_log`, `current_readiness` | Every readiness change, and the latest per asset and data product (`infra/monitoring.tf`) |
| `contract_monitoring` | `notification_log` | Every notification sent. `notify-stewards` reads it to skip repeats (`infra/notifications.tf`). |

The data product `sales-orders` holds the three `sales` and `marketing` objects as assets. Schema contracts are in `infra/contracts.tf`. The functions are in `functions/<name>/` and deploy through `infra/modules/function/`.

## Verifying

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

Each line is a guardrail. The reasons are in comments next to the code. The observed feed behaviour behind them is in [`docs/architecture.md`](docs/architecture.md#metadata-change-feed-behaviour).

- **Build golden tables and views with `CREATE OR REPLACE` from a `terraform_data`,** never with `google_bigquery_table` or `google_bigquery_job`.
- **Set the insights labels in every `CREATE OR REPLACE` statement** (`OPTIONS(labels=…)`). The statement drops labels, and the console's Insights tab needs them.
- **Use the project-number form in feed filters** (`projects/655216118709/locations/global/...`). The `dataplex-types` alias matches nothing.
- **Rebuild entry names from `fullQualifiedName`.** The event's `entryName` is an opaque ID on updates. The field has no "y", unlike the published format.
- **Never treat `updatedAspects` as a schema-change signal.** It lists `schema` on every table update.
- **Keep the two readiness aspect types separate,** or `rollup-product` triggers itself.
- **Make anything a feed must see on first apply depend on `time_sleep.feed_activation`.**
- **Keep every resource in `var.region`.** A data product and its assets must share a location.
- **Never import across `functions/<name>/` directories.** Each deploys on its own, so helpers are repeated.
- **Keep access groups in `infra/terraform.tfvars`** (gitignored). Never commit real group or user emails.
- **Keep the line numbers in `docs/01-schema-changes.md` in step with `infra/data_product.tf` and `infra/contracts.tf`.** The guide points at exact lines, so a change that shifts them updates the guide too.
- **Non-interactive shells don't load `.envrc`**, so pass `--project` to `bq` and `gcloud`.

## Teardown

```bash
cd infra && tofu destroy
```

Removes the domain, including dataset contents. What stays behind, and how to remove it, is listed in [`README.md`](README.md#cleanup). The schema contract aspects are dropped from state but not deleted. They go away with their tables.

## More

[`README.md`](README.md) is the human-facing overview. [`docs/`](docs/README.md) has the step-by-step guide, the quick reference and the architecture, including the message formats. The console screenshots in `docs/images/` carry their date in the caption. Retake them when the console changes. Engineering standards that apply to every repo live in the user-level agent toolkit, not here.
