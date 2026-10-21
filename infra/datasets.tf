# =============================================================================
# BIGQUERY DATASETS
# Named for the data mesh domains, not for medallion stages: the demo is about
# a producer domain (sales) publishing to a consumer domain (marketing), and
# the dataset names carry that story.
#
#   raw                 = theLook tables copied into the demo region
#   sales               = producer domain's golden tables (in the data product)
#   marketing           = consumer domain's view over the sales tables
#   contract_monitoring = platform team's readiness history
# =============================================================================

resource "google_bigquery_dataset" "domains" {
  for_each = {
    raw                 = "RAW: theLook eCommerce tables copied into ${var.region}"
    sales               = "SALES DOMAIN: golden tables published in the Sales Orders data product"
    marketing           = "MARKETING DOMAIN: consumer views built on the sales golden tables"
    contract_monitoring = "PLATFORM: history of asset and data product readiness changes"
  }

  dataset_id  = each.key
  location    = var.region
  description = each.value

  # Rebuildable by design: every table is recreated by the next apply.
  delete_contents_on_destroy = true

  labels = {
    project = var.project_id
    purpose = "data-domain"
    domain  = "metadata-feed"
    stage   = replace(each.key, "_", "-")
  }

  depends_on = [google_project_service.apis["bigquery.googleapis.com"]]
}
