.PHONY: docs-api

# Regenerate Markdown API reference under docs/api/ by scraping `///` doc
# comments from Sources/. Consumed by the www site at build time.
docs-api:
	python3 scripts/gen-api-docs.py
