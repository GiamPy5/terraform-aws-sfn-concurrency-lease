# terraform-aws-sfn-concurrency-lease

Composable Terraform module that adds safe concurrency control to AWS Step Functions.  
It wraps a purpose-built Lambda function, DynamoDB table, and IAM wiring to implement the distributed lease pattern so you can throttle fan-out workloads without rewriting business logic.

---

## Why this module?
- **Deterministic fan-out throttling** – enforce a fixed number of parallel tasks across Step Functions `Map` states or nested workflows.
- **Drop-in state machine guards** – ship pre-defined `AcquireLease` / `ReleaseLease` state JSON that can be merged into existing definitions.
- **Production defaults** – opinionated CloudWatch log retention, Powertools observability configuration, and optional DynamoDB autoscaling.
- **Transparent IAM** – emitted inline policies and managed policy attachments so platform teams can review grants before deploying.
- **Tested runtime** – the bundled Lambda function is covered by 100% unit test coverage using moto-backed regression tests.

---

## Quick start

```hcl
module "sfn_concurrency" {
  source = "github.com/your-org/terraform-aws-sfn-concurrency-lease"

  name_prefix               = "analytics-pipeline"
  max_concurrent_leases     = 10
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

## Module inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `create` | bool | `true` | Master switch – disable to prevent all resource creation. |
| `create_lambdas` | bool | `true` | Control creation of the `lease-manager` Lambda and IAM role. |
| `create_dynamodb_table` | bool | `true` | Toggle managed DynamoDB table creation. |
| `ddb_table_name` | string | `""` | Override table name. Required when reusing an external table. |
| `lease_prefix` | string | `""` | Optional partition suffix used when multiple workflows share a table. |
| `max_concurrent_leases` | number | `100` | Maximum number of active leases allowed at once. |
| `max_lease_duration_seconds` | number | `600` | TTL applied to each lease item. |
| `cloudwatch_logs_retention_in_days` | number | `7` | Retention period for Lambda log groups. |
| `kms_key_arn` | string | `""` | Optional CMK ARN for encrypting Lambda environment variables. |
| `ddb_hash_key` / `ddb_range_key` | string | `"PK"` / `"SK"` | Attribute names for the table primary key and sort key. |
| `ddb_ttl_attribute_name` | string | `"ttl"` | Attribute used for DynamoDB TTL. |
| `ddb_billing_mode` | string | `"PAY_PER_REQUEST"` | Switch to `PROVISIONED` to set read/write capacity. |
| `ddb_read_capacity` / `ddb_write_capacity` | number | `null` | Provisioned throughput when billing mode is `PROVISIONED`. |
| `ddb_autoscaling_enabled` | bool | `false` | Enable DynamoDB autoscaling (requires provisioned billing). |
| `ddb_autoscaling_read` / `ddb_autoscaling_write` | object | `{ max_capacity = 1 }` | Upper bounds for autoscaling policies. |
| `ddb_deletion_protection_enabled` | bool | `false` | Protect managed table from deletion. |
| `powertools_configuration` | object | _(see defaults)_ | Fine-grained AWS Lambda Powertools configuration (metrics namespace, logger sample rate, tracing, etc.). |
| `sfn_resource_id_jsonpath` | string | `"$.resource_id"` | JSONPath used to fetch the resource identifier in the `AcquireLease` state. |
| `sfn_lease_id_jsonpath` | string | `"$.lease_id"` | JSONPath used to locate the `lease_id` for release. |
| `sfn_lease_result_path` | string | `"$.acquireLease"` | Where to store acquisition results in the Step Functions context. |
| `sfn_post_acquire_lease_state` | string | `"StartExecution"` | Next state name after `AcquireLease` when the lease is granted. |
| `sfn_post_release_lease_state` | string | `"NextStep"` | Next state name after `ReleaseLease` when the lease finishes. |
| `sfn_acquire_lease_state_name` / `sfn_release_lease_state_name` | string | `"AcquireLease"` / `"ReleaseLease"` | Keys used inside the exported state JSON. Override if these names collide with existing states. |
| `end_state_after_release_lease` | bool | `false` | End the workflow immediately after releasing the lease. |

> Tip: use `lease_prefix` when multiple teams/projects share the same DynamoDB table so each workload acquires leases from an isolated partition key.

---

## Module outputs

| Name | Description |
| --- | --- |
| `dynamodb_table_name` / `dynamodb_table_arn` | The resolved table name and ARN (managed or external). |
| `acquire_lease_state` | JSON-encoded Step Functions state fragment for acquiring a lease. |
| `release_lease_state` | JSON-encoded fragment for releasing a lease (honours `end_state_after_release_lease`). |
| `sfn_acquire_lease_state_name` / `sfn_release_lease_state_name` | Convenience outputs for referencing the state keys without hard-coding. |
| `lambda_permissions` | Inline IAM policy JSON that grants `lambda:InvokeFunction` on the lease-manager Lambda. Attach this to your Step Functions role. |

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
