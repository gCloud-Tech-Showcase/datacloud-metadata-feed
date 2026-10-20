# Schema Drift Alerts with Metadata Change Feeds Architecture

<!-- SKELETON: replace. Cover the pipeline flow (a mermaid graph works well),
     a Key Components table mapping dataset -> object -> purpose, and any
     model/endpoint notes. See the churn or feedback domain for a worked
     example of the shape. -->

Datasets follow semantic medallion stages — the domain (`metadata_feed`) is a
Dataform tag, not a dataset.

## Key components

| Stage | Object | Purpose |
| --- | --- | --- |
| | | |

## Data quality

| Folder | type | Semantics |
| --- | --- | --- |
| `assertions/` | `"assertion"` | Hard fail — returned rows fail the run |
| `monitoring/` | `"view"` | Warning only — never blocks |
