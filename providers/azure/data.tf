data "azurerm_client_config" "current" {}

data "azurerm_kubernetes_cluster" "this" {
  name                = module.kubernetes.name
  resource_group_name = azurerm_resource_group.rg.name
}
