module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name                  = local.name_prefix
  cidr                  = "10.0.0.0/16"
  secondary_cidr_blocks = local.private_subnets

  azs              = local.azs
  private_subnets  = local.private_subnets
  public_subnets   = local.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "5.19.0"

  vpc_id = module.vpc.vpc_id
  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
    }
  }
}
