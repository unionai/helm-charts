locals {
  name_prefix       = var.name_prefix
  normalized_prefix = lower(replace("${local.name_prefix}", "/[^a-zA-Z0-9]/", ""))
}
