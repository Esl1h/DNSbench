BIN     := dnsbench
SRC     := cmd/cli.v
VFLAGS  := -prod

.PHONY: all build dev run test fmt fmt-check vet check schema clean

all: build

build:
	v $(VFLAGS) -o $(BIN) $(SRC)

dev:
	v -g -o $(BIN) $(SRC)

run: dev
	./$(BIN)

test:
	v test .

fmt:
	v fmt -w .

# CI runs `v fmt -verify`; `make fmt` rewrites and can never fail, so `check` uses this.
fmt-check:
	v fmt -verify .

vet:
	v vet .

# Validates against the schema, not merely that the file is JSON: the same check as CI.
# Only testdata/golden/ holds run results. Other fixtures under testdata/ are inputs to
# specific tests and are not the output contract.
schema:
	@if ! ls testdata/golden/*.json >/dev/null 2>&1; then \
		echo "no golden JSON yet, skipping"; \
	elif ! command -v check-jsonschema >/dev/null 2>&1; then \
		echo "check-jsonschema not installed: pip install check-jsonschema"; exit 1; \
	else \
		check-jsonschema --schemafile schema/result.schema.json testdata/golden/*.json; \
	fi

check: fmt-check vet test schema
	@echo "all checks passed"

clean:
	rm -f $(BIN)
