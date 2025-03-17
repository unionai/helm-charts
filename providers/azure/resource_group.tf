resource "azurerm_resource_group" "rg" {
  name     = local.name_prefix
  location = var.location
}