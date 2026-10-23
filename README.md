# Schema Drift Alerts with Metadata Change Feeds

<!-- SKELETON: replace the content, keep the structure. This is the
     human-facing walkthrough; AGENTS.md is the agent-facing one. -->

Standalone and self-contained — clone it, point it at your own GCP project, and
`tofu apply` builds everything including the data.

## Architecture

<!-- A short diagram or bullet flow: source → stages → outputs. -->

## Prerequisites

1. **A GCP project with billing** (one-time, created out-of-band):
   ```bash
   gcloud projects create datacloud-metadata-feed --organization=<YOUR_ORG_ID>
   gcloud billing projects link datacloud-metadata-feed --billing-account=<YOUR_BILLING_ACCOUNT>
   gcloud auth application-default login
   ```
2. **[OpenTofu](https://opentofu.org) ≥ 1.6** (`tofu`). Terraform ≥ 1.6 works too.
3. `curl`, `python3`, `gsutil` — all ship with `gcloud`.

No GitHub token is needed: the Dataform repository pulls over an *anonymous* git link, which works because this repo is public.

## Quickstart

```bash
./infra/scripts/setup.sh   # one-time per project: APIs + state bucket + tofu init
cd infra && tofu apply     # zero required variables — every one has a default
```

`setup.sh` handles what Terraform can't bootstrap itself: it enables the Cloud
Resource Manager / Service Usage APIs, creates a **versioned** state bucket at
`gs://datacloud-metadata-feed-tfstate`, and runs `tofu init` against it. Re-running is a
safe no-op.

To deploy elsewhere, change `project_id`'s default in `infra/variables.tf` —
that one value drives everything — or pass `--project=<id>` to `setup.sh`.

> **State lives remotely** and versioned, so a bad apply is recoverable. Each
> fork gets its own bucket in its own project; nothing is shared.

## Verify

```sql
-- replace with this domain's real checks
SELECT * FROM `serving.<table>` LIMIT 10;
SELECT * FROM `assertions.<assertion>`;   -- empty = healthy
```

## What gets created

| Resource | Notes |
| --- | --- |
| BigQuery datasets | one per medallion stage, plus `assertions` |
| Dataform repository | git-linked anonymously, pulls from `main` |
| Runner service account | workflow invocations execute as it |
| First-run trigger | `run_pipeline_on_apply` builds everything at the end of apply |

## Data quality

`definitions/assertions/` hard-fails the workflow when a healthy pipeline would
return zero rows. `definitions/monitoring/` surfaces rows that are *expected*
sometimes — model drift, known-imperfect upstream data — without blocking a run.

## Cleanup

```bash
cd infra && tofu destroy
```

Two things are deliberately left behind, because Tofu didn't create them: the
project and the state bucket. Remove them by hand if you want the project gone:

```bash
gcloud storage rm -r gs://datacloud-metadata-feed-tfstate
gcloud projects delete datacloud-metadata-feed
```
