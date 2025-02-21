data "aws_availability_zones" "available" { state = "available" }
data "aws_region" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name                    = local.name_prefix
  cluster_version                 = "1.32"
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true
  enable_irsa                     = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    for k, v in var.node_groups : k => {
      desired_size = v.min_size
      max_size     = v.max_size
      min_size     = v.min_size

      ami_type = v.gpu_count == 0 ? null : "AL2_x86_64_GPU"
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = v.root_disk_size_gb
          }
        }
      }

      capacity_type  = v.spot ? "SPOT" : "ON_DEMAND"
      instance_types = [v.instance_type]
      labels = merge(
        v.gpu_count == 0 ? {} : {
          "k8s.amazonaws.com/accelerator" = v.gpu_accelerator
        },
        v.dedicated_node_role == null ? {} : {
          "flyte.org/node-role" = v.dedicated_node_role
        }
      )

      subnet_ids              = module.vpc.private_subnets
      tags = {
        "k8s.io/cluster-autoscaler/enabled"              = true
        "k8s.io/cluster-autoscaler/${local.name_prefix}" = true
      }

      taints = v.gpu_count == 0 ? [] : [
          {
            key    = "nvidia.com/gpu"
            value  = "present"
            effect = "NO_SCHEDULE"
          }
      ]

      iam_role_additional_policies = {
        "CloudWatchAgentPolicy" = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
      }
    }
  }
}

resource "aws_autoscaling_group_tag" "eks_managed_node_group_asg_tag" {
  for_each = merge([
    for mng, tags in local.nodegroup_asg_tags : {
      for tag_key, tag_value in tags : "${mng}-${replace(tag_key, "k8s.io/cluster-autoscaler/node-template/", "")}" => {
        mng   = mng
        key   = tag_key
        value = tag_value
      }
    }
  ]...)

  autoscaling_group_name = one(module.eks.eks_managed_node_groups[each.value.mng].node_group_autoscaling_group_names)

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = false
  }

  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "default" {
  name = module.eks.cluster_name
}

module "aws_load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.11.2"

  role_name                              = "${local.name_prefix}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = false

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

module "cluster_autoscaler_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.11.2"

  role_name                        = "${local.name_prefix}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.eks.cluster_name]

  oidc_providers = {
    default = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-cluster-autoscaler"]
    }
  }
}

resource "helm_release" "aws_cluster_autoscaler" {
  namespace = "kube-system"
  wait      = true
  timeout   = 600

  name = "aws-cluster-autoscaler"

  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.24.0"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "awsRegion"
    value = data.aws_region.current.name
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cluster_autoscaler_irsa_role.iam_role_arn
  }
  depends_on = [ module.eks ]
}
