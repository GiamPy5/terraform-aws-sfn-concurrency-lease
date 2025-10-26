variable "region" {
  description = "AWS region where the shared concurrency infrastructure is deployed."
  type        = string
  default     = "eu-central-1"
}

variable "shared_table_name" {
  description = "Name of the DynamoDB table that stores concurrency leases for every application in the region."
  type        = string
  default     = "regional-concurrency-leases"
}
