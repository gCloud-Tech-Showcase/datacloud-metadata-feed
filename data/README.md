# data/ — [addon:unstructured]

Commit the frozen corpus here as a single NDJSON (one JSON record per line).
`scripts/seed_data.sh` explodes it into one file per record at apply time,
because a BigLake object table is one row per file.

`.gitignore` ignores `*.json` but not `*.ndjson`, so the corpus commits cleanly.

Delete this directory along with the rest of the add-on if the domain has no
unstructured source data.
