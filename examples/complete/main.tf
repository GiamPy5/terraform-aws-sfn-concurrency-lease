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
  ddb_deletion_protection_enabled = true

  cloudwatch_logs_retention_in_days = 30
  name_prefix                       = local.name_prefix
  lease_prefix                      = "analytics-pipeline"
  max_lease_duration_seconds        = 900
  max_concurrent_leases             = 25

  kms_key_arn = aws_kms_key.lambda.arn

  powertools_configuration = local.powertools_config

  sfn_resource_id_jsonpath      = "$.detail.resourceId"
  sfn_lease_id_jsonpath         = "$.acquireLease.Payload.lease_id"
  sfn_lease_result_path         = "$.acquireLease"
  sfn_post_acquire_lease_state  = "ProcessWork"
  sfn_post_release_lease_state  = "NotifyNext"
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
  name_prefix                       = local.name_prefix
  lease_prefix                      = "analytics-pipeline"
  max_lease_duration_seconds        = 900
  max_concurrent_leases             = 25

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

  sfn_resource_id_jsonpath      = "$.detail.resourceId"
  sfn_lease_id_jsonpath         = "$.acquireLease.Payload.lease_id"
  sfn_lease_result_path         = "$.acquireLease"
  sfn_post_acquire_lease_state  = "ProcessWork"
  sfn_post_release_lease_state  = "NotifyNext"
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
}

locals {
  existing_workflow_states = {
    ProcessWork = {
      Type = "Pass"
      Result = {
        message = "Process the unit of work."
      }
      Next = module.dedicated_ddb_table.sfn_release_lease_state_name
    }
    NotifyNext = {
      Type = "Pass"
      Result = {
        message = "Notify the next worker."
      }
      End = true
    }
  }

  state_machine_definition = jsonencode({
    Comment = "Existing workflow protected by concurrency lease guards."
    StartAt = module.dedicated_ddb_table.sfn_acquire_lease_state_name
    States = merge(
      jsondecode(module.dedicated_ddb_table.acquire_lease_state),
      local.existing_workflow_states,
      jsondecode(module.dedicated_ddb_table.release_lease_state)
    )
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

resource "aws_iam_role_policy" "state_machine" {
  name   = "${local.name_prefix}-sfn-policy"
  role   = aws_iam_role.state_machine.id
  policy = module.dedicated_ddb_table.lambda_permissions
}

resource "aws_sfn_state_machine" "existing_workflow" {
  name     = "${local.name_prefix}-workflow"
  role_arn = aws_iam_role.state_machine.arn
  type     = "STANDARD"

  definition = local.state_machine_definition
}
