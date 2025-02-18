resource "oci_identity_compartment" "union-compartment" {
  compartment_id = var.tenancy_ocid
  description    = "Compartment for Union.ai dataplane resources."
  name           = "uniondp"
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = oci_identity_compartment.union-compartment.id
}
