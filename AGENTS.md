# datacloud-metadata-feed

<!-- SKELETON: the structure below is the convention; replace the content.
     Keep this operational — how to stand the domain up, what the tables are,
     how to verify, and the traps specific to THIS pipeline. Engineering
     standards do not belong here; they live in the user-level agent toolkit. -->

Standalone domain: Schema Drift Alerts with Metadata Change Feeds. <!-- one or two lines: what it does,
which Google Cloud products, and where the data comes from. -->

## Standing it up

```bash
./infra/scripts/setup.sh   # APIs + versioned state bucket + tofu init
cd infra && tofu apply     # zero required variables
```

**Tofu layout: flat** — everything in `infra/*.tf`, one apply, no `bootstrap/`
stage. Stated rather than left to be inferred, per `rules/tofu.md`.

`tofu apply` enables APIs, creates the datasets, runner SA and IAM, stands up
the Dataform repo, then triggers one pipeline run and blocks until it finishes.
`setup.sh` covers what can't run inside the graph — and on a private repo that
includes issuing Dataform's SSH deploy key, so the key never enters state.

Deploying elsewhere: change `project_id`'s default in `infra/variables.tf` —
that single value drives the provider, the resources, the derived bucket names
and the state bucket. Don't hardcode it anywhere else.

## Data model

Datasets are named for the **medallion stage**; the domain (`metadata_feed`)
is a Dataform tag, never a dataset or a table prefix.

| Dataset | Object | What |
| --- | --- | --- |
| `raw` | | <!-- landed source data, or delete this row --> |
| `processed` | | <!-- cleansed / typed --> |
| `serving` | | <!-- marts, models, predictions --> |
| `assertions` | | hard-fail checks; rows returned = failed run |
| `assertions` | | warning views; non-empty is expected |

`definitions/` mirrors this: `sources/`, `raw/`, `processed/`, `serving/`,
`assertions/`, `monitoring/`.

## Verifying

```sql
-- replace with the queries that prove THIS domain works
SELECT * FROM `assertions.<assertion_name>`;   -- must be empty
```

<!-- Include the check that proves the domain is actually working, not just
     running. For a model that means the predictions stratify; for an
     enrichment it means the output distribution is sane. A green pipeline
     is not the same as a correct one. -->

## Gotchas

<!-- Only traps specific to this pipeline. Some that recur across domains: -->

- **Incremental tables don't retroactively change existing rows.** Editing the
  SELECT only affects new rows; a full refresh re-pays for every model call.
  For a small correction, converge existing rows with a targeted `UPDATE`.
- **Adding a stage in `definitions/` means adding it to `infra/datasets.tf`.**
  Dataform auto-creates a missing dataset, so it silently works — then
  `tofu destroy` orphans it, unlabeled and untracked.
- **Gemini 3.x is global-endpoint only** and needs the full publisher URL; the
  bare model slug is rejected.
- **Non-interactive shells don't load `.envrc`**, so pass `--project` to
  `bq`/`gcloud` rather than trusting the ambient project.

## Teardown

```bash
cd infra && tofu destroy
```

Removes the domain including dataset contents. Deliberately **not** removed,
because Tofu didn't create them: the project and the state bucket
(`gs://datacloud-metadata-feed-tfstate`) — destroying the bucket holding the state
mid-destroy would be self-defeating.

## More

`README.md` for the human-facing walkthrough, `docs/` for architecture and
query guides.
