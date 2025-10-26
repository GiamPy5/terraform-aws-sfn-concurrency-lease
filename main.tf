data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  repository_root = path.module
}