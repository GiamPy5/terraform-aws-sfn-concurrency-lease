locals {
  acquire_lease_state = {
    (var.sfn_acquire_lease_state_name) = {
      Type     = "Task"
      Resource = "arn:aws:states:::lambda:invoke"
      Parameters = {
        FunctionName = try(module.lambda["lease-manager"].lambda_function_name, "")
        Payload = {
          action          = "acquire"
          "resource_id.$" = var.sfn_resource_id_jsonpath
        }
      }
      ResultSelector = {
        "Payload.$" = "$.Payload"
      }
      ResultPath = var.sfn_lease_result_path
      Next       = var.sfn_check_lease_state_name
    }
  }

  check_lease_status_state = {
    (var.sfn_check_lease_state_name) = {
      Type = "Choice"
      Choices = [
        {
          Variable     = "${var.sfn_lease_result_path}.Payload.status"
          StringEquals = "wait"
          Next         = var.sfn_wait_state_name
        }
      ]
      Default = var.sfn_post_acquire_lease_state
    }
  }

  wait_for_lease_state = {
    (var.sfn_wait_state_name) = {
      Type    = "Wait"
      Seconds = var.sfn_wait_seconds
      Next    = var.sfn_acquire_lease_state_name
    }
  }

  release_lease_state = {
    (var.sfn_release_lease_state_name) = merge(
      {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = try(module.lambda["lease-manager"].lambda_function_name, "")
          Payload = {
            action       = "release"
            "lease_id.$" = var.sfn_lease_id_jsonpath
          }
        }
        ResultSelector = {
          "Payload.$" = "$.Payload"
        }
        ResultPath = var.sfn_release_lease_result_path
      },
      var.end_state_after_release_lease ? { End = true } : { Next = var.sfn_post_release_lease_state }
    )
  }
}
