module "union-data" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.6.0"

  # TODO: change me to something different (var)
  bucket                  = "${local.name_prefix}-data"
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
