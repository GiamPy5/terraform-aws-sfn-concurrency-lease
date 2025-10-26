variable "region" {
  description = "AWS region where the shared lease infrastructure will be deployed."
  type        = string
  default     = "eu-central-1"
}

variable "shared_table_name" {
  description = "Name of the DynamoDB table that will be shared across applications in the region."
  type        = string
  default     = "regional-concurrency-leases"
}
