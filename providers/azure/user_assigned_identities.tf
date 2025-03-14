
locals {
  services_ns = var.k8s_namespace != null ? var.k8s_namespace : var.union_org

  # Allow Union worker Kubernetes service accounts to retrieve tokens
  worker_ns_kas_parts = [
    "development:default",
    "staging:default",
    "production:default",
  ]

  # Allow Union services Kubernetes service accounts to retrieve tokens
  services_ns_kas_parts = [
    "${local.services_ns}:flytepropeller-system",
    "${local.services_ns}:flytepropeller-webhook-system",
    "${local.services_ns}:operator-system",
    "${local.services_ns}:proxy-system",
  ]
}

# Assigned identity to be used by Union executions
module "worker_userassignedidentity" {
  source = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"

  name                = "${local.name_prefix}-worker"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_federated_identity_credential" "worker" {
  for_each = toset(local.worker_ns_kas_parts)

  name                = "${local.name_prefix}-worker-${replace(each.key, ":", "-")}"
  resource_group_name = azurerm_resource_group.rg.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = data.azurerm_kubernetes_cluster.this.oidc_issuer_url
  parent_id           = module.worker_userassignedidentity.resource_id
  subject             = format("system:serviceaccount:%s", each.value)
}

# Managed identity for Union services
module "services_userassignedidentity" {
  source = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"

  name                = "${local.name_prefix}-services"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_federated_identity_credential" "services" {
  for_each = toset(local.services_ns_kas_parts)

  name                = "${local.name_prefix}-services-${replace(each.key, ":", "-")}"
  resource_group_name = azurerm_resource_group.rg.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = data.azurerm_kubernetes_cluster.this.oidc_issuer_url
  parent_id           = module.services_userassignedidentity.resource_id
  subject             = format("system:serviceaccount:%s", each.value)
}
