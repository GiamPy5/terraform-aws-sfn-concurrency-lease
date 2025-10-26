variable "create" {
  type        = bool
  description = "Master toggle to enable or disable creation of every resource in the module."
  default     = true
}

variable "create_lambdas" {
  type        = bool
  description = "When true, package and deploy the lease-manager Lambda function and supporting IAM role."
  default     = true
}

variable "lambdas_tracing_enabled" {
  type        = bool
  description = "Attach AWS X-Ray tracing configuration and policies to the lease-manager Lambda."
  default     = false
}

variable "create_dynamodb_table" {
  type        = bool
  description = "Control whether the module provisions the DynamoDB lease table or expects an existing table."
  default     = true
}

variable "cloudwatch_logs_retention_in_days" {
  type        = number
  description = "Retention period, in days, applied to the Lambda function's CloudWatch Logs group."
  default     = 7
}

variable "lease_prefix" {
  type        = string
  description = "Optional suffix added to the DynamoDB partition key so multiple workloads can share a table without collisions."
  default     = ""
}

variable "ddb_table_name" {
  type        = string
  description = "Name of the DynamoDB table to use when create_dynamodb_table is false; otherwise used as an override for the managed table."
  default     = ""
}

variable "kms_key_arn" {
  type        = string
  description = "Customer managed KMS key ARN for encrypting Lambda environment variables and any DynamoDB encryption context."
  default     = ""
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all named AWS resources created by the module."
  default     = "concurrency-mgmt"
}

variable "max_lease_duration_seconds" {
  type        = number
  description = "Time-to-live in seconds applied to each lease item stored in DynamoDB."
  default     = 600
}

variable "max_concurrent_leases" {
  type        = number
  description = "Maximum number of active leases allowed before new requests are told to wait."
  default     = 100
}

variable "ddb_deletion_protection_enabled" {
  type        = bool
  description = "Enable DynamoDB deletion protection on the managed lease table."
  default     = false
}

variable "ddb_hash_key" {
  type        = string
  description = "Name of the DynamoDB partition key attribute used in the lease table."
  default     = "PK"
}

variable "ddb_range_key" {
  type        = string
  description = "Name of the DynamoDB sort key attribute used in the lease table."
  default     = "SK"
}

variable "ddb_ttl_attribute_name" {
  type        = string
  description = "Attribute name that stores the TTL timestamp for automatically expiring leases."
  default     = "ttl"
}

variable "ddb_billing_mode" {
  type        = string
  description = "Billing mode for the DynamoDB table; set to PROVISIONED to supply read/write capacity."
  default     = "PAY_PER_REQUEST"
}

variable "ddb_read_capacity" {
  type        = number
  description = "Provisioned read capacity units when using PROVISIONED billing mode."
  default     = 10
}

variable "ddb_write_capacity" {
  type        = number
  description = "Provisioned write capacity units when using PROVISIONED billing mode."
  default     = 10
}

variable "ddb_point_in_time_recovery_enabled" {
  type        = bool
  description = "Enable Point-in-Time Recovery (continuous backups) for the DynamoDB table."
  default     = false
}

variable "ddb_autoscaling_enabled" {
  type        = bool
  description = "Enable DynamoDB Application Auto Scaling policies for provisioned capacity."
  default     = false
}

variable "ddb_autoscaling_read" {
  type = object({
    max_capacity = number
  })
  description = "Autoscaling limits for read capacity when autoscaling is enabled."
  default = {
    max_capacity = 1
  }
}

variable "ddb_autoscaling_write" {
  type = object({
    max_capacity = number
  })
  description = "Autoscaling limits for write capacity when autoscaling is enabled."
  default = {
    max_capacity = 1
  }
}

variable "powertools_configuration" {
  type = object({
    metrics_namespace       = optional(string, "terraform-aws-sfn-concurrency-lease")
    metrics_disabled        = optional(bool, false)
    trace_disabled          = optional(bool, false)
    tracer_capture_response = optional(bool, true)
    tracer_capture_error    = optional(bool, true)
    trace_middlewares       = optional(list(string), [])
    logger_log_event        = optional(bool, false)
    logger_sample_rate      = optional(number, 0.1)
    log_deduplication       = optional(bool, false)
    parameters_max_age      = optional(number, 10)
    parameters_ssm_decrypt  = optional(bool, false)
    dev_mode                = optional(bool, false)
    log_level               = optional(string, "INFO")
  })
  description = "AWS Lambda Powertools settings injected into the lease-manager Lambda environment."
  default = {
    metrics_namespace       = "terraform-aws-sfn-concurrency-lease"
    metrics_disabled        = false
    trace_disabled          = false
    tracer_capture_response = true
    tracer_capture_error    = true
    trace_middlewares       = []
    logger_log_event        = true
    logger_sample_rate      = 0.1
    log_deduplication       = false
    parameters_max_age      = 10
    parameters_ssm_decrypt  = false
    dev_mode                = true
    log_level               = "DEBUG"
  }
}

variable "sfn_release_lease_result_path" {
  type        = string
  description = "JSONPath location within the Step Functions context to store the release lease Lambda result."
  default     = "$.releaseLease"
}

variable "sfn_resource_id_jsonpath" {
  type        = string
  default     = "$.resource_id"
  description = "JSONPath to extract the resource ID from the Step Functions context for the acquire step."
}

variable "sfn_lease_id_jsonpath" {
  type        = string
  default     = "$.lease_id"
  description = "JSONPath to extract the lease ID from the Step Functions context for the release step."
}

variable "sfn_lease_result_path" {
  type        = string
  description = "JSONPath within the state machine context where the acquire lease Lambda result will be stored."
  default     = "$.acquireLease"
}

variable "sfn_post_acquire_lease_state" {
  type        = string
  description = "Name of the next state entered when a lease is acquired successfully."
  default     = "StartExecution"
}

variable "sfn_post_release_lease_state" {
  type        = string
  description = "Name of the next state entered after releasing a lease when end_state_after_release_lease is false."
  default     = "NextStep"
}

variable "sfn_check_lease_state_name" {
  type        = string
  default     = "CheckLeaseStatus"
  description = "State name for the optional Choice state that inspects the acquire result."
}

variable "sfn_acquire_lease_state_name" {
  type        = string
  description = "State name used for the generated AcquireLease task."
  default     = "AcquireLease"
}

variable "sfn_release_lease_state_name" {
  type        = string
  description = "State name used for the generated ReleaseLease task."
  default     = "ReleaseLease"
}

variable "sfn_wait_state_name" {
  type        = string
  default     = "WaitForLease"
  description = "State name for the optional Wait state that pauses before retrying an acquire."
}

variable "sfn_wait_seconds" {
  type        = number
  default     = 5
  description = "Seconds the Wait state should pause before retrying an acquire call."
}

variable "end_state_after_release_lease" {
  type        = bool
  description = "When true, the ReleaseLease state terminates the workflow; otherwise it transitions to sfn_post_release_lease_state."
  default     = false
}
