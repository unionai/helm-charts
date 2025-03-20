locals {
  images = {
    for source in data.oci_containerengine_node_pool_option.all.sources :
      source.source_name => source.image_id
  }
}

data "oci_containerengine_node_pool_option" "all" {
  compartment_id = oci_identity_compartment.union-compartment.id
  node_pool_option_id = "all"
}

resource "oci_containerengine_cluster" "union-dp" {
  compartment_id     = oci_identity_compartment.union-compartment.id
  kubernetes_version = "v1.31.1"
  name               = "union-dp"
  vcn_id             = oci_core_vcn.vcn.id

  # Revisit the native vcn cluster
  # cluster_pod_network_options {
  #     cni_type = "OCI_VCN_IP_NATIVE???"
  # }

  options {
    service_lb_subnet_ids = [
      oci_core_subnet.union-k8s-api-lb-subnet.id,
    ]

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    admission_controller_options {
      is_pod_security_policy_enabled = false
    }

    kubernetes_network_config {
      pods_cidr     = var.pods_cidr
      services_cidr = var.services_cidr
    }
  }
}

resource "oci_containerengine_node_pool" "union-dp-nodepool" {
  cluster_id     = oci_containerengine_cluster.union-dp.id
  compartment_id = oci_identity_compartment.union-compartment.id
  name           = "union-dp-nodepool"
  node_shape     = var.node_shape

  initial_node_labels {
    key   = "flyte.org/node-role"
    value = "worker"
  }

  node_source_details {
    image_id                = lookup(local.images, var.image_name, "unknown")
    source_type             = "IMAGE"
    boot_volume_size_in_gbs = var.node_boot_volume_size_gb
  }

  node_config_details {
    size = var.node_count
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.union-k8s-nodepool-subnet.id
    }
  }

  node_shape_config {
    memory_in_gbs = var.node_memory_gb
    ocpus         = var.node_cpus
  }
}
