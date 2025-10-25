locals {
  acquire_lease_state = {
    (var.sfn_acquire_lease_state_name) = {
      Type     = "Task"
      Resource = "arn:aws:states:::lambda:invoke"
      Parameters = {
        FunctionName = module.lambda["lease-manager"].lambda_function_name
        Payload = {
          action          = "acquire"
          "resource_id.$" = var.sfn_resource_id_jsonpath
        }
      }
      ResultPath = var.sfn_lease_result_path
      Next       = var.sfn_post_acquire_lease_state
    }
  }

  release_lease_state = {
    (var.sfn_release_lease_state_name) = merge(
      {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = module.lambda["lease-manager"].lambda_function_name
          Payload = {
            action       = "release"
            "lease_id.$" = var.sfn_lease_id_jsonpath
          }
        }
      },
      var.end_state_after_release_lease ? { End = true } : { Next = var.sfn_post_release_lease_state }
    )
  }
}
