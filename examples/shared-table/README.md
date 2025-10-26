# shared-table example

Run two independent Step Functions workflows against a single regional DynamoDB lease table. The example provisions the shared table once and then deploys two application stacks—`analytics` and `batch`—that each configure their own lease prefix and maximum concurrency.

## Quickstart
- Configure AWS credentials for `var.region` (defaults to `eu-central-1`)
- Deploy from this directory:
  ```bash
  terraform init
  terraform apply
  ```
- Start executions for both state machines to see how they honour separate concurrency caps while writing into the same DynamoDB table.

## Topology
- `module.regional_lease_store` owns the DynamoDB table. It sets `create_lambdas = false` so only the storage layer is managed centrally.
- `module.analytics_lease` and `module.batch_lease` reuse that table (`create_dynamodb_table = false`) but provide different `lease_prefix` values. Each module emits its own Lambda function and Step Functions artefacts so teams can tune concurrency per workload.
- Two Step Functions workflows (`analytics` and `batch`) demonstrate how separate applications can borrow the shared module outputs and still sequence `Acquire → Wait → Process → Release → Complete`.

Destroy the resources when finished:
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
| [aws_sfn_state_machine.analytics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sfn_state_machine) | resource |
| [aws_sfn_state_machine.batch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sfn_state_machine) | resource |
| [aws_iam_policy_document.analytics_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.batch_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_region"></a> [region](#input\_region) | AWS region where the shared concurrency infrastructure is deployed. | `string` | `"eu-central-1"` | no |
| <a name="input_shared_table_name"></a> [shared\_table\_name](#input\_shared\_table\_name) | Name of the DynamoDB table that stores concurrency leases for every application in the region. | `string` | `"regional-concurrency-leases"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->