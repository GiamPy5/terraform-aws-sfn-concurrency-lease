provider "aws" {
  region = var.region
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "example-sfn-concurrency-lease"

  powertools_config = {
    metrics_namespace       = "ExampleTelemetry"
    metrics_disabled        = false
    trace_disabled          = false
    tracer_capture_response = true
    tracer_capture_error    = true
    trace_middlewares       = []
    logger_log_event        = true
    logger_sample_rate      = 0.2
    log_deduplication       = true
    parameters_max_age      = 30
    parameters_ssm_decrypt  = true
    dev_mode                = false
    log_level               = "INFO"
  }

  distributed_map_items = [
    for idx in range(50) : {
      resource_id = format("item-%02d", idx)
    }
  ]

  distributed_map_object_body = jsonencode(local.distributed_map_items)
}

module "dedicated_ddb_table" {
  source = "./../.."

  create = true

  create_lambdas                  = true
  create_dynamodb_table           = true
  ddb_table_name                  = var.lease_table_name
  ddb_hash_key                    = "PK"
  ddb_range_key                   = "SK"
  ddb_ttl_attribute_name          = "ttl"
  ddb_billing_mode                = "PROVISIONED"
  ddb_read_capacity               = 10
  ddb_write_capacity              = 10
  ddb_autoscaling_enabled         = true
  ddb_autoscaling_read            = { max_capacity = 100 }
  ddb_autoscaling_write           = { max_capacity = 50 }
  ddb_deletion_protection_enabled = false

  cloudwatch_logs_retention_in_days = 30
  name_prefix                       = local.name_prefix
  lease_prefix                      = "analytics-pipeline"
  max_lease_duration_seconds        = 900
  max_concurrent_leases             = 5

  kms_key_arn = aws_kms_key.lambda.arn

  powertools_configuration = local.powertools_config

  sfn_resource_id_jsonpath = "$.resource_id"
  sfn_lease_id_jsonpath    = "$.acquireLease.Payload.lease_id"
  sfn_lease_result_path    = "$.acquireLease"

  sfn_post_acquire_lease_state  = "ProcessItem"
  sfn_post_release_lease_state  = "ReleaseComplete"
  sfn_wait_seconds              = 3
  end_state_after_release_lease = false
}

module "existing_ddb_table" {
  source = "./../.."

  create = true

  create_lambdas         = true
  create_dynamodb_table  = false
  ddb_table_name         = aws_dynamodb_table.example.id
  ddb_hash_key           = "PK"
  ddb_range_key          = "SK"
  ddb_ttl_attribute_name = "ttl"

  cloudwatch_logs_retention_in_days = 30
  name_prefix                       = "${local.name_prefix}-existing"
  lease_prefix                      = "analytics-pipeline"
  max_lease_duration_seconds        = 900
  max_concurrent_leases             = 5

  kms_key_arn = aws_kms_key.lambda.arn

  powertools_configuration = {
    metrics_namespace       = "ExampleTelemetry"
    metrics_disabled        = false
    trace_disabled          = false
    tracer_capture_response = true
    tracer_capture_error    = true
    trace_middlewares       = []
    logger_log_event        = true
    logger_sample_rate      = 0.2
    log_deduplication       = true
    parameters_max_age      = 30
    parameters_ssm_decrypt  = true
    dev_mode                = false
    log_level               = "INFO"
  }

  sfn_resource_id_jsonpath = "$.Key"
  sfn_lease_id_jsonpath    = "$.acquireLease.Payload.lease_id"
  sfn_lease_result_path    = "$.acquireLease"

  sfn_post_acquire_lease_state  = "ProcessItem"
  sfn_post_release_lease_state  = "ReleaseComplete"
  sfn_wait_seconds              = 3
  end_state_after_release_lease = false
}

module "disabled" {
  source = "./../.."

  create = false
}

# ---------------------------------------------------------------------
# Supporting Resources
# ---------------------------------------------------------------------
resource "aws_kms_key" "lambda" {
  description             = "KMS key for encrypting Lambda environment variables in the concurrency lease example."
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "lambda" {
  name          = "alias/${local.name_prefix}-lambda"
  target_key_id = aws_kms_key.lambda.key_id
}

resource "aws_dynamodb_table" "example" {
  name = "dynamodb-table-example"

  read_capacity  = 10
  write_capacity = 10

  hash_key  = "PK"
  range_key = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.lambda.arn
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "encryption" {
  bucket = aws_s3_bucket.work_items.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket" "work_items" {
  bucket_prefix = "${local.name_prefix}-items-"
  force_destroy = true
}

resource "aws_s3_object" "work_items" {
  bucket       = aws_s3_bucket.work_items.id
  key          = "distributed-map-items.json"
  content      = local.distributed_map_object_body
  content_type = "application/json"
}

locals {
  distributed_map_state = {
    ProcessDistributedItems = {
      Type           = "Map"
      MaxConcurrency = 50
      ItemReader = {
        ReaderConfig = {
          InputType = "JSON"
        }
        Resource = "arn:aws:states:::s3:getObject"
        Parameters = {
          Bucket = aws_s3_bucket.work_items.id
          Key    = aws_s3_object.work_items.key
        }
      }
      ItemProcessor = {
        ProcessorConfig = {
          Mode          = "DISTRIBUTED"
          ExecutionType = "STANDARD"
        }
        StartAt = module.dedicated_ddb_table.sfn_acquire_lease_state_name
        States = merge(
          jsondecode(module.dedicated_ddb_table.acquire_lease_state),
          jsondecode(module.dedicated_ddb_table.check_lease_status_state),
          jsondecode(module.dedicated_ddb_table.wait_for_lease_state),
          {
            ProcessItem = {
              Type    = "Pass"
              Comment = "Stub for the actual distributed unit of work."
              Next    = module.dedicated_ddb_table.sfn_release_lease_state_name
            }
          },
          jsondecode(module.dedicated_ddb_table.release_lease_state),
          {
            ReleaseComplete = {
              Type = "Pass"
              End  = true
            }
          }
        )
      }
      End = true
    }
  }

  state_machine_definition = jsonencode({
    Comment = "Distributed Map workflow protected by concurrency lease guards."
    StartAt = "ProcessDistributedItems"
    States  = local.distributed_map_state
  })
}

data "aws_iam_policy_document" "state_machine_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = [format("states.%s", data.aws_partition.current.dns_suffix)]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "state_machine" {
  name               = "${local.name_prefix}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.state_machine_assume_role.json
}

data "aws_iam_policy_document" "state_machine_s3_access" {
  statement {
    sid     = "ReadDistributedMapItems"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = [
      aws_s3_object.work_items.arn,
      format("%s/*", aws_s3_bucket.work_items.arn),
    ]
  }

  statement {
    sid       = "ListDistributedMapBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.work_items.arn]
  }
}

data "aws_iam_policy_document" "state_machine_map_permissions" {
  statement {
    sid     = "AllowDistributedMapExecutions"
    effect  = "Allow"
    actions = ["states:StartExecution"]
    resources = [
      format(
        "arn:%s:states:%s:%s:stateMachine:%s",
        data.aws_partition.current.partition,
        var.region,
        data.aws_caller_identity.current.account_id,
        "${local.name_prefix}-workflow"
      )
    ]
  }
}

data "aws_iam_policy_document" "state_machine_policy" {
  source_policy_documents = [
    module.dedicated_ddb_table.lambda_permissions,
    data.aws_iam_policy_document.state_machine_s3_access.json,
    data.aws_iam_policy_document.state_machine_map_permissions.json,
  ]
}

resource "aws_iam_role_policy" "state_machine" {
  name   = "${local.name_prefix}-sfn-policy"
  role   = aws_iam_role.state_machine.id
  policy = data.aws_iam_policy_document.state_machine_policy.json
}

resource "aws_sfn_state_machine" "distributed_map" {
  name     = "${local.name_prefix}-workflow"
  role_arn = aws_iam_role.state_machine.arn
  type     = "STANDARD"

  definition = local.state_machine_definition
}
