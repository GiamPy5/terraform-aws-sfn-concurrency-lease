import boto3
import importlib
import sys
from pathlib import Path

import pytest
from botocore.exceptions import ClientError, EndpointConnectionError
from moto import mock_aws

ROOT = Path(__file__).parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

lambda_mod = importlib.import_module("src.lease_manager.lambda_function")


# --------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------
TABLE_NAME = "concurrency-leases-example"


def _base_env(overrides=None):
    env = {
        "LEASE_TABLE_NAME": TABLE_NAME,
        "LEASE_HASH_VALUE": "CONCURRENCY_LEASES",
        "LEASE_HASH_KEY": "PK",
        "LEASE_RANGE_KEY": "SK",
        "MAX_CONCURRENT_LEASES": "1",
        "LEASE_TTL_SECONDS": "60",
    }
    if overrides:
        env.update(overrides)
    return env


def _setup_table(resource):
    resource.create_table(
        TableName=TABLE_NAME,
        KeySchema=[
            {"AttributeName": "PK", "KeyType": "HASH"},
            {"AttributeName": "SK", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "PK", "AttributeType": "S"},
            {"AttributeName": "SK", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )


# --------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------
@mock_aws
def test_dependencies_missing_env_vars():
    resource = boto3.resource("dynamodb", region_name="eu-central-1")
    _setup_table(resource)

    env = _base_env()
    env.pop("LEASE_RANGE_KEY")

    with pytest.raises(ValueError) as exc:
        lambda_mod.Dependencies(dynamodb_resource=resource, env=env)

    assert "Missing required environment variables" in str(exc.value)


@mock_aws
def test_acquire_concurrency_lease_success(fake_context):
    resource = boto3.resource("dynamodb", region_name="eu-central-1")
    _setup_table(resource)
    deps = lambda_mod.Dependencies(dynamodb_resource=resource, env=_base_env())

    event = {"action": "acquire", "reference_id": "job-123"}
    result = lambda_mod.acquire_concurrency_lease(event, deps)

    assert result["status"] == "acquired"
    assert result["lease_id"].startswith("lease-")


@mock_aws
def test_acquire_concurrency_lease_waits_when_at_capacity(fake_context):
    resource = boto3.resource("dynamodb", region_name="eu-central-1")
    _setup_table(resource)
    deps = lambda_mod.Dependencies(dynamodb_resource=resource, env=_base_env())

    first = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)
    assert first["status"] == "acquired"

    second = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)
    assert second["status"] == "wait"
    assert second["current_running"] == 1


@mock_aws
def test_release_concurrency_lease_happy_path(fake_context):
    resource = boto3.resource("dynamodb", region_name="eu-central-1")
    _setup_table(resource)
    deps = lambda_mod.Dependencies(dynamodb_resource=resource, env=_base_env())

    acquired = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)
    lease_id = acquired["lease_id"]

    result = lambda_mod.release_concurrency_lease({"lease_id": lease_id}, deps)
    assert result["status"] == "released"
    assert result["lease_id"] == lease_id


@mock_aws
def test_release_concurrency_lease_missing_item(fake_context):
    resource = boto3.resource("dynamodb", region_name="eu-central-1")
    _setup_table(resource)
    deps = lambda_mod.Dependencies(dynamodb_resource=resource, env=_base_env())

    result = lambda_mod.release_concurrency_lease({"lease_id": "missing"}, deps)
    assert result["status"] == "released"
    assert result["note"] == "already expired or missing"


@mock_aws
def test_lambda_handler_routes_actions(fake_context):
    resource = boto3.resource("dynamodb", region_name="eu-central-1")
    _setup_table(resource)
    deps = lambda_mod.Dependencies(dynamodb_resource=resource, env=_base_env())

    acquire_out = lambda_mod.lambda_handler({"action": "acquire"}, fake_context, deps=deps)
    assert acquire_out["status"] == "acquired"

    lease_id = acquire_out["lease_id"]
    release_out = lambda_mod.lambda_handler({"action": "release", "lease_id": lease_id}, fake_context, deps=deps)
    assert release_out["status"] == "released"

    error_out = lambda_mod.lambda_handler({"action": "unknown"}, fake_context, deps=deps)
    assert error_out["reason"] == "unknown_action"


# --------------------------------------------------------------------
# Stubs for error-path coverage
# --------------------------------------------------------------------
class StubTable:
    def __init__(self, query_sequence=None, put_sequence=None, delete_sequence=None):
        self._query_sequence = list(query_sequence or [{}])
        self._put_sequence = list(put_sequence or [{}])
        self._delete_sequence = list(delete_sequence or [{}])
        self.query_calls = []

    def _pop(self, sequence):
        if sequence:
            item = sequence.pop(0)
        else:
            item = {}
        if isinstance(item, Exception):
            raise item
        return item

    def query(self, **kwargs):
        self.query_calls.append(kwargs)
        return self._pop(self._query_sequence)

    def put_item(self, **kwargs):
        return self._pop(self._put_sequence)

    def delete_item(self, **kwargs):
        return self._pop(self._delete_sequence)


class StubDeps:
    def __init__(
        self,
        *,
        query_sequence=None,
        put_sequence=None,
        delete_sequence=None,
        max_concurrent=1,
    ):
        self.lease_hash_key = "PK"
        self.lease_range_key = "SK"
        self.lease_hash_value = "CONCURRENCY_LEASES"
        self.max_concurrent = max_concurrent
        self.lease_ttl_seconds = 60
        self.table = StubTable(
            query_sequence=query_sequence,
            put_sequence=put_sequence,
            delete_sequence=delete_sequence,
        )


# --------------------------------------------------------------------
# Error-path tests for acquire_concurrency_lease
# --------------------------------------------------------------------
def test_acquire_uses_exclusive_start_key_on_paged_query():
    deps = StubDeps(
        query_sequence=[
            {"Items": [], "LastEvaluatedKey": {"PK": "a"}},
            {"Items": []},
        ]
    )
    result = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)

    assert result["status"] == "acquired"
    # Second query should include pagination marker
    assert "ExclusiveStartKey" in deps.table.query_calls[1]


def test_acquire_handles_query_client_error():
    error = ClientError({"Error": {"Code": "ThrottlingException"}}, "Query")
    deps = StubDeps(query_sequence=[error])

    result = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)

    assert result == {
        "status": "error",
        "reason": "dynamodb_query_failed",
        "details": str(error),
    }


def test_acquire_handles_conditional_put_conflict():
    conflict = ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, "PutItem")
    deps = StubDeps(put_sequence=[conflict])

    result = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)

    assert result["status"] == "wait"


def test_acquire_handles_put_client_error():
    client_error = ClientError({"Error": {"Code": "SomeOther"}}, "PutItem")
    deps = StubDeps(put_sequence=[client_error])

    result = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)

    assert result["reason"] == "client_error"
    assert "SomeOther" in result["details"]


def test_acquire_handles_boto_error():
    deps = StubDeps(put_sequence=[EndpointConnectionError(endpoint_url="https://example.com")])

    result = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)

    assert result["reason"] == "boto_error"


def test_acquire_handles_unexpected_error():
    deps = StubDeps(put_sequence=[Exception("boom")])

    result = lambda_mod.acquire_concurrency_lease({"action": "acquire"}, deps)

    assert result["reason"] == "unexpected"


# --------------------------------------------------------------------
# Error-path tests for release_concurrency_lease
# --------------------------------------------------------------------
def test_release_requires_lease_id():
    deps = StubDeps()
    result = lambda_mod.release_concurrency_lease({}, deps)
    assert result["reason"] == "missing_lease_id"


def test_release_handles_conditional_check_failure():
    conflict = ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, "DeleteItem")
    deps = StubDeps(delete_sequence=[conflict])

    result = lambda_mod.release_concurrency_lease({"lease_id": "abc"}, deps)

    assert result["status"] == "released"
    assert result["note"] == "already expired or missing"


def test_release_handles_client_error():
    error = ClientError({"Error": {"Code": "InternalFailure"}}, "DeleteItem")
    deps = StubDeps(delete_sequence=[error])

    result = lambda_mod.release_concurrency_lease({"lease_id": "abc"}, deps)

    assert result["reason"] == "client_error"


def test_release_handles_boto_error():
    deps = StubDeps(delete_sequence=[EndpointConnectionError(endpoint_url="https://example.com")])

    result = lambda_mod.release_concurrency_lease({"lease_id": "abc"}, deps)

    assert result["reason"] == "boto_error"


def test_release_handles_unexpected_error():
    deps = StubDeps(delete_sequence=[Exception("boom")])

    result = lambda_mod.release_concurrency_lease({"lease_id": "abc"}, deps)

    assert result["reason"] == "unexpected"


def test_lambda_handler_catches_unhandled(monkeypatch, fake_context):
    def boom(event, deps):
        raise RuntimeError("explode")

    monkeypatch.setattr(lambda_mod, "acquire_concurrency_lease", boom)

    result = lambda_mod.lambda_handler({"action": "acquire"}, fake_context, deps=StubDeps())

    assert result["reason"] == "unhandled_exception"
