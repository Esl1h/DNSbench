BIN     := dnsbench
SRC     := cmd/
VFLAGS  := -prod

# The version lives in v.mod and the commit in git; both reach the binary as
# compile-time defines. cmd/cli.v carries a working default for each, so a plain
# `v -o dnsbench cmd/` still builds outside a checkout.
VERSION := $(shell sed -n "s/^[[:space:]]*version:[[:space:]]*'\(.*\)'/\1/p" v.mod)
COMMIT  := $(shell git rev-parse --short=12 HEAD 2>/dev/null)
STAMP   := -d version=$(VERSION) $(if $(COMMIT),-d commit=$(COMMIT),)

DIST    := dist
TARGET  := linux-amd64

# Static linking is opt-in because it needs a static libc that a development
# machine has no reason to install. Release builds set STATIC=1.
STATIC  ?=
LINKAGE := $(if $(STATIC),-cc musl-gcc -cflags -static,)

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
MANDIR  ?= $(PREFIX)/share/man/man1
DATADIR ?= $(PREFIX)/share

.PHONY: all build dev run test fmt fmt-check vet check schema release install uninstall clean

all: build

build:
	v $(VFLAGS) $(LINKAGE) $(STAMP) -o $(BIN) $(SRC)

dev:
	v -g $(STAMP) -o $(BIN) $(SRC)

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

# A release artifact for the host architecture: stripped, stamped, and listed in
# a checksum file next to it. Cross-architecture builds need a cross toolchain
# and are cut by .github/workflows/release.yml; docs/RELEASING.md has the whole
# procedure and what makes it reproducible.
release: check
	@test -n "$(VERSION)" || { echo "no version in v.mod"; exit 1; }
	@test -n "$(COMMIT)" || { echo "not a git checkout: refusing to cut an unstamped release"; exit 1; }
	@git diff --quiet HEAD || { echo "working tree is dirty: commit or stash first"; exit 1; }
	rm -rf $(DIST)/stage
	mkdir -p $(DIST)/stage/$(BIN)-$(VERSION)-$(TARGET)/completions
	v $(VFLAGS) $(LINKAGE) $(STAMP) -o $(DIST)/stage/$(BIN)-$(VERSION)-$(TARGET)/$(BIN) $(SRC)
	strip $(DIST)/stage/$(BIN)-$(VERSION)-$(TARGET)/$(BIN)
	cp packaging/dnsbench.1 $(DIST)/stage/$(BIN)-$(VERSION)-$(TARGET)/
	cp packaging/completions/* $(DIST)/stage/$(BIN)-$(VERSION)-$(TARGET)/completions/
	cp LICENSE README.md CHANGELOG.md $(DIST)/stage/$(BIN)-$(VERSION)-$(TARGET)/
	cp $(DIST)/stage/$(BIN)-$(VERSION)-$(TARGET)/$(BIN) $(DIST)/$(BIN)-$(VERSION)-$(TARGET)
	tar -czf $(DIST)/$(BIN)-$(VERSION)-$(TARGET).tar.gz -C $(DIST)/stage $(BIN)-$(VERSION)-$(TARGET)
	rm -rf $(DIST)/stage
	cd $(DIST) && sha256sum $(BIN)-$(VERSION)-$(TARGET) $(BIN)-$(VERSION)-$(TARGET).tar.gz > SHA256SUMS-$(TARGET)
	@echo "cut $(DIST)/$(BIN)-$(VERSION)-$(TARGET) from $(COMMIT)"

install: build
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)
	install -Dm644 packaging/dnsbench.1 $(DESTDIR)$(MANDIR)/dnsbench.1
	install -Dm644 packaging/completions/dnsbench.bash $(DESTDIR)$(DATADIR)/bash-completion/completions/dnsbench
	install -Dm644 packaging/completions/dnsbench.zsh $(DESTDIR)$(DATADIR)/zsh/site-functions/_dnsbench
	install -Dm644 packaging/completions/dnsbench.fish $(DESTDIR)$(DATADIR)/fish/vendor_completions.d/dnsbench.fish

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(BIN)
	rm -f $(DESTDIR)$(MANDIR)/dnsbench.1
	rm -f $(DESTDIR)$(DATADIR)/bash-completion/completions/dnsbench
	rm -f $(DESTDIR)$(DATADIR)/zsh/site-functions/_dnsbench
	rm -f $(DESTDIR)$(DATADIR)/fish/vendor_completions.d/dnsbench.fish

clean:
	rm -f $(BIN)
	rm -rf $(DIST)
