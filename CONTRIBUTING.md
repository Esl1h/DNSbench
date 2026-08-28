# Contributing

## Language

Everything in English: code, identifiers, comments, commit messages, issues, docs, and all
user-facing strings. No exceptions, including in tests and fixtures.

Number formatting is locale-independent (`.` decimal separator) everywhere.

## Code style

- `v fmt -w` before every commit. CI rejects unformatted code.
- `v vet` clean.
- No `panic()` outside `main`. Library code returns `!T` or `?T`.
- Comments explain **why**, not what. `// discard the first sample: it pays for the TLS
  handshake` is useful; `// loop over providers` is noise.
- Public functions in `core/` carry a doc comment stating what they measure and what they do
  not.

## Tests

```sh
v test .                        # unit
v run testdata/golden_check.v   # golden-file output comparison
```

Required for any change to measurement code:

1. **Wire codec** — byte-for-byte assertions against captured real responses in `testdata/`.
   Never against another implementation's output.
2. **Statistics** — the worked example in `docs/SCORING.md` is a test. If the code and the
   document disagree, one of them is a bug and CI says which.
3. **Output** — golden files for table, JSON and CSV. A diff in output is a deliberate change
   or a regression; the review decides which.
4. **Schema** — every golden JSON validates against `schema/result.schema.json`.

Integration tests run against a local mock authoritative server, never against public
resolvers. CI must not generate traffic to third-party infrastructure.

## Adding a provider

Pull request against `data/providers.toml` with:

- A public documentation URL for every endpoint listed.
- Tags only from the closed vocabulary in `docs/DATA.md`. Declared-only tags (`nolog`,
  `audited`, `nonprofit`) must cite a source in `notes`.
- One line in the PR description explaining the distinct trade-off it adds. "Another
  no-logging resolver" is not a trade-off.
- A CHANGELOG entry.

Endpoints are verified at review time. Stale entries are removed without ceremony.

## Changing the score

Any change to weights or subscore formulas requires:

1. An update to `docs/SCORING.md` **in the same commit**.
2. An updated worked example.
3. A before/after ranking on at least one real dataset in the PR description, so reviewers can
   see which providers move and why.

Score changes are semver-minor at minimum. Silent reweighting is not acceptable — users make
decisions based on this number.

## Methodology changes

Any change that alters what a probe measures requires a `docs/METHODOLOGY.md` update and a
`schema_version` review. If old results become incomparable to new ones, that must be stated
in the CHANGELOG and detected by `history`.

## Reporting a measurement bug

Include:

```sh
dnsbench --json > report.json      # redacts nothing; review before posting
```

plus your ASN, interface type (fibre / mobile / VPN) and whether any tunnel was active. A
latency report without the network fingerprint is unactionable.

## Security

Report vulnerabilities privately to the address in `SECURITY.md`. Relevant classes: catalog
verification bypass, TLS validation weakness, and anything that causes the tool to send more
traffic to third parties than documented.
