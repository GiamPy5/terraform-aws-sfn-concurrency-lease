variable "region" {
  description = "AWS region where the example will be deployed."
  type        = string
  default     = "eu-central-1"
}

variable "lease_table_name" {
  description = "Name of the DynamoDB table that stores concurrency leases."
  type        = string
  default     = "example-concurrency-leases"
}
