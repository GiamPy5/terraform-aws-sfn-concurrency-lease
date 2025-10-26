# complete example

## Quickstart

### 1. Prerequisites
- Terraform `~> 1.6`
- Configured AWS CLI credentials with permissions to create Step Functions, Lambda, DynamoDB, IAM, and KMS resources in your chosen region
- (Optional) `aws` CLI for running a smoke test of the state machine

### 2. Configure variables
The example reads values from `examples/complete/variables.tf`. Override them via a `terraform.tfvars` or `-var` flags if you need to change:
- `region`: deployment region (defaults to `eu-central-1`)
- `lease_table_name`: name for the managed DynamoDB table

Inside `examples/complete/main.tf` the module exposes the same inputs as the root module. You can tweak key concurrency controls before deploying:
- `max_concurrent_leases`: hard limit on inflight workloads
- `max_lease_duration_seconds`: TTL applied to each lease
- `lease_prefix`: prefix partition in the DynamoDB table when sharing capacity
- `sfn_*` inputs: rename or reposition the `AcquireLease`, `CheckLeaseStatus`, `WaitForLease`, and `ReleaseLease` states inside your workflows

### 3. Deploy the example
```bash
cd examples/complete
terraform init
terraform apply
```
Terraform will provision the DynamoDB table, packaged Lambda function, IAM role and policies, a KMS CMK for Lambda environment encryption, an S3 object containing 50 JSON work items, and an example Step Functions state machine named `example-sfn-concurrency-lease-workflow`.

### 4. Exercise the Step Function
The workflow loads 50 items from the provisioned S3 object and processes them with a Distributed Map. The object contains a JSON array where each element looks like `{"resource_id":"item-00"}`. Each map worker acquires a lease before starting, so with `max_concurrent_leases = 5` no more than five items run in parallel.

**From the AWS console**
1. Navigate to Step Functions → State machines → `example-sfn-concurrency-lease-workflow`
2. Choose *Start execution* and leave the input empty (`{}`) – the Distributed Map will automatically stream items from the S3 object.
3. Start several executions back-to-back. You should see some map workers cycling through the `AcquireLease` → `WaitForLease` loop until capacity frees up.

**Using the AWS CLI**
```bash
STATE_MACHINE_ARN=$(aws stepfunctions list-state-machines --query "stateMachines[?name=='example-sfn-concurrency-lease-workflow'].stateMachineArn" --output text)
aws stepfunctions start-execution \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --input '{}'
```
Launch the command a few times to build pressure on the concurrency lease and observe workers pausing until leases are released.

### 5. Clean up
Destroy the resources once you finish testing:
```bash
terraform destroy
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.6 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.18.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_dedicated_ddb_table"></a> [dedicated\_ddb\_table](#module\_dedicated\_ddb\_table) | ./../.. | n/a |
| <a name="module_disabled"></a> [disabled](#module\_disabled) | ./../.. | n/a |
| <a name="module_existing_ddb_table"></a> [existing\_ddb\_table](#module\_existing\_ddb\_table) | ./../.. | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_dynamodb_table.example](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table) | resource |
| [aws_iam_role.state_machine](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.state_machine](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.work_items](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.encryption](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_object.work_items](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_sfn_state_machine.distributed_map](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sfn_state_machine) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.state_machine_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_machine_map_permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_machine_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_machine_s3_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_lease_table_name"></a> [lease\_table\_name](#input\_lease\_table\_name) | Name of the DynamoDB table that stores concurrency leases. | `string` | `"example-concurrency-leases"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region where the example will be deployed. | `string` | `"eu-central-1"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
