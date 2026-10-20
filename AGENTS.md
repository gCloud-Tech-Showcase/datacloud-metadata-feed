# datacloud-metadata-feed

Standalone domain: Schema Drift Alerts with Metadata Change Feeds. Knowledge Catalog metadata change feeds push BigQuery schema changes to Pub/Sub. Two Cloud Functions compare each asset's live schema with a schema contract aspect and mark the asset and its data product `READY` or `BLOCKED`. Source data is a copy of theLook eCommerce.

## Standing it up

```bash
./infra/scripts/setup.sh   # APIs + versioned state bucket + tofu init
cd infra && tofu apply     # zero required variables, ~15 min on first apply
./scripts/verify.sh --expect READY
```

**Tofu layout: flat.** Everything is in `infra/*.tf`, with one apply and no `bootstrap/` stage.

**No Dataform.** This is a deliberate exception to the domain template. Two tables and one view are not a pipeline, and keeping every change in Tofu makes the demo's producer workflow one edit and one apply.

Deploying elsewhere: change `project_id`'s default in `infra/variables.tf`. That single value drives the provider, the resources, the derived bucket names and the state bucket. Never hardcode it anywhere else.

## Words

Use these terms consistently in code, docs and commit messages.

| Term | Meaning |
| --- | --- |
| asset | A BigQuery table or view listed in the data product |
| schema contract | The `schema-contract` aspect: the agreed columns of one asset |
| live schema | The system `schema` aspect that Knowledge Catalog keeps on every BigQuery entry |
| readiness | `READY` or `BLOCKED`, held in `asset-readiness` and `product-readiness` |
| reason | One difference between the live schema and the schema contract |
| breaking | A reason that blocks: `COLUMN_DROPPED`, `TYPE_CHANGED`, `MODE_CHANGED` |
| feed | A Knowledge Catalog metadata change feed |

## Object map

| Object | Type | Defined in |
| --- | --- | --- |
| `raw.thelook_orders`, `raw.thelook_users` | Tables (`bq cp` from theLook) | `infra/source_data.tf` |
| `sales.orders`, `sales.customers` | Tables (`CREATE OR REPLACE TABLE … AS SELECT`) | `infra/data_product.tf` |
| `marketing.customer_orders` | View (`CREATE OR REPLACE VIEW`) | `infra/data_product.tf` |
| `contract_monitoring.readiness_log` | Table, every readiness change | `infra/monitoring.tf` |
| `contract_monitoring.current_readiness` | View, latest row per asset and product | `infra/monitoring.tf` |
| `sales-orders` | Data product with 3 assets | `infra/data_product.tf` |
| `schema-contract`, `asset-readiness`, `product-readiness` | Aspect types | `infra/contracts.tf` |
| `schema-changes`, `readiness-changes` | Feeds and topics | `infra/feeds.tf` |
| `<topic>-demo` | Pull subscriptions for live demos, nothing consumes them | `infra/feeds.tf` |
| `feed-dead-letter-pull` | Messages that failed 5 deliveries | `infra/feeds.tf` |
| `<asset>-profile`, `<asset>-quality`, `<asset>-insights` | Data scans on all three assets, results published to the catalog | `infra/scans.tf` |
| `check-contract`, `rollup-product` | Cloud Functions (Python 3.12) | `infra/functions.tf`, `infra/modules/function/`, `functions/` |

## Verifying

```bash
./scripts/verify.sh --expect READY   # all assets and the data product READY, dead-letter empty
./scripts/verify.sh --smoke          # a throwaway table with a broken contract becomes BLOCKED
```

```sql
SELECT * FROM `contract_monitoring.current_readiness`;   -- one row per asset and product
```

```bash
gcloud dataplex datascans run orders-quality --location=us-central1 --project=datacloud-metadata-feed   # re-run a scan
```

## Gotchas

- **Never define a golden table as a `google_bigquery_table` with a schema block.** A dropped column forces replacement, which deletes the catalog entry and its contract. Build it with `CREATE OR REPLACE TABLE … AS SELECT` from a `terraform_data` keyed on the SQL. The catalog keeps the same entry and its aspects.
- **Do not use `google_bigquery_job` for data the next resource needs.** It returns as soon as the job is submitted, and a failed job still shows as created. `bq` waits and fails the apply.
- **The console's Insights tab needs labels on the table** (`dataplex-data-documentation-published-{scan,project,location}`). API-created scans do not add them, and `CREATE OR REPLACE` drops labels, so each statement sets them in `OPTIONS(labels=…)`. Profile and quality results show without labels.
- **Lineage is only recorded for DDL and DML.** `CREATE TABLE AS SELECT` and `CREATE VIEW` produce lineage. A `SELECT` into a destination table, or a view created through the API (`google_bigquery_table`), does not. Lineage can take up to 24 hours to appear.
- **Feed filters need the project-number form** (`projects/655216118709/locations/global/...`). The `dataplex-types` alias is accepted but matches nothing.
- **The event's `entryName` cannot be passed to `GetEntry`.** Rebuild the entry name from `fullQualifiedName`.
- **`updatedAspects` lists `schema` on every table update**, not only on schema changes. Do not use it to decide whether the schema changed.
- **Keep the two readiness aspect types separate.** Merging them makes `rollup-product` trigger itself through the readiness feed.
- **A new feed takes up to 10 minutes to publish.** Anything that must be seen by a feed on first apply depends on `time_sleep.feed_activation`.
- **Data product assets must be in the same location as the data product.** Every resource uses `var.region`.
- **Each function directory deploys on its own.** Never import across `functions/<name>/` directories, so shared helpers are repeated.
- **Non-interactive shells don't load `.envrc`**, so pass `--project` to `bq` and `gcloud`.

## Teardown

```bash
cd infra && tofu destroy
```

Removes the domain, including dataset contents. Not removed, because Tofu did not create them: the project and the state bucket (`gs://datacloud-metadata-feed-tfstate`). The contract aspects are dropped from state but not deleted. They go away with their tables.

## More

`README.md` for the human-facing overview, `docs/01-demo.md` for the live walkthrough, `docs/architecture.md` for design decisions and observed feed behaviour.
