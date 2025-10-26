# shared-table example

Demonstrates how platform teams can provision a single DynamoDB lease table and let multiple Step Functions workloads across the region share it safely. Two Distributed Map workflows (`analytics` and `batch`) read their items from S3 objects, acquire leases with distinct prefixes, and honour different concurrency caps while writing back to the same table.

## Prerequisites
- Terraform `~> 1.6`
- AWS credentials with permissions to create DynamoDB, Lambda, Step Functions, IAM, and S3 resources in the target region (defaults to `eu-central-1`)

## Deploy
```bash
cd examples/shared-table
terraform init
terraform apply
```

Terraform provisions:
- One DynamoDB table (`regional-concurrency-leases`) managed by `module.regional_lease_store`
- Two lease manager Lambdas with per-application settings
- An S3 bucket that stores JSON arrays of work items for each workflow
- Distributed Map state machines for analytics and batch workloads, each with its own lease prefix and concurrency limit

## Exercise the workflows
After `terraform apply`, start executions for the two state machines (input `{}` is sufficient because the Map states load items from S3):
```bash
aws stepfunctions start-execution \
  --state-machine-arn $(aws stepfunctions list-state-machines \
    --query "stateMachines[?name=='shared-lease-platform-analytics-workflow'].stateMachineArn" \
    --output text) \
  --input '{}'

aws stepfunctions start-execution \
  --state-machine-arn $(aws stepfunctions list-state-machines \
    --query "stateMachines[?name=='shared-lease-platform-batch-workflow'].stateMachineArn" \
    --output text) \
  --input '{}'
```

- The analytics workflow processes 30 items with a lease pool of 15
- The batch ETL workflow processes 20 items with a lease pool of 5

Monitor the executions to see each Map worker loop through `AcquireLease → (optional Wait) → Process → Release`, all backed by the shared DynamoDB table.

## Tear down
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
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_analytics_lease"></a> [analytics\_lease](#module\_analytics\_lease) | ./../.. | n/a |
| <a name="module_batch_lease"></a> [batch\_lease](#module\_batch\_lease) | ./../.. | n/a |
| <a name="module_regional_lease_store"></a> [regional\_lease\_store](#module\_regional\_lease\_store) | ./../.. | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_iam_role.analytics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.batch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.analytics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.batch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_s3_bucket.work_items](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_object.analytics_items](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_s3_object.batch_items](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_sfn_state_machine.analytics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sfn_state_machine) | resource |
| [aws_sfn_state_machine.batch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sfn_state_machine) | resource |
| [aws_iam_policy_document.analytics_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.analytics_combined_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.analytics_s3_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.batch_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.batch_combined_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.batch_s3_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_region"></a> [region](#input\_region) | AWS region where the shared lease infrastructure will be deployed. | `string` | `"eu-central-1"` | no |
| <a name="input_shared_table_name"></a> [shared\_table\_name](#input\_shared\_table\_name) | Name of the DynamoDB table that will be shared across applications in the region. | `string` | `"regional-concurrency-leases"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->