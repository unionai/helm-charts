data "oci_objectstorage_namespace" "union-namespace" {
  compartment_id = oci_identity_compartment.union-compartment.id
}

# We aren't actually using these tags, but I'm going to explore dynamic grouping
# next.
resource "oci_identity_tag_namespace" "unionai" {
  compartment_id = oci_identity_compartment.union-compartment.id
  description    = "Union namespace"
  name           = "unionai"
}

resource "oci_identity_tag" "access" {
  name             = "access"
  description      = "Union access tagging"
  tag_namespace_id = oci_identity_tag_namespace.unionai.id
}

resource "oci_identity_user" "union-storage-user" {
  compartment_id = var.tenancy_ocid
  description    = "Union object storage user"
  name           = "union-storage"
  email          = var.storage_user_email
}

resource "oci_identity_group" "union-storage-group" {
  compartment_id = var.tenancy_ocid
  description    = "Union object storage managers"
  name           = "union-storage"
}

resource "oci_identity_user_group_membership" "union-storage-membership" {
  group_id = oci_identity_group.union-storage-group.id
  user_id  = oci_identity_user.union-storage-user.id
}

resource "oci_identity_customer_secret_key" "union-storage-access" {
  display_name = "union-storage-access"
  user_id      = oci_identity_user.union-storage-user.id
}

resource "oci_objectstorage_bucket" "union-dp-bucket" {
  compartment_id = oci_identity_compartment.union-compartment.id
  name           = "union-dp-bucket"
  namespace      = data.oci_objectstorage_namespace.union-namespace.namespace
  storage_tier   = "Standard"
  freeform_tags = {
    "Name" = "union-dp-bucket"
  }

  access_type           = "NoPublicAccess"
  object_events_enabled = false
}
