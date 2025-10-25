.PHONY: test coverage

test: ## Run pytest locally
	@echo "🧪 Running pytest locally..."
	@pyenv exec pytest -q --maxfail=1 --disable-warnings -ras

coverage: ## Run tests with coverage report
	@echo "📊 Running tests with coverage..."
	@pyenv exec pytest --cov=src/ --cov-report=term-missing --disable-warnings -q