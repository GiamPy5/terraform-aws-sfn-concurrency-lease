locals {
  create_dynamodb_table = var.create && var.create_dynamodb_table
}

data "aws_dynamodb_table" "existing_table" {
  count = var.create && !var.create_dynamodb_table ? 1 : 0

  name = var.ddb_table_name
}

module "dynamodb_table" {
  count = local.create_dynamodb_table ? 1 : 0

  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "4.2.0"

  name = var.ddb_table_name != "" ? var.ddb_table_name : "${var.name_prefix}-leases"

  ttl_attribute_name = var.ddb_ttl_attribute_name
  ttl_enabled        = true

  attributes = [
    {
      name = var.ddb_hash_key
      type = "S"
    },
    {
      name = var.ddb_range_key
      type = "S"
    }
  ]

  hash_key  = var.ddb_hash_key
  range_key = var.ddb_range_key

  billing_mode = var.ddb_billing_mode

  read_capacity  = var.ddb_read_capacity
  write_capacity = var.ddb_write_capacity

  deletion_protection_enabled           = var.ddb_deletion_protection_enabled
  autoscaling_enabled                   = var.ddb_autoscaling_enabled
  ignore_changes_global_secondary_index = var.ddb_autoscaling_enabled
}

locals {
  ddb_table_name = local.create_dynamodb_table ? module.dynamodb_table[0].dynamodb_table_id : coalesce(try(data.aws_dynamodb_table.existing_table[0].name, null), var.ddb_table_name)
  ddb_table_arn  = local.create_dynamodb_table ? module.dynamodb_table[0].dynamodb_table_arn : try(data.aws_dynamodb_table.existing_table[0].arn, "")
}
