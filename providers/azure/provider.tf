terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# Configure the Microsoft Azure Provider with azurecli
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli
provider "azurerm" {
  features {}
  storage_use_azuread = true
}
