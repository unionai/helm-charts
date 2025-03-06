locals {
  metadata_container_name = "${local.name_prefix}-metadata"
}

module "storage_account" {
  source = "Azure/avm-res-storage-storageaccount/azurerm"

  name                     = local.normalized_prefix
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "ZRS"
  account_kind             = "StorageV2"

  is_hns_enabled                = true
  shared_access_key_enabled     = false
  public_network_access_enabled = true

  containers = {
    metadata = {
      name = local.metadata_container_name
    }
  }

  # Allow all subnets from the virtual network to access the storage account
  network_rules = {
    virtual_network_subnet_ids = [
      for _, subnet in module.virtual_network.subnets : subnet.resource_id
    ]
  }

  # Allow workers and union services access to the storage account
  role_assignments = {
    worker = {
      role_definition_id_or_name = "Storage Blob Data Owner"
      principal_id               = module.worker_userassignedidentity.principal_id
    }
    services = {
      role_definition_id_or_name = "Storage Blob Data Owner"
      principal_id               = module.services_userassignedidentity.principal_id
    }
  }
}