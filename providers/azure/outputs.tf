output "kubernetes_name" {
  value = module.kubernetes.name
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "union_org" {
  value = var.union_org
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}

output "storage_container_name" {
  value = local.metadata_container_name
}

output "storage_account_name" {
  value = module.storage_account.name
}

output "worker_userassignedidentity_client_id" {
  value = module.worker_userassignedidentity.client_id
}

output "services_userassignedidentity_client_id" {
  value = module.services_userassignedidentity.client_id
}

output "worker_labels" {
  value = local.worker_labels
}

output "worker_tolerations" {
  value = local.worker_tolerations
}
