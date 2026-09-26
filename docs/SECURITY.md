# Security policy

## Reporting

Report vulnerabilities privately through GitHub's private vulnerability reporting on this
repository: Security > Report a vulnerability. Do not open a public issue.

## In scope

- Catalog verification bypass (minisign signature not enforced, downgrade to unsigned)
- TLS validation weakness in the DoT or DoH clients
- Anything causing the tool to send more traffic to third parties than documented
- Path traversal or arbitrary write via config, catalog or dataset parsing

## Out of scope

- A provider in the catalog being untrustworthy. Tags are declared by providers; see
  `docs/DATA.md`.
- Latency results you disagree with. Open an issue with `--json` output attached.

## What leaves the machine

By design, only:

1. DNS queries to the resolvers under test.
2. TCP connects to CDN hosts for the edge probe (connect only — no TLS, no HTTP request).
3. One public-IP lookup over DNS, unless `--no-geo`.
4. Catalog fetches during an explicit `dnsbench update`.

No telemetry, no analytics, no crash reporting. Ever.

Note for users: measuring a resolver necessarily reveals your IP to that resolver. That is
inherent to the measurement, not a flaw.
