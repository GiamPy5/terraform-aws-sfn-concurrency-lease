# terraform-aws-sfn-concurrency-lease

Composable Terraform module that adds safe concurrency control to AWS Step Functions.  
It wraps a purpose-built Lambda function, DynamoDB table, and IAM wiring to implement the distributed lease pattern so you can throttle fan-out workloads without rewriting business logic.

---

## Why this module?
- **Deterministic fan-out throttling** – enforce a fixed number of parallel tasks across Step Functions `Map` states or nested workflows.
- **Drop-in state machine guards** – ship pre-defined `AcquireLease`, optional `CheckLeaseStatus` + `WaitForLease`, and `ReleaseLease` state JSON that can be merged into existing definitions.
- **Production defaults** – opinionated CloudWatch log retention, Powertools observability configuration, and optional DynamoDB autoscaling.
- **Transparent IAM** – emitted inline policies and managed policy attachments so platform teams can review grants before deploying.
- **Tested runtime** – the bundled Lambda function is covered by 100% unit test coverage using moto-backed regression tests.

---

## Quick start

```hcl
module "sfn_concurrency" {
  source = "GiamPy5/sfn-concurrency-lease/aws"

  name_prefix                = "analytics-pipeline"
  max_concurrent_leases      = 10
  max_lease_duration_seconds = 900

  # Optional: let the module create the table and Lambda package
  create_lambdas         = true
  create_dynamodb_table  = true

  # Optional: reuse an external table
  # create_dynamodb_table = false
  # ddb_table_name        = "shared-concurrency-leases"

  kms_key_arn = aws_kms_key.lambda_env.arn
}
```

Integrate the concurrency guard states into an existing Step Functions definition:

```hcl
locals {
  state_machine_definition = jsonencode({
    StartAt = module.sfn_concurrency.sfn_acquire_lease_state_name
    States = merge(
      jsondecode(module.sfn_concurrency.acquire_lease_state),
      jsondecode(module.sfn_concurrency.check_lease_status_state),
      jsondecode(module.sfn_concurrency.wait_for_lease_state),
      {
        ProcessWork = {
          Type = "Task"
          Resource = aws_lambda_function.worker.arn
          Next = module.sfn_concurrency.sfn_release_lease_state_name
        }
      },
      jsondecode(module.sfn_concurrency.release_lease_state)
    )
  })
}

resource "aws_sfn_state_machine" "workflow" {
  name     = "analytics-workflow"
  role_arn = aws_iam_role.workflow.arn
  definition = local.state_machine_definition
}

resource "aws_iam_role_policy" "sfn_lambda_invoke" {
  role   = aws_iam_role.workflow.id
  policy = module.sfn_concurrency.lambda_permissions
}
```

See a complete end-to-end setup in [`examples/complete`](examples/complete).

---

## Architecture

| Component | Purpose |
| --- | --- |
| AWS Lambda (`lease-manager`) | Handles `acquire` / `release` actions, counts active leases, and enforces TTLs. Ships with AWS Lambda Powertools logging, tracing, and metrics. |
| DynamoDB table | Stores leases as `{PK, SK}` items with TTL attribute so expired leases are reclaimed automatically. |
| Terraform locals & outputs | Provide ready-made Step Functions state fragments and IAM policy JSON to embed in existing workflows. |

Execution flow:
1. Step Function enters `AcquireLease` state and invokes the Lambda with `action=acquire`.
2. Lambda counts active (TTL > now) leases; returns `wait` if the fleet is saturated.
3. Business logic executes while holding the lease.
4. `ReleaseLease` state calls the same Lambda with `action=release` to free capacity. If a lease disappears naturally (TTL expiry), the release call is treated as idempotent.

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.6 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_dynamodb_table"></a> [dynamodb\_table](#module\_dynamodb\_table) | terraform-aws-modules/dynamodb-table/aws | ~> 5.2 |
| <a name="module_lambda"></a> [lambda](#module\_lambda) | terraform-aws-modules/lambda/aws | ~> 8.1 |

## Resources

| Name | Type |
|------|------|
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_dynamodb_table.existing_table](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/dynamodb_table) | data source |
| [aws_iam_policy_document.state_machine_permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cloudwatch_logs_retention_in_days"></a> [cloudwatch\_logs\_retention\_in\_days](#input\_cloudwatch\_logs\_retention\_in\_days) | Retention period, in days, applied to the Lambda function's CloudWatch Logs group. | `number` | `7` | no |
| <a name="input_create"></a> [create](#input\_create) | Master toggle to enable or disable creation of every resource in the module. | `bool` | `true` | no |
| <a name="input_create_dynamodb_table"></a> [create\_dynamodb\_table](#input\_create\_dynamodb\_table) | Control whether the module provisions the DynamoDB lease table or expects an existing table. | `bool` | `true` | no |
| <a name="input_create_lambdas"></a> [create\_lambdas](#input\_create\_lambdas) | When true, package and deploy the lease-manager Lambda function and supporting IAM role. | `bool` | `true` | no |
| <a name="input_ddb_autoscaling_enabled"></a> [ddb\_autoscaling\_enabled](#input\_ddb\_autoscaling\_enabled) | Enable DynamoDB Application Auto Scaling policies for provisioned capacity. | `bool` | `false` | no |
| <a name="input_ddb_autoscaling_read"></a> [ddb\_autoscaling\_read](#input\_ddb\_autoscaling\_read) | Autoscaling limits for read capacity when autoscaling is enabled. | <pre>object({<br/>    max_capacity = number<br/>  })</pre> | <pre>{<br/>  "max_capacity": 1<br/>}</pre> | no |
| <a name="input_ddb_autoscaling_write"></a> [ddb\_autoscaling\_write](#input\_ddb\_autoscaling\_write) | Autoscaling limits for write capacity when autoscaling is enabled. | <pre>object({<br/>    max_capacity = number<br/>  })</pre> | <pre>{<br/>  "max_capacity": 1<br/>}</pre> | no |
| <a name="input_ddb_billing_mode"></a> [ddb\_billing\_mode](#input\_ddb\_billing\_mode) | Billing mode for the DynamoDB table; set to PROVISIONED to supply read/write capacity. | `string` | `"PAY_PER_REQUEST"` | no |
| <a name="input_ddb_deletion_protection_enabled"></a> [ddb\_deletion\_protection\_enabled](#input\_ddb\_deletion\_protection\_enabled) | Enable DynamoDB deletion protection on the managed lease table. | `bool` | `false` | no |
| <a name="input_ddb_hash_key"></a> [ddb\_hash\_key](#input\_ddb\_hash\_key) | Name of the DynamoDB partition key attribute used in the lease table. | `string` | `"PK"` | no |
| <a name="input_ddb_point_in_time_recovery_enabled"></a> [ddb\_point\_in\_time\_recovery\_enabled](#input\_ddb\_point\_in\_time\_recovery\_enabled) | Enable Point-in-Time Recovery (continuous backups) for the DynamoDB table. | `bool` | `false` | no |
| <a name="input_ddb_range_key"></a> [ddb\_range\_key](#input\_ddb\_range\_key) | Name of the DynamoDB sort key attribute used in the lease table. | `string` | `"SK"` | no |
| <a name="input_ddb_read_capacity"></a> [ddb\_read\_capacity](#input\_ddb\_read\_capacity) | Provisioned read capacity units when using PROVISIONED billing mode. | `number` | `10` | no |
| <a name="input_ddb_table_name"></a> [ddb\_table\_name](#input\_ddb\_table\_name) | Name of the DynamoDB table to use when create\_dynamodb\_table is false; otherwise used as an override for the managed table. | `string` | `""` | no |
| <a name="input_ddb_ttl_attribute_name"></a> [ddb\_ttl\_attribute\_name](#input\_ddb\_ttl\_attribute\_name) | Attribute name that stores the TTL timestamp for automatically expiring leases. | `string` | `"ttl"` | no |
| <a name="input_ddb_write_capacity"></a> [ddb\_write\_capacity](#input\_ddb\_write\_capacity) | Provisioned write capacity units when using PROVISIONED billing mode. | `number` | `10` | no |
| <a name="input_end_state_after_release_lease"></a> [end\_state\_after\_release\_lease](#input\_end\_state\_after\_release\_lease) | When true, the ReleaseLease state terminates the workflow; otherwise it transitions to sfn\_post\_release\_lease\_state. | `bool` | `false` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | Customer managed KMS key ARN for encrypting Lambda environment variables and any DynamoDB encryption context. | `string` | `""` | no |
| <a name="input_lambdas_tracing_enabled"></a> [lambdas\_tracing\_enabled](#input\_lambdas\_tracing\_enabled) | Attach AWS X-Ray tracing configuration and policies to the lease-manager Lambda. | `bool` | `false` | no |
| <a name="input_lease_prefix"></a> [lease\_prefix](#input\_lease\_prefix) | Optional suffix added to the DynamoDB partition key so multiple workloads can share a table without collisions. | `string` | `""` | no |
| <a name="input_max_concurrent_leases"></a> [max\_concurrent\_leases](#input\_max\_concurrent\_leases) | Maximum number of active leases allowed before new requests are told to wait. | `number` | `100` | no |
| <a name="input_max_lease_duration_seconds"></a> [max\_lease\_duration\_seconds](#input\_max\_lease\_duration\_seconds) | Time-to-live in seconds applied to each lease item stored in DynamoDB. | `number` | `600` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix applied to all named AWS resources created by the module. | `string` | `"concurrency-mgmt"` | no |
| <a name="input_powertools_configuration"></a> [powertools\_configuration](#input\_powertools\_configuration) | AWS Lambda Powertools settings injected into the lease-manager Lambda environment. | <pre>object({<br/>    metrics_namespace       = optional(string, "terraform-aws-sfn-concurrency-lease")<br/>    metrics_disabled        = optional(bool, false)<br/>    trace_disabled          = optional(bool, false)<br/>    tracer_capture_response = optional(bool, true)<br/>    tracer_capture_error    = optional(bool, true)<br/>    trace_middlewares       = optional(list(string), [])<br/>    logger_log_event        = optional(bool, false)<br/>    logger_sample_rate      = optional(number, 0.1)<br/>    log_deduplication       = optional(bool, false)<br/>    parameters_max_age      = optional(number, 10)<br/>    parameters_ssm_decrypt  = optional(bool, false)<br/>    dev_mode                = optional(bool, false)<br/>    log_level               = optional(string, "INFO")<br/>  })</pre> | <pre>{<br/>  "dev_mode": true,<br/>  "log_deduplication": false,<br/>  "log_level": "DEBUG",<br/>  "logger_log_event": true,<br/>  "logger_sample_rate": 0.1,<br/>  "metrics_disabled": false,<br/>  "metrics_namespace": "terraform-aws-sfn-concurrency-lease",<br/>  "parameters_max_age": 10,<br/>  "parameters_ssm_decrypt": false,<br/>  "trace_disabled": false,<br/>  "trace_middlewares": [],<br/>  "tracer_capture_error": true,<br/>  "tracer_capture_response": true<br/>}</pre> | no |
| <a name="input_sfn_acquire_lease_state_name"></a> [sfn\_acquire\_lease\_state\_name](#input\_sfn\_acquire\_lease\_state\_name) | State name used for the generated AcquireLease task. | `string` | `"AcquireLease"` | no |
| <a name="input_sfn_check_lease_state_name"></a> [sfn\_check\_lease\_state\_name](#input\_sfn\_check\_lease\_state\_name) | State name for the optional Choice state that inspects the acquire result. | `string` | `"CheckLeaseStatus"` | no |
| <a name="input_sfn_lease_id_jsonpath"></a> [sfn\_lease\_id\_jsonpath](#input\_sfn\_lease\_id\_jsonpath) | JSONPath to extract the lease ID from the Step Functions context for the release step. | `string` | `"$.lease_id"` | no |
| <a name="input_sfn_lease_result_path"></a> [sfn\_lease\_result\_path](#input\_sfn\_lease\_result\_path) | JSONPath within the state machine context where the acquire lease Lambda result will be stored. | `string` | `"$.acquireLease"` | no |
| <a name="input_sfn_post_acquire_lease_state"></a> [sfn\_post\_acquire\_lease\_state](#input\_sfn\_post\_acquire\_lease\_state) | Name of the next state entered when a lease is acquired successfully. | `string` | `"StartExecution"` | no |
| <a name="input_sfn_post_release_lease_state"></a> [sfn\_post\_release\_lease\_state](#input\_sfn\_post\_release\_lease\_state) | Name of the next state entered after releasing a lease when end\_state\_after\_release\_lease is false. | `string` | `"NextStep"` | no |
| <a name="input_sfn_release_lease_result_path"></a> [sfn\_release\_lease\_result\_path](#input\_sfn\_release\_lease\_result\_path) | JSONPath location within the Step Functions context to store the release lease Lambda result. | `string` | `"$.releaseLease"` | no |
| <a name="input_sfn_release_lease_state_name"></a> [sfn\_release\_lease\_state\_name](#input\_sfn\_release\_lease\_state\_name) | State name used for the generated ReleaseLease task. | `string` | `"ReleaseLease"` | no |
| <a name="input_sfn_resource_id_jsonpath"></a> [sfn\_resource\_id\_jsonpath](#input\_sfn\_resource\_id\_jsonpath) | JSONPath to extract the resource ID from the Step Functions context for the acquire step. | `string` | `"$.resource_id"` | no |
| <a name="input_sfn_wait_seconds"></a> [sfn\_wait\_seconds](#input\_sfn\_wait\_seconds) | Seconds the Wait state should pause before retrying an acquire call. | `number` | `5` | no |
| <a name="input_sfn_wait_state_name"></a> [sfn\_wait\_state\_name](#input\_sfn\_wait\_state\_name) | State name for the optional Wait state that pauses before retrying an acquire. | `string` | `"WaitForLease"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_acquire_lease_state"></a> [acquire\_lease\_state](#output\_acquire\_lease\_state) | n/a |
| <a name="output_check_lease_status_state"></a> [check\_lease\_status\_state](#output\_check\_lease\_status\_state) | n/a |
| <a name="output_dynamodb_table_arn"></a> [dynamodb\_table\_arn](#output\_dynamodb\_table\_arn) | n/a |
| <a name="output_dynamodb_table_name"></a> [dynamodb\_table\_name](#output\_dynamodb\_table\_name) | n/a |
| <a name="output_lambda_permissions"></a> [lambda\_permissions](#output\_lambda\_permissions) | n/a |
| <a name="output_release_lease_state"></a> [release\_lease\_state](#output\_release\_lease\_state) | n/a |
| <a name="output_sfn_acquire_lease_state_name"></a> [sfn\_acquire\_lease\_state\_name](#output\_sfn\_acquire\_lease\_state\_name) | n/a |
| <a name="output_sfn_check_lease_state_name"></a> [sfn\_check\_lease\_state\_name](#output\_sfn\_check\_lease\_state\_name) | n/a |
| <a name="output_sfn_release_lease_state_name"></a> [sfn\_release\_lease\_state\_name](#output\_sfn\_release\_lease\_state\_name) | n/a |
| <a name="output_sfn_wait_state_name"></a> [sfn\_wait\_state\_name](#output\_sfn\_wait\_state\_name) | n/a |
| <a name="output_wait_for_lease_state"></a> [wait\_for\_lease\_state](#output\_wait\_for\_lease\_state) | n/a |
<!-- END_TF_DOCS -->

---

## Example IAM integration

```hcl
resource "aws_iam_role" "state_machine" {
  name               = "workflow-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume_role.json
}

resource "aws_iam_role_policy" "invoke_lease_manager" {
  role   = aws_iam_role.state_machine.id
  policy = module.sfn_concurrency.lambda_permissions
}
```

---

## Local development

```bash
# 1. Create a virtual environment
python -m venv .venv
source .venv/bin/activate

# 2. Install test dependencies
pip install -U pip
pip install boto3 moto pytest aws-lambda-powertools

# 3. Run the regression suite (includes 100% coverage for the Lambda runtime)
pytest

# Optional: view coverage
pytest --cov=src/lease_manager/lambda_function.py
```

---

## Contributing

1. Fork the repository and create a feature branch.
2. Run `terraform fmt` and `pytest` before opening a PR.
3. Update examples and documentation when toggling or adding inputs.
4. Submit the pull request with a concise summary of the change.

Bug reports and feature requests are welcome through GitHub issues. Please include Terraform version, AWS provider version, and reproduction steps when reporting problems.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE). You are free to use, modify, and distribute the module in personal or commercial projects as long as you retain the license notice.
