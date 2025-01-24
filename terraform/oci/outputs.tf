output "compartment_id" {
  value = oci_identity_compartment.union-compartment.id
}

output "bucket_info" {
  value = {
    "bucket_name" : oci_objectstorage_bucket.union-dp-bucket.name,
    "compatibility_endpoint" : "https://${oci_identity_tag_namespace.unionai.name}.compat.objectstorage.${var.region}.oraclecloud.com",
    "access_key" : oci_identity_customer_secret_key.union-storage-access.id,
    "secret_key" : oci_identity_customer_secret_key.union-storage-access.key,
  }
}
