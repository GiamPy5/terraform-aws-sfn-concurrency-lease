PWD=$(shell pwd)
USERID=$(shell id -u)

.PHONY: test coverage all

all: lint docs tfsec test

test: ## Run pytest locally
	@echo "🧪 Running pytest locally..."
	@pyenv exec pytest -q --maxfail=1 --disable-warnings -ras

coverage: ## Run tests with coverage report
	@echo "📊 Running tests with coverage..."
	@pyenv exec pytest --cov=src/ --cov-report=xml:coverage.xml --disable-warnings -q

docs:
	@echo "Running terraform docs..."
	@docker run --rm --volume "${PWD}:/terraform-docs" -u ${USERID} quay.io/terraform-docs/terraform-docs:0.20.0 markdown --output-file README.md --output-mode inject /terraform-docs
	@docker run --rm --volume "${PWD}/examples/complete:/terraform-docs" -u ${USERID} quay.io/terraform-docs/terraform-docs:0.20.0 markdown --output-file README.md --output-mode inject /terraform-docs
	@docker run --rm --volume "${PWD}/examples/shared-table:/terraform-docs" -u ${USERID} quay.io/terraform-docs/terraform-docs:0.20.0 markdown --output-file README.md --output-mode inject /terraform-docs

lint:
	@echo "Running terraform fmt..."
	@terraform fmt --recursive

tfsec:
	@echo "Running tfsec..."
	@docker run --rm -it -v "${PWD}/examples/complete:/src" aquasec/tfsec /src