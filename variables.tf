variable "create" {
  type    = bool
  default = true
}

variable "create_lambdas" {
  type    = bool
  default = true
}

variable "create_dynamodb_table" {
  type    = bool
  default = true
}

variable "cloudwatch_logs_retention_in_days" {
  type    = number
  default = 7
}

variable "lease_prefix" {
  type    = string
  default = ""
}

variable "ddb_table_name" {
  type    = string
  default = ""
}

variable "kms_key_arn" {
  type    = string
  default = ""
}

variable "name_prefix" {
  type    = string
  default = "concurrency-mgmt"
}

variable "max_lease_duration_seconds" {
  type    = number
  default = 600
}

variable "max_concurrent_leases" {
  type    = number
  default = 100
}

variable "ddb_deletion_protection_enabled" {
  type    = bool
  default = false
}

variable "ddb_hash_key" {
  type    = string
  default = "PK"
}

variable "ddb_range_key" {
  type    = string
  default = "SK"
}

variable "ddb_ttl_attribute_name" {
  type    = string
  default = "ttl"
}

variable "ddb_billing_mode" {
  type    = string
  default = "PAY_PER_REQUEST"
}

variable "ddb_read_capacity" {
  type    = number
  default = null
}

variable "ddb_write_capacity" {
  type    = number
  default = null
}

variable "ddb_autoscaling_enabled" {
  type    = bool
  default = false
}

variable "ddb_autoscaling_read" {
  type = object({
    max_capacity = number
  })
  default = {
    max_capacity = 1
  }
}

variable "ddb_autoscaling_write" {
  type = object({
    max_capacity = number
  })
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
  type    = string
  default = "$.acquireLease"
}

variable "sfn_post_acquire_lease_state" {
  type    = string
  default = "StartExecution"
}

variable "sfn_post_release_lease_state" {
  type    = string
  default = "NextStep"
}

variable "sfn_acquire_lease_state_name" {
  type    = string
  default = "AcquireLease"
}

variable "sfn_release_lease_state_name" {
  type    = string
  default = "ReleaseLease"
}

variable "end_state_after_release_lease" {
  type    = bool
  default = false
}