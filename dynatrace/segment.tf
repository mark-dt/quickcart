# One segment that scopes every app / notebook / dashboard to QuickCart:
#   k8s.cluster.name = <cluster> AND (k8s.namespace.name = <staging> OR k8s.namespace.name = <production>)
#
# The Segments API stores filters as the parsed filter-field AST (Group /
# Statement nodes with character ranges into the filter text), so the text and
# the ranges are built together below.
locals {
  seg_cluster_text = "k8s.cluster.name = ${var.k8s_cluster}"
  seg_stg_text     = "k8s.namespace.name = ${var.staging_namespace}"
  seg_prd_text     = "k8s.namespace.name = ${var.production_namespace}"

  # Full text: <cluster> AND (<stg> OR <prd>)
  seg_or_from  = length(local.seg_cluster_text) + length(" AND ")
  seg_stg_from = local.seg_or_from + 1
  seg_prd_from = local.seg_stg_from + length(local.seg_stg_text) + length(" OR ")
  seg_or_to    = local.seg_prd_from + length(local.seg_prd_text) + 1
  seg_text     = "${local.seg_cluster_text} AND (${local.seg_stg_text} OR ${local.seg_prd_text})"
}

locals {
  # statement(key, value, from) — "key = value" starting at offset `from`
  seg_statements = {
    cluster = { key = "k8s.cluster.name", value = var.k8s_cluster, from = 0 }
    stg     = { key = "k8s.namespace.name", value = var.staging_namespace, from = local.seg_stg_from }
    prd     = { key = "k8s.namespace.name", value = var.production_namespace, from = local.seg_prd_from }
  }
  seg_nodes = {
    for k, s in local.seg_statements : k => {
      type  = "Statement"
      range = { from = s.from, to = s.from + length(s.key) + 3 + length(s.value) }
      key   = { type = "Key", textValue = s.key, value = s.key, range = { from = s.from, to = s.from + length(s.key) } }
      operator = {
        type      = "ComparisonOperator"
        textValue = "="
        value     = "="
        range     = { from = s.from + length(s.key) + 1, to = s.from + length(s.key) + 2 }
      }
      value = {
        type      = "String"
        textValue = s.value
        value     = s.value
        isEscaped = false
        range     = { from = s.from + length(s.key) + 3, to = s.from + length(s.key) + 3 + length(s.value) }
      }
    }
  }

  seg_filter = {
    type            = "Group"
    logicalOperator = "AND"
    explicit        = false
    range           = { from = 0, to = length(local.seg_text) }
    children = [
      local.seg_nodes.cluster,
      {
        type            = "Group"
        logicalOperator = "OR"
        explicit        = true
        range           = { from = local.seg_or_from, to = local.seg_or_to }
        children        = [local.seg_nodes.stg, local.seg_nodes.prd]
      },
    ]
  }
}

resource "dynatrace_segment" "quickcart" {
  name        = "${var.name_prefix} quickcart"
  description = "QuickCart staging + production on ${var.k8s_cluster} (managed by Terraform in the quickcart repo)"
  is_public   = true

  includes {
    items {
      data_object = "_all_data_object"
      filter      = jsonencode(local.seg_filter)
    }
  }
}
