import os
import importlib.util
import sys
import pytest
from pathlib import Path

# Ensure boto3 clients constructed in tests have a default region.
os.environ.setdefault("AWS_REGION", "eu-central-1")
os.environ.setdefault("AWS_DEFAULT_REGION", "eu-central-1")

# --------------------------------------------------------------------
# Helpers for dynamically loading lambdas
# --------------------------------------------------------------------

def load_lambda(name: str, file: Path):
    """Load a lambda file as a Python module under the given name."""
    spec = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# Root folder for all lambdas
LAMBDA_ROOT = Path(__file__).parents[1] / "src"

# Autoload every lambda_function.py
for lambda_dir in LAMBDA_ROOT.iterdir():
    if not lambda_dir.is_dir():
        continue

    for candidate in ["lambda_function.py"]:
        lambda_file = lambda_dir / candidate
        if lambda_file.exists():
            module_name = f"{lambda_dir.name}.{candidate.replace('.py','')}"
            load_lambda(module_name, lambda_file)
            break


# --------------------------------------------------------------------
# Shared fake LambdaContext for tests
# --------------------------------------------------------------------

class FakeContext:
    function_name = "test-func"
    memory_limit_in_mb = 128
    invoked_function_arn = "arn:aws:lambda:eu-central-1:123456789012:function:test"
    aws_request_id = "test-request-id"

@pytest.fixture
def fake_context():
    return FakeContext()