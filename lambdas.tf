locals {
  lambda_src_root = "${local.repository_root}/src"

  lease_hash_value = var.lease_prefix == "" ? "CONCURRENCY_LEASES" : "CONCURRENCY_LEASES#${var.lease_prefix}"

  create_lambdas = var.create == true && var.create_lambdas ? true : false

  lambda_runtime        = "python3.12"
  lambda_architectures  = ["arm64"]
  powertools_layer_name = "AWSLambdaPowertoolsPythonV3-${replace(local.lambda_runtime, ".", "")}-${local.lambda_architectures[0]}:18"

  layers = concat(
    ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"],
    var.lambdas_tracing_enabled ? ["arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"] : []
  )

  lambdas = {
    "lease-manager" = {
      handler = "lambda_function.lambda_handler"
      policies = [
        "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
      ]
      source_path = "${local.lambda_src_root}/lease_manager"
      environment_variables = {
        LEASE_TABLE_NAME      = local.ddb_table_name
        LEASE_HASH_VALUE      = local.lease_hash_value
        LEASE_HASH_KEY        = var.ddb_hash_key
        LEASE_TTL_SECONDS     = var.max_lease_duration_seconds
        LEASE_RANGE_KEY       = var.ddb_range_key
        MAX_CONCURRENT_LEASES = var.max_concurrent_leases
      }
      timeout = 5
      policy_json = jsonencode({
        Version = "2012-10-17"
        Statement = concat(
          [
            {
              Effect   = "Allow"
              Action   = ["dynamodb:Query", "dynamodb:PutItem", "dynamodb:DeleteItem"]
              Resource = local.ddb_table_arn
              Condition = {
                "ForAllValues:StringLike" = {
                  "dynamodb:LeadingKeys" = local.lease_hash_value
                }
              }
            }
          ],
          var.kms_key_arn != "" ? [
            {
              Effect   = "Allow"
              Action   = ["kms:Decrypt"]
              Resource = var.kms_key_arn
            }
          ] : []
        )
      })
    }
  }

  lambda_layers = [
    "arn:aws:lambda:${data.aws_region.current.region}:017000801446:layer:${local.powertools_layer_name}"
  ]
}

module "lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.1"

  for_each = local.create_lambdas == true ? local.lambdas : {}

  create_role     = true
  create_package  = true
  create_function = true

  attach_tracing_policy = var.lambdas_tracing_enabled
  tracing_mode          = var.lambdas_tracing_enabled ? "Active" : null

  kms_key_arn = var.kms_key_arn

  publish = true

  function_name      = "${var.name_prefix}-${each.key}"
  runtime            = local.lambda_runtime
  architectures      = local.lambda_architectures
  handler            = each.value.handler
  policies           = each.value.policies
  layers             = local.lambda_layers
  attach_policy_json = contains(keys(each.value), "policy_json")
  policy_json        = try(each.value.policy_json, "")
  timeout            = each.value.timeout

  cloudwatch_logs_retention_in_days = var.cloudwatch_logs_retention_in_days

  source_path = {
    path = each.value.source_path
  }

  environment_variables = merge(each.value.environment_variables, {
    POWERTOOLS_SERVICE_NAME            = var.name_prefix,
    POWERTOOLS_METRICS_FUNCTION_NAME   = each.key
    POWERTOOLS_METRICS_DISABLED        = var.powertools_configuration.metrics_disabled
    POWERTOOLS_METRICS_NAMESPACE       = var.powertools_configuration.metrics_namespace
    POWERTOOLS_TRACE_DISABLED          = var.powertools_configuration.trace_disabled
    POWERTOOLS_TRACER_CAPTURE_RESPONSE = var.powertools_configuration.tracer_capture_response
    POWERTOOLS_TRACER_CAPTURE_ERROR    = var.powertools_configuration.tracer_capture_error
    POWERTOOLS_TRACE_MIDDLEWARES       = length(var.powertools_configuration.trace_middlewares) > 0 ? join(",", var.powertools_configuration.trace_middlewares) : false
    POWERTOOLS_LOGGER_LOG_EVENT        = var.powertools_configuration.logger_log_event
    POWERTOOLS_LOGGER_SAMPLE_RATE      = var.powertools_configuration.logger_sample_rate
    POWERTOOLS_LOG_DEDUPLICATION       = var.powertools_configuration.log_deduplication
    POWERTOOLS_PARAMETERS_MAX_AGE      = var.powertools_configuration.parameters_max_age
    POWERTOOLS_PARAMETERS_SSM_DECRYPT  = var.powertools_configuration.parameters_ssm_decrypt
    POWERTOOLS_DEV_MODE                = var.powertools_configuration.dev_mode
    POWERTOOLS_LOG_LEVEL               = var.powertools_configuration.log_level
  })
}

data "aws_iam_policy_document" "state_machine_permissions" {
  count = local.create_lambdas ? 1 : 0

  statement {
    sid     = "AllowLeaseManagerInvocation"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]

    resources = [
      for _, lambda_module in module.lambda :
      lambda_module.lambda_function_arn
    ]
  }
}
