locals {
  service_endpoints = ["Microsoft.Storage", "Microsoft.ContainerRegistry", "Microsoft.KeyVault"]
}

# NAT Gateway used for outbound traffic
resource "azurerm_public_ip" "nat_gateway" {
  count = var.num_natgateway_ips

  name                = "${local.name_prefix}-${count.index}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "this" {
  name                    = local.name_prefix
  resource_group_name     = azurerm_resource_group.rg.name
  location                = azurerm_resource_group.rg.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
}

# Associate NAT Gateway with public IP
resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = var.num_natgateway_ips

  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat_gateway[count.index].id
}

# Ref: https://registry.terraform.io/modules/Azure/avm-res-network-virtualnetwork
module "virtual_network" {
  source = "Azure/avm-res-network-virtualnetwork/azurerm"

  name                = local.name_prefix
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = [var.vnet_cidr_range]
  subnets = {
    nodes = {
      name              = "nodes"
      address_prefix    = var.vnet_nodes_subnet_cidr_range
      service_endpoints = local.service_endpoints
      nat_gateway = {
        id = azurerm_nat_gateway.this.id
      }
    }
    pods = {
      name              = "pods"
      address_prefixes  = var.vnet_pods_subnet_cidr_ranges
      service_endpoints = local.service_endpoints
      delegation = [{
        name = "Microsoft.ContainerService/managedClusters"
        service_delegation = {
          name = "Microsoft.ContainerService/managedClusters"
        }
      }]
      nat_gateway = {
        id = azurerm_nat_gateway.this.id
      }
    }
  }
}
