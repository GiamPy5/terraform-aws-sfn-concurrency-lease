"""
Concurrency Lease Manager — AWS Lambda Function

Implements a DynamoDB-backed Distributed Lease Pattern to control concurrency
across distributed workflows such as AWS Step Functions Map states.

Features:
- Acquire and release leases with TTL expiration
- Enforces a maximum number of concurrent active leases
- Provides metrics and tracing via AWS Lambda Powertools
"""

from __future__ import annotations

import os
import time
import uuid
import traceback
from typing import Any, Dict, Optional

import boto3
from botocore.exceptions import ClientError, EndpointConnectionError, BotoCoreError
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.utilities.typing import LambdaContext
from aws_lambda_powertools.metrics import MetricUnit

# ---------------------------------------------------------------------
# AWS Powertools setup
# ---------------------------------------------------------------------
logger = Logger(service="concurrency-lease-manager")
tracer = Tracer(service="concurrency-lease-manager")
metrics = Metrics(namespace="ConcurrencyLeaseManager")


# ---------------------------------------------------------------------
# Dependencies container
# ---------------------------------------------------------------------
class Dependencies:
    """Container for external dependencies and environment configuration."""

    def __init__(
        self,
        dynamodb_resource=None,
        env: Optional[Dict[str, str]] = None,
    ) -> None:
        base_env = dict(os.environ)
        if env:
            base_env.update(env)

        # Required env vars
        required = [
            "LEASE_TABLE_NAME",
            "LEASE_HASH_VALUE",
            "LEASE_HASH_KEY",
            "LEASE_RANGE_KEY",
            "MAX_CONCURRENT_LEASES",
            "LEASE_TTL_SECONDS",
        ]
        missing = [k for k in required if k not in base_env]
        if missing:
            raise ValueError(f"Missing required environment variables: {missing}")

        self.dynamodb_resource = dynamodb_resource or boto3.resource("dynamodb")
        self.lease_table_name: str = base_env["LEASE_TABLE_NAME"]
        self.lease_hash_value: str = base_env["LEASE_HASH_VALUE"]
        self.lease_hash_key: str = base_env["LEASE_HASH_KEY"]
        self.lease_range_key: str = base_env["LEASE_RANGE_KEY"]
        self.max_concurrent: int = int(base_env.get("MAX_CONCURRENT_LEASES"))
        self.lease_ttl_seconds: int = int(base_env.get("LEASE_TTL_SECONDS"))

        self.table = self.dynamodb_resource.Table(self.lease_table_name)


# ---------------------------------------------------------------------
# Domain logic
# ---------------------------------------------------------------------
@tracer.capture_method
def acquire_concurrency_lease(
    event: Dict[str, Any], deps: Dependencies
) -> Dict[str, Any]:
    """
    Attempt to acquire a new concurrency lease.

    Returns:
        Dict with one of:
        {
            "status": "acquired",
            "lease_id": "...",
            "lease_expires_at": int
        }
        or
        {
            "status": "wait",
            "current_running": int
        }
        or
        {
            "status": "error",
            "reason": "...",
            "details": "..."
        }
    """
    reference_id = event.get("reference_id")
    now = int(time.time())
    ttl_timestamp = now + deps.lease_ttl_seconds
    current_running = 0
    eks = None

    # -------------------------------
    # Count current active leases
    # -------------------------------
    try:
        while True:
            query_args = {
                "KeyConditionExpression": f"{deps.lease_hash_key} = :pk",
                "ExpressionAttributeValues": {
                    ":pk": deps.lease_hash_value,
                    ":now": now,
                },
                "ProjectionExpression": f"{deps.lease_range_key}, #ttl",
                "ExpressionAttributeNames": {"#ttl": "ttl"},
                "FilterExpression": "#ttl > :now",
                "ConsistentRead": True,
            }

            if eks:
                query_args["ExclusiveStartKey"] = eks

            resp = deps.table.query(**query_args)
            items = resp.get("Items", [])
            current_running += len(items)

            if current_running >= deps.max_concurrent:
                logger.info(
                    "Lease capacity reached",
                    extra={
                        "current_running": current_running,
                        "max_concurrent": deps.max_concurrent,
                    },
                )
                metrics.add_metric("LeaseWaits", MetricUnit.Count, 1)
                return {"status": "wait", "current_running": current_running}

            eks = resp.get("LastEvaluatedKey")
            if not eks:
                break

    except (ClientError, BotoCoreError, EndpointConnectionError) as e:
        logger.exception("Failed to query active leases")
        metrics.add_metric("LeaseAcquireFailures", MetricUnit.Count, 1)
        return {"status": "error", "reason": "dynamodb_query_failed", "details": str(e)}

    # -------------------------------
    # Create new lease item
    # -------------------------------
    lease_id = f"lease-{uuid.uuid4()}"
    item = {
        deps.lease_hash_key: deps.lease_hash_value,
        deps.lease_range_key: lease_id,
        "reference_id": reference_id,
        "status": "active",
        "started_at": now,
        "ttl": ttl_timestamp,
    }

    try:
        deps.table.put_item(Item=item, ConditionExpression=f"attribute_not_exists({deps.lease_range_key})")
        logger.info("Lease acquired", extra={"lease_id": lease_id})
        metrics.add_metric("LeasesAcquired", MetricUnit.Count, 1)
        return {
            "status": "acquired",
            "lease_id": lease_id,
            "lease_expires_at": ttl_timestamp,
        }

    except ClientError as e:
        code = e.response["Error"].get("Code", "")
        if code == "ConditionalCheckFailedException":
            logger.warning("Lease conflict, retry later")
            return {"status": "wait", "current_running": current_running}

        logger.error(
            "Client error creating lease",
            extra={
                "lease_id": lease_id,
                "error": e.response,
                "traceback": traceback.format_exc(),
            },
        )
        metrics.add_metric("LeaseAcquireFailures", MetricUnit.Count, 1)
        return {"status": "error", "reason": "client_error", "details": str(e)}

    except (BotoCoreError, EndpointConnectionError) as e:
        logger.exception("Boto3 or endpoint issue creating lease")
        metrics.add_metric("LeaseAcquireFailures", MetricUnit.Count, 1)
        return {"status": "error", "reason": "boto_error", "details": str(e)}

    except Exception as e:
        logger.exception("Unexpected error acquiring lease")
        metrics.add_metric("LeaseAcquireFailures", MetricUnit.Count, 1)
        return {"status": "error", "reason": "unexpected", "details": str(e)}


@tracer.capture_method
def release_concurrency_lease(
    event: Dict[str, Any], deps: Dependencies
) -> Dict[str, Any]:
    """
    Release an existing concurrency lease.

    Returns:
        {
            "status": "released",
            "lease_id": "...",
        }
        or
        {
            "status": "error",
            "reason": "...",
            "details": "..."
        }
    """
    lease_id = event.get("lease_id")
    if not lease_id:
        return {"status": "error", "reason": "missing_lease_id"}

    try:
        resp = deps.table.delete_item(
            Key={deps.lease_hash_key: deps.lease_hash_value, deps.lease_range_key: lease_id},
            ConditionExpression=f"attribute_exists({deps.lease_hash_key})",
        )
        logger.info("Lease released", extra={"lease_id": lease_id})
        metrics.add_metric("LeasesReleased", MetricUnit.Count, 1)
        return {"status": "released", "lease_id": lease_id, "response": resp}

    except ClientError as e:
        code = e.response["Error"].get("Code", "")
        if code == "ConditionalCheckFailedException":
            logger.warning(
                "Lease not found during release", extra={"lease_id": lease_id}
            )
            return {
                "status": "released",
                "lease_id": lease_id,
                "note": "already expired or missing",
            }

        logger.exception("Client error releasing lease")
        metrics.add_metric("LeaseReleaseFailures", MetricUnit.Count, 1)
        return {
            "status": "error",
            "reason": "client_error",
            "details": str(e),
            "lease_id": lease_id,
        }

    except (BotoCoreError, EndpointConnectionError) as e:
        logger.exception("Network or Boto3 error releasing lease")
        metrics.add_metric("LeaseReleaseFailures", MetricUnit.Count, 1)
        return {
            "status": "error",
            "reason": "boto_error",
            "details": str(e),
            "lease_id": lease_id,
        }

    except Exception as e:
        logger.exception("Unexpected error releasing lease")
        metrics.add_metric("LeaseReleaseFailures", MetricUnit.Count, 1)
        return {
            "status": "error",
            "reason": "unexpected",
            "details": str(e),
            "lease_id": lease_id,
        }


# ---------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------
@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
@metrics.log_metrics(capture_cold_start_metric=True)
def lambda_handler(
    event: Dict[str, Any],
    context: LambdaContext,
    deps: Optional[Dependencies] = None,
) -> Dict[str, Any]:
    """
    AWS Lambda entrypoint.

    Expects an `action` field in the event:
        - "acquire": acquire a new lease
        - "release": release a lease

    Returns a JSON response with `status`, and possibly `lease_id` or `reason`.
    """
    deps = deps or Dependencies()
    action = (event.get("action") or "").lower().strip()
    logger.info("Received lease action", extra={"action": action})

    try:
        if action == "acquire":
            result = acquire_concurrency_lease(event, deps)
        elif action == "release":
            result = release_concurrency_lease(event, deps)
        else:
            logger.warning("Unknown action", extra={"event": event})
            result = {"status": "error", "reason": "unknown_action"}

        logger.debug("Lease manager result", extra=result)
        return result

    except Exception as e:
        logger.exception("Fatal error in lambda handler")
        metrics.add_metric("UnhandledExceptions", MetricUnit.Count, 1)
        return {"status": "error", "reason": "unhandled_exception", "details": str(e)}
