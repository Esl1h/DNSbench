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
#
# -gc none goes with it: V's default Boehm GC needs getcontext for stack
# scanning, and Ubuntu's musl-tools does not provide it for static linking,
# so a static build fails at the link step rather than the compile step.
# Dropping the GC is safe here specifically because dnsbench is a short-lived
# CLI process; the operating system reclaims everything at exit regardless.
STATIC  ?=
LINKAGE := $(if $(STATIC),-cc musl-gcc -cflags -static -gc none,)

# core/doh_h2_d_doh_h2.v, DoH over HTTP/2 through libcurl for the two
# providers that refuse HTTP/1.1 outright, is opt-in: CURL=1 adds -d doh_h2.
# Without it, core/doh_h2_stub_notd_doh_h2.v's stub is what's compiled in,
# and the binary keeps the zero-runtime-dependency guarantee unconditionally.
# Release builds do not set this, so the published binary never links curl.
CURL    ?=
DFLAGS  := $(if $(CURL),-d doh_h2,)

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
MANDIR  ?= $(PREFIX)/share/man/man1
DATADIR ?= $(PREFIX)/share

.PHONY: all build dev run test fmt fmt-check vet check schema release install uninstall clean

all: build

build:
	v $(VFLAGS) $(LINKAGE) $(DFLAGS) $(STAMP) -o $(BIN) $(SRC)

dev:
	v -g $(DFLAGS) $(STAMP) -o $(BIN) $(SRC)

run: dev
	./$(BIN)

test:
	v $(DFLAGS) test .

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
	v $(VFLAGS) $(LINKAGE) $(DFLAGS) $(STAMP) -o $(DIST)/stage/$(BIN)-$(VERSION)-$(TARGET)/$(BIN) $(SRC)
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
