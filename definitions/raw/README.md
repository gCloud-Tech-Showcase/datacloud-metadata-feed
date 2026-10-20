# raw/ — landed source data

Objects here represent data as it lands: BigLake object tables over GCS,
or tables loaded by something outside Dataform.

Skip this stage entirely when the only source is an external table referenced
by a declaration in `sources/` — there's nothing to land. If you do skip it,
delete the `raw` entry from `infra/datasets.tf` and the `raw_dataset_id` output
in `infra/outputs.tf`; they're a pair.
