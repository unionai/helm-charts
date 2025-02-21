data "aws_iam_roles" "admin_regexes" {
  for_each   = toset(var.admin_role_regexes)
  name_regex = each.key
}

locals {
  admin_regex_role_arns = [
    for role in data.aws_iam_roles.admin_regexes : one(role.arns)
  ]

  pathless_admin_regex_role_arns = [
    for parts in [for arn in local.admin_regex_role_arns : split("/", arn)] :
    format("%s/%s", parts[0], element(parts, length(parts) - 1))
  ]

  admin_role_arns = concat(
    local.pathless_admin_regex_role_arns,
    var.admin_role_arns,
  )

  admin_role_configmap_data = [
    for role_arn in local.admin_role_arns : {
      rolearn  = role_arn
      username = "union-admin"
      groups   = ["system:masters"]
    }
  ]

  node_role_configmap_data = [
    for role_arn in var.node_role_arns : {
      rolearn  = role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers", "system:nodes"]
    }
  ]

  admin_user_arns = [
    for role_arn in var.admin_user_arns : {
      userarn = role_arn
      groups  = ["system:masters"]
    }
  ]

  aws_auth_configmap_data = {
    mapRoles = replace(yamlencode(concat(
      local.admin_role_configmap_data,
      local.node_role_configmap_data,
    )), "\"", "")
    mapUsers = replace(yamlencode(local.admin_user_arns), "\"", "")
  }
}

resource "kubernetes_config_map_v1_data" "aws_auth" {
  force = true

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = local.aws_auth_configmap_data
}
