provider "aws" {
  region = var.region
}

data "aws_partition" "current" {}

locals {
  platform_name     = "shared-lease-platform"
  analytics_prefix  = "analytics"
  batch_prefix      = "batch"
  analytics_comment = "Analytics workload acquires a shared regional lease before running."
  batch_comment     = "Batch ETL workload reuses the same lease table with its own prefix."
}

# ---------------------------------------------------------------------
# Shared DynamoDB table (no lambda or workflow created here)
# ---------------------------------------------------------------------
module "regional_lease_store" {
  source = "./../.."

  create                     = true
  create_dynamodb_table      = true
  create_lambdas             = false
  name_prefix                = local.platform_name
  lease_prefix               = ""
  ddb_table_name             = var.shared_table_name
  max_concurrent_leases      = 200
  max_lease_duration_seconds = 900
}

# ---------------------------------------------------------------------
# Application A (Analytics) - owns its own lambda and workflow
# ---------------------------------------------------------------------
module "analytics_lease" {
  source = "./../.."

  create                = true
  create_dynamodb_table = false
  ddb_table_name        = module.regional_lease_store.dynamodb_table_name

  name_prefix                = "${local.platform_name}-${local.analytics_prefix}"
  lease_prefix               = local.analytics_prefix
  max_concurrent_leases      = 15
  max_lease_duration_seconds = 600

  sfn_post_acquire_lease_state = "ProcessAnalyticsWork"
  sfn_post_release_lease_state = "AnalyticsComplete"
  sfn_wait_seconds             = 5
}

locals {
  analytics_states = jsonencode({
    Comment = local.analytics_comment
    StartAt = module.analytics_lease.sfn_acquire_lease_state_name
    States = merge(
      jsondecode(module.analytics_lease.acquire_lease_state),
      jsondecode(module.analytics_lease.check_lease_status_state),
      jsondecode(module.analytics_lease.wait_for_lease_state),
      {
        ProcessAnalyticsWork = {
          Type = "Pass"
          Result = {
            description = "Placeholder for analytics task."
          }
          Next = module.analytics_lease.sfn_release_lease_state_name
        }
      },
      jsondecode(module.analytics_lease.release_lease_state),
      {
        AnalyticsComplete = {
          Type = "Succeed"
        }
      }
    )
  })
}

data "aws_iam_policy_document" "analytics_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = [format("states.%s", data.aws_partition.current.dns_suffix)]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "analytics" {
  name               = "${local.platform_name}-${local.analytics_prefix}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.analytics_assume_role.json
}

resource "aws_iam_role_policy" "analytics" {
  name   = "${local.platform_name}-${local.analytics_prefix}-sfn-policy"
  role   = aws_iam_role.analytics.id
  policy = module.analytics_lease.lambda_permissions
}

resource "aws_sfn_state_machine" "analytics" {
  name     = "${local.platform_name}-${local.analytics_prefix}-workflow"
  role_arn = aws_iam_role.analytics.arn
  type     = "STANDARD"

  definition = local.analytics_states
}

# ---------------------------------------------------------------------
# Application B (Batch ETL) - separate lease prefix, same table
# ---------------------------------------------------------------------
module "batch_lease" {
  source = "./../.."

  create                = true
  create_dynamodb_table = false
  ddb_table_name        = module.regional_lease_store.dynamodb_table_name

  name_prefix                = "${local.platform_name}-${local.batch_prefix}"
  lease_prefix               = local.batch_prefix
  max_concurrent_leases      = 5
  max_lease_duration_seconds = 1200

  sfn_post_acquire_lease_state = "ProcessBatchWork"
  sfn_post_release_lease_state = "BatchComplete"
  sfn_wait_seconds             = 10
}

locals {
  batch_states = jsonencode({
    Comment = local.batch_comment
    StartAt = module.batch_lease.sfn_acquire_lease_state_name
    States = merge(
      jsondecode(module.batch_lease.acquire_lease_state),
      jsondecode(module.batch_lease.check_lease_status_state),
      jsondecode(module.batch_lease.wait_for_lease_state),
      {
        ProcessBatchWork = {
          Type = "Pass"
          Result = {
            description = "Placeholder for batch workload."
          }
          Next = module.batch_lease.sfn_release_lease_state_name
        }
      },
      jsondecode(module.batch_lease.release_lease_state),
      {
        BatchComplete = {
          Type = "Succeed"
        }
      }
    )
  })
}

data "aws_iam_policy_document" "batch_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = [format("states.%s", data.aws_partition.current.dns_suffix)]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "batch" {
  name               = "${local.platform_name}-${local.batch_prefix}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json
}

resource "aws_iam_role_policy" "batch" {
  name   = "${local.platform_name}-${local.batch_prefix}-sfn-policy"
  role   = aws_iam_role.batch.id
  policy = module.batch_lease.lambda_permissions
}

resource "aws_sfn_state_machine" "batch" {
  name     = "${local.platform_name}-${local.batch_prefix}-workflow"
  role_arn = aws_iam_role.batch.arn
  type     = "STANDARD"

  definition = local.batch_states
}
