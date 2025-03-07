variable "vnet_cidr_range" {
  description = "The CIDR range for the VNet"
  type        = string
  default     = "10.0.0.0/8"
}

variable "vnet_nodes_subnet_cidr_range" {
  description = "The CIDR range for the AKS nodes subnet"
  type        = string
  default     = "10.0.96.0/19"
}

variable "vnet_pods_subnet_cidr_ranges" {
  description = <<EOF
The CIDR range for the AKS nodes subnet.

Note: Should likely be set to empty if overlay_pods_cidr is configured. The resulting pod subnets will be effectively wasted.
EOF
  type        = list(string)
  default     = ["10.4.0.0/14"]
  # Can include 10.8.0.0/14, 10.12.0.0/14, 10.16.0.0/14, 10.20.0.0/14 for future use.
  # Ref: https://unionai.atlassian.net/wiki/spaces/ENG/pages/598671388/VPC+IP+Address+Range+Allocations#Azure
  validation {
    condition     = length(var.vnet_pods_subnet_cidr_ranges) > 0
    error_message = "At least one vnet_pods_subnet_cidr_ranges must be provided."
  }
}

variable "num_natgateway_ips" {
  description = "The number of IPs to allocate for the NAT Gateway"
  type        = number
  default     = 1
}

variable "default_nodepool_vm_size" {
  description = "The size of the VMs in the default node pool"
  type        = string
  default     = "Standard_B8as_v2"
}

variable "default_nodepool_max_count" {
  description = "The maximum number of nodes in the default node pool"
  type        = number
  default     = 5
}

variable "additional_worker_node_pools" {
  type = map(object({
    name                          = string
    vm_size                       = string
    capacity_reservation_group_id = optional(string)
    max_count                     = optional(number)
    node_count                    = optional(number)
    host_encryption_enabled       = optional(bool)
    node_public_ip_enabled        = optional(bool)
    eviction_policy               = optional(string)
    host_group_id                 = optional(string)
    fips_enabled                  = optional(bool)
    gpu_instance                  = optional(string)
    kubelet_disk_type             = optional(string)
    max_pods                      = optional(number)
    mode                          = optional(string)
    node_network_profile = optional(object({
      allowed_host_ports = optional(list(object({
        port_start = optional(number)
        port_end   = optional(number)
        protocol   = optional(string)
      })))
      application_security_group_ids = optional(list(string))
      node_public_ip_tags            = optional(map(string))
    }))
    node_labels                  = optional(map(string))
    node_public_ip_prefix_id     = optional(string)
    node_taints                  = optional(list(string))
    orchestrator_version         = optional(string)
    os_disk_size_gb              = optional(number)
    os_disk_type                 = optional(string)
    os_sku                       = optional(string)
    os_type                      = optional(string)
    priority                     = optional(string)
    proximity_placement_group_id = optional(string)
    spot_max_price               = optional(string)
    snapshot_id                  = optional(string)
    tags                         = optional(map(string))
    scale_down_mode              = optional(string)
    ultra_ssd_enabled            = optional(bool)
    zones                        = optional(list(string))
    workload_runtime             = optional(string)
    windows_profile = optional(object({
      outbound_nat_enabled = optional(bool)
    }))
    upgrade_settings = optional(object({
      drain_timeout_in_minutes      = optional(number)
      node_soak_duration_in_minutes = optional(number)
      max_surge                     = string
    }))

    kubelet_config = optional(object({
      cpu_manager_policy        = optional(string)
      cpu_cfs_quota_enabled     = optional(bool, true)
      cpu_cfs_quota_period      = optional(string)
      image_gc_high_threshold   = optional(number)
      image_gc_low_threshold    = optional(number)
      topology_manager_policy   = optional(string)
      allowed_unsafe_sysctls    = optional(set(string))
      container_log_max_size_mb = optional(number)
      container_log_max_line    = optional(number)
      pod_max_pid               = optional(number)
    }))
    linux_os_config = optional(object({
      sysctl_config = optional(object({
        fs_aio_max_nr                      = optional(number)
        fs_file_max                        = optional(number)
        fs_inotify_max_user_watches        = optional(number)
        fs_nr_open                         = optional(number)
        kernel_threads_max                 = optional(number)
        net_core_netdev_max_backlog        = optional(number)
        net_core_optmem_max                = optional(number)
        net_core_rmem_default              = optional(number)
        net_core_rmem_max                  = optional(number)
        net_core_somaxconn                 = optional(number)
        net_core_wmem_default              = optional(number)
        net_core_wmem_max                  = optional(number)
        net_ipv4_ip_local_port_range_min   = optional(number)
        net_ipv4_ip_local_port_range_max   = optional(number)
        net_ipv4_neigh_default_gc_thresh1  = optional(number)
        net_ipv4_neigh_default_gc_thresh2  = optional(number)
        net_ipv4_neigh_default_gc_thresh3  = optional(number)
        net_ipv4_tcp_fin_timeout           = optional(number)
        net_ipv4_tcp_keepalive_intvl       = optional(number)
        net_ipv4_tcp_keepalive_probes      = optional(number)
        net_ipv4_tcp_keepalive_time        = optional(number)
        net_ipv4_tcp_max_syn_backlog       = optional(number)
        net_ipv4_tcp_max_tw_buckets        = optional(number)
        net_ipv4_tcp_tw_reuse              = optional(bool)
        net_netfilter_nf_conntrack_buckets = optional(number)
        net_netfilter_nf_conntrack_max     = optional(number)
        vm_max_map_count                   = optional(number)
        vm_swappiness                      = optional(number)
        vm_vfs_cache_pressure              = optional(number)
      }))
    }))
  }))
  default = {
    b4asv2 = {
      name      = "b4asv2"
      vm_size   = "Standard_B4as_v2"
      max_count = 10
    }
    b4asv2spot = {
      name      = "b4asv2spot"
      vm_size   = "Standard_B4as_v2"
      max_count = 10
      priority  = "Spot"
    }
  }
  description = "Optional. The additional node pools for the Kubernetes cluster."
}

variable "union_org" {
  description = "The organization name for the cluster"
  type        = string
}

variable "name_prefix" {
  description = "The prefix for the name of the resources"
  type        = string
}

variable "location" {
  description = "The location for the resources"
  type        = string
}

variable "k8s_namespace" {
  description = "The namespace that will run Union services. union_org will be used if null."
  type        = string
  default     = null
}

variable "worker_labels" {
  description = "The labels for the worker nodes"
  type        = map(string)
  default     = {}
}