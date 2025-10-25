output "dynamodb_table_name" {
  value = local.ddb_table_name
}

output "dynamodb_table_arn" {
  value = local.ddb_table_arn
}

output "acquire_lease_state" {
  value = try(jsonencode(local.acquire_lease_state), "")
}

output "release_lease_state" {
  value = try(jsonencode(local.release_lease_state), "")
}

output "sfn_acquire_lease_state_name" {
  value = var.sfn_acquire_lease_state_name
}

output "sfn_release_lease_state_name" {
  value = var.sfn_release_lease_state_name
}

output "lambda_permissions" {
  value = try(data.aws_iam_policy_document.state_machine_permissions[0].json, "")
}
