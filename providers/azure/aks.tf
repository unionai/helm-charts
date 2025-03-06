locals {
  common_worker_node_properties = {
    # Recommended, size up to allow more ephemeral storage. Optionall, can use secondary disk from host disk
    os_disk_size_gb      = 500
    vnet_subnet_id       = module.virtual_network.subnets["nodes"].resource_id
    pod_subnet_id        = module.virtual_network.subnets["pods"].resource_id
    auto_scaling_enabled = true
    min_count            = 0
  }

  worker_labels = var.worker_labels
  azure_worker_taints = [
    for label_key, label_value in local.worker_labels : "${label_key}=${label_value}:NoSchedule"
  ]
  worker_tolerations = [
    for label_key, label_value in local.worker_labels : {
      key      = label_key
      operator = "Equal"
      value    = label_value
      effect   = "NoSchedule"
    }
  ]
}

resource "random_id" "temp_name_suffix" {
  byte_length = 4

  keepers = {
    vnet_subnet_id = module.virtual_network.subnets["nodes"].resource_id
    pod_subnet_id  = module.virtual_network.subnets["pods"].resource_id
  }
}

module "kubernetes" {
  source = "Azure/avm-res-containerservice-managedcluster/azurerm"

  name                = local.normalized_prefix
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  # Enable workload identity and OIDC issuer to allow service accounts to access Azure services
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  automatic_upgrade_channel = "stable" # Recommended but optional
  local_account_disabled    = false    # Optional, can use Azure AD to access the cluster

  network_profile = {
    network_plugin = "azure"
    # Note: Azure Karpenter Provider does not support customizing service DNS IP.
    # Therefore, defaulting to the Azure default service DNS IP for future proofing migration
    # Karpenter
    dns_service_ip     = "10.0.0.10"
    service_cidr       = "10.0.0.0/19"
    outbound_type      = "userAssignedNATGateway"
    network_data_plane = "cilium"
  }

  managed_identities = {
    # Optional, system-assigned identity are the simplest.
    system_assigned = true
  }

  role_based_access_control_enabled = false

  # Recommended, isolated node pool to run Union services
  default_node_pool = {
    name                        = "default"
    vm_size                     = var.default_nodepool_vm_size
    min_count                   = 1
    max_count                   = var.default_nodepool_max_count
    auto_scaling_enabled        = true
    temporary_name_for_rotation = "temp${random_id.temp_name_suffix.hex}"
    vnet_subnet_id              = module.virtual_network.subnets["nodes"].resource_id
    pod_subnet_id               = module.virtual_network.subnets["pods"].resource_id
    os_disk_size_gb             = 30

    node_labels = { "node_pool_name" = "default" }

    upgrade_settings = {
      drain_timeout_in_minutes      = 0
      max_surge                     = "33%"
      node_soak_duration_in_minutes = 0
    }
  }

  node_pools = { for name, node_pool in var.additional_worker_node_pools :
    name => merge(
      merge(
        merge(
          merge(local.common_worker_node_properties, node_pool),
          { node_labels : node_pool.node_labels != null ? merge(node_pool.node_labels, local.worker_labels) : local.worker_labels }
        ),
        { node_taints : node_pool.node_taints != null ? concat(node_pool.node_taints, local.azure_worker_taints) : local.azure_worker_taints }
        ), {
        eviction_policy = node_pool.priority != null && node_pool.priority == "Spot" ? "Delete" : null
      }
    )
  }
}
