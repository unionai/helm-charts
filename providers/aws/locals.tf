locals {
  # move to vars
  project     = "union"
  environment = "terraform"
  name_prefix = "${local.project}-${local.environment}"
  account_id  = data.aws_caller_identity.current.account_id

  union_projects         = ["flytesnacks"]
  union_domains          = ["development", "staging", "production"]

  # move to vars as well
  azs             = data.aws_availability_zones.available.zone_ids
  main_cidr_block = "10.0.0.0/16"
  private_subnets = [
    for idx, _ in local.azs :
    format("10.%d.0.0/16", idx + 1)
  ]
  public_subnets = [
    for idx, _ in local.azs :
    format("10.0.%d.0/24", idx + 1)
  ]
  database_subnets = [
    for idx, _ in local.azs :
    format("10.0.%d.0/24", idx + 10)
  ]

  nodegroup_asg_tags = {
    for k, v in var.node_groups : k => merge(
      # Spot
      v.spot ? {
        "k8s.io/cluster-autoscaler/node-template/label/eks.amazonaws.com/capacityType" = "SPOT"
        } : {
        "k8s.io/cluster-autoscaler/node-template/label/eks.amazonaws.com/capacityType" = "ON_DEMAND"
      },
      # Ephemeral storage
      {
        "k8s.io/cluster-autoscaler/node-template/resources/ephemeral-storage" = "${v.root_disk_size_gb}G"
      },
      # GPUs
      v.gpu_count == 0 ? {} : {
        "k8s.io/cluster-autoscaler/node-template/label/k8s.amazonaws.com/accelerator" = v.gpu_accelerator
        "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"            = tostring(v.gpu_count)
        "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"                = "present:NoSchedule"
      },
      # Dedicated node role
      v.dedicated_node_role == null ? {} : {
        "k8s.io/cluster-autoscaler/node-template/label/flyte.org/node-role" = v.dedicated_node_role
        "k8s.io/cluster-autoscaler/node-template/taint/flyte.org/node-role" = "${v.dedicated_node_role}:NoSchedule"
      }
    )
  }
}
