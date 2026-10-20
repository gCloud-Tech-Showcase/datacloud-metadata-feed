# __DOMAIN_TITLE__ — quick reference

<!-- SKELETON: replace with queries that actually prove this domain works.
     Include at least one that distinguishes "the pipeline ran" from "the
     result is correct". -->

```sql
-- row counts
SELECT COUNT(*) FROM `serving.<table>`;

-- data quality: both must be empty
SELECT * FROM `assertions.<assertion_name>`;

-- monitoring: non-empty is expected, watch the trend
SELECT * FROM `assertions.<monitoring_view>`;
```
