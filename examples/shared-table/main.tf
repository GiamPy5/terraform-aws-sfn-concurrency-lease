provider "aws" {
  region = var.region
}

data "aws_partition" "current" {}

locals {
  platform_name    = "shared-lease-platform"
  analytics_prefix = "analytics"
  batch_prefix     = "batch"

  analytics_items = [
    for idx in range(30) : {
      resource_id = format("analytics-%02d", idx)
    }
  ]

  batch_items = [
    for idx in range(20) : {
      resource_id = format("batch-%02d", idx)
    }
  ]

  analytics_object_body = jsonencode(local.analytics_items)
  batch_object_body     = jsonencode(local.batch_items)
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
  ddb_table_name             = var.shared_table_name
}

# ---------------------------------------------------------------------
# Shared data sources for distributed map workloads
# ---------------------------------------------------------------------
resource "aws_s3_bucket" "work_items" {
  bucket_prefix = "${local.platform_name}-items-"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "work_items" {
  bucket = aws_s3_bucket.work_items.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "analytics_items" {
  bucket       = aws_s3_bucket.work_items.id
  key          = "analytics-items.json"
  content      = local.analytics_object_body
  content_type = "application/json"
}

resource "aws_s3_object" "batch_items" {
  bucket       = aws_s3_bucket.work_items.id
  key          = "batch-items.json"
  content      = local.batch_object_body
  content_type = "application/json"
}

# ---------------------------------------------------------------------
# Application A (Analytics) - Distributed Map workflow
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

  sfn_post_acquire_lease_state  = "ProcessAnalyticsWork"
  sfn_post_release_lease_state  = "AnalyticsReleaseComplete"
  sfn_wait_seconds              = 5
  end_state_after_release_lease = false
}

locals {
  analytics_distributed_map = {
    ProcessAnalyticsItems = {
      Type           = "Map"
      MaxConcurrency = 0
      ItemReader = {
        Resource = "arn:aws:states:::s3:getObject"
        ReaderConfig = {
          InputType = "JSON"
        }
        Parameters = {
          Bucket = aws_s3_bucket.work_items.id
          Key    = aws_s3_object.analytics_items.key
        }
      }
      ItemProcessor = {
        ProcessorConfig = {
          Mode          = "DISTRIBUTED"
          ExecutionType = "STANDARD"
        }
        StartAt = module.analytics_lease.sfn_acquire_lease_state_name
        States = merge(
          jsondecode(module.analytics_lease.acquire_lease_state),
          jsondecode(module.analytics_lease.check_lease_status_state),
          jsondecode(module.analytics_lease.wait_for_lease_state),
          {
            ProcessAnalyticsWork = {
              Type = "Pass"
              Result = {
                detail = "Placeholder analytics task."
              }
              Next = module.analytics_lease.sfn_release_lease_state_name
            }
          },
          jsondecode(module.analytics_lease.release_lease_state),
          {
            AnalyticsReleaseComplete = {
              Type = "Pass"
              End  = true
            }
          }
        )
      }
      End = true
    }
  }

  analytics_state_machine_definition = jsonencode({
    Comment = "Analytics Distributed Map guarded by shared leases."
    StartAt = "ProcessAnalyticsItems"
    States  = local.analytics_distributed_map
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

data "aws_iam_policy_document" "analytics_s3_access" {
  statement {
    sid       = "ReadAnalyticsItems"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = [aws_s3_object.analytics_items.arn]
  }

  statement {
    sid       = "ListAnalyticsBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.work_items.arn]
  }
}

data "aws_iam_policy_document" "analytics_combined_policy" {
  source_policy_documents = [
    module.analytics_lease.lambda_permissions,
    data.aws_iam_policy_document.analytics_s3_access.json,
  ]
}

resource "aws_iam_role" "analytics" {
  name               = "${local.platform_name}-${local.analytics_prefix}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.analytics_assume_role.json
}

resource "aws_iam_role_policy" "analytics" {
  name   = "${local.platform_name}-${local.analytics_prefix}-sfn-policy"
  role   = aws_iam_role.analytics.id
  policy = data.aws_iam_policy_document.analytics_combined_policy.json
}

resource "aws_sfn_state_machine" "analytics" {
  name     = "${local.platform_name}-${local.analytics_prefix}-workflow"
  role_arn = aws_iam_role.analytics.arn
  type     = "STANDARD"

  definition = local.analytics_state_machine_definition
}

# ---------------------------------------------------------------------
# Application B (Batch ETL) - Distributed Map workflow
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

  sfn_post_acquire_lease_state  = "ProcessBatchWork"
  sfn_post_release_lease_state  = "BatchReleaseComplete"
  sfn_wait_seconds              = 8
  end_state_after_release_lease = false
}

locals {
  batch_distributed_map = {
    ProcessBatchItems = {
      Type           = "Map"
      MaxConcurrency = 0
      ItemReader = {
        Resource = "arn:aws:states:::s3:getObject"
        ReaderConfig = {
          InputType = "JSON"
        }
        Parameters = {
          Bucket = aws_s3_bucket.work_items.id
          Key    = aws_s3_object.batch_items.key
        }
      }
      ItemProcessor = {
        ProcessorConfig = {
          Mode          = "DISTRIBUTED"
          ExecutionType = "STANDARD"
        }
        StartAt = module.batch_lease.sfn_acquire_lease_state_name
        States = merge(
          jsondecode(module.batch_lease.acquire_lease_state),
          jsondecode(module.batch_lease.check_lease_status_state),
          jsondecode(module.batch_lease.wait_for_lease_state),
          {
            ProcessBatchWork = {
              Type = "Pass"
              Result = {
                detail = "Placeholder batch task."
              }
              Next = module.batch_lease.sfn_release_lease_state_name
            }
          },
          jsondecode(module.batch_lease.release_lease_state),
          {
            BatchReleaseComplete = {
              Type = "Pass"
              End  = true
            }
          }
        )
      }
      End = true
    }
  }

  batch_state_machine_definition = jsonencode({
    Comment = "Batch ETL Distributed Map guarded by shared leases."
    StartAt = "ProcessBatchItems"
    States  = local.batch_distributed_map
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

data "aws_iam_policy_document" "batch_s3_access" {
  statement {
    sid       = "ReadBatchItems"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = [aws_s3_object.batch_items.arn]
  }

  statement {
    sid       = "ListBatchBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.work_items.arn]
  }
}

data "aws_iam_policy_document" "batch_combined_policy" {
  source_policy_documents = [
    module.batch_lease.lambda_permissions,
    data.aws_iam_policy_document.batch_s3_access.json,
  ]
}

resource "aws_iam_role" "batch" {
  name               = "${local.platform_name}-${local.batch_prefix}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json
}

resource "aws_iam_role_policy" "batch" {
  name   = "${local.platform_name}-${local.batch_prefix}-sfn-policy"
  role   = aws_iam_role.batch.id
  policy = data.aws_iam_policy_document.batch_combined_policy.json
}

resource "aws_sfn_state_machine" "batch" {
  name     = "${local.platform_name}-${local.batch_prefix}-workflow"
  role_arn = aws_iam_role.batch.arn
  type     = "STANDARD"

  definition = local.batch_state_machine_definition
}
