data "oci_core_services" "all-services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_vcn" "vcn" {
  cidr_block     = var.vcn_cidr
  display_name   = "union-dp"
  dns_label      = "uniondp"
  compartment_id = oci_identity_compartment.union-compartment.id
}

resource "oci_core_service_gateway" "union-dp-bucket-sg" {
  display_name   = "union-dp-sg" # Display name for the Service Gateway
  compartment_id = oci_identity_compartment.union-compartment.id
  vcn_id         = oci_core_vcn.vcn.id
  services {
    service_id = lookup(data.oci_core_services.all-services.services[0], "id")
  }
}

resource "oci_core_nat_gateway" "ngw" {
  display_name   = "union-dp-ng" # Display name for the NAT Gateway
  compartment_id = oci_identity_compartment.union-compartment.id
  vcn_id         = oci_core_vcn.vcn.id
  block_traffic  = false
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = oci_identity_compartment.union-compartment.id
  display_name   = "union-dp-igw"
  vcn_id         = oci_core_vcn.vcn.id
}

resource "oci_core_route_table" "union-ngw-rt" {
  vcn_id         = oci_core_vcn.vcn.id
  compartment_id = oci_identity_compartment.union-compartment.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.ngw.id
  }

  route_rules {
    destination       = lookup(data.oci_core_services.all-services.services[0], "cidr_block")
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.union-dp-bucket-sg.id
  }
}

resource "oci_core_security_list" "union-k8s-api-endpoint" {
  vcn_id         = oci_core_vcn.vcn.id
  compartment_id = oci_identity_compartment.union-compartment.id
  display_name   = "union-k8s-api-endpoint"

  egress_security_rules {
    destination      = var.nodepool_cidr
    destination_type = "CIDR_BLOCK"
    protocol         = "6"
  }

  egress_security_rules {
    destination      = var.nodepool_cidr
    destination_type = "CIDR_BLOCK"
    protocol         = "1"

    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    destination      = lookup(data.oci_core_services.all-services.services[0], "cidr_block")
    destination_type = "SERVICE_CIDR_BLOCK"
    protocol         = "6"

    tcp_options {
      min = 443
      max = 443
    }
  }

  # Duplication here, since the next takes all...
  ingress_security_rules {
    source   = var.nodepool_cidr
    protocol = "6"

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = var.nodepool_cidr

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_security_list" "union-k8s-nodepool" {
  vcn_id         = oci_core_vcn.vcn.id
  compartment_id = oci_identity_compartment.union-compartment.id
  display_name   = "union-k8s-nodepool"

  egress_security_rules {
    description      = "allow traffic between nodes"
    protocol         = "all"
    destination_type = "CIDR_BLOCK"
    destination      = var.nodepool_cidr
  }

  egress_security_rules {
    description = "allow ping"
    protocol    = 1
    destination = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    description      = "allow traffic to oci services"
    protocol         = "6"
    destination_type = "SERVICE_CIDR_BLOCK"
    destination      = lookup(data.oci_core_services.all-services.services[0], "cidr_block")
  }

  egress_security_rules {
    description      = "allow api traffic out"
    protocol         = "6"
    destination_type = "CIDR_BLOCK"
    destination      = var.api_endpoint_cidr

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  egress_security_rules {
    description      = "allow all tcp traffic out"
    protocol         = "6"
    destination_type = "CIDR_BLOCK"
    destination      = "0.0.0.0/0"
  }

  ingress_security_rules {
    description = "allow ingress to nodes"
    protocol    = "all"
    source_type = "CIDR_BLOCK"
    source      = var.nodepool_cidr
  }

  ingress_security_rules {
    description = "allow tcp to api endpoint"
    protocol    = "6"
    source      = var.api_endpoint_cidr
  }

  ingress_security_rules {
    description = "allow ping"
    protocol    = 1
    source      = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "union-k8s-api-endpoint-subnet" {
  vcn_id         = oci_core_vcn.vcn.id
  compartment_id = oci_identity_compartment.union-compartment.id
  cidr_block     = var.api_endpoint_cidr
  display_name   = "union-k8s-api-endpoint-subnet"
  security_list_ids = [
    oci_core_vcn.vcn.default_security_list_id,
    oci_core_security_list.union-k8s-api-endpoint.id,
  ]
  route_table_id             = oci_core_route_table.union-ngw-rt.id
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_subnet" "union-k8s-api-lb-subnet" {
  vcn_id         = oci_core_vcn.vcn.id
  compartment_id = oci_identity_compartment.union-compartment.id
  cidr_block     = var.lb_cidr
  display_name   = "union-k8s-lb-subnet"
  security_list_ids = [
    oci_core_vcn.vcn.default_security_list_id,
  ]
  route_table_id = oci_core_route_table.union-ngw-rt.id
}

resource "oci_core_subnet" "union-k8s-nodepool-subnet" {
  vcn_id         = oci_core_vcn.vcn.id
  compartment_id = oci_identity_compartment.union-compartment.id
  cidr_block     = var.nodepool_cidr
  display_name   = "union-k8s-nodepool-subnet"
  security_list_ids = [
    oci_core_vcn.vcn.default_security_list_id,
    oci_core_security_list.union-k8s-nodepool.id,
  ]
  route_table_id             = oci_core_route_table.union-ngw-rt.id
  prohibit_public_ip_on_vnic = true
}
