# Roadmap

## Milestones

### M0 — Core, no frontend (week 1)

- [ ] `core/wire.v` — encode/decode, EDNS0, unit tests against captured byte vectors
- [ ] `core/transport.v` — UDP, TCP
- [ ] `core/stats.v` — percentiles, jitter, loss
- [ ] `core/netinfo.v` — `/etc/resolv.conf`, `resolvectl`, gateway, interface, ASN
- [ ] `catalog/embedded.v` + `data/providers.toml`
- [ ] Golden-file tests

**Exit criterion:** `warm` and `cold` probes produce numbers matching `kdig` within noise on
the same link. If they do not, everything downstream is built on sand.

### M1 — CLI (week 2)

- [ ] `core/schedule.v` — interleaving, shuffling, rate limiting, SIGINT
- [ ] `core/score.v` + profiles
- [ ] `store/report.v` — table, JSON, CSV
- [ ] `store/jsonl.v` — history append
- [ ] Tiering via bootstrap CI
- [ ] Exit codes

**Exit criterion:** feature parity with the shell prototype, plus tiers, plus scoring, plus
parallelism.

### M2 — Encrypted transports + ECS (week 3)

- [ ] DoT via `net.ssl`, IP-literal dial with explicit SNI
- [ ] `dot-fresh` vs `dot-warm` split
- [ ] DoH over HTTP/1.1, version-labelled
- [ ] `probe.ecs` — resolve, TCP connect, penalty vs. run best
- [ ] CDN host health checks
- [ ] DNSSEC and filtering probes

**Exit criterion:** the ECS column reproduces the published regional finding — a no-ECS
resolver shows a large edge penalty on Akamai-backed hosts from a South American vantage
point.

### M3 — TUI (week 4)

- [x] `term.ui` frame loop, computed column layout, SIGWINCH
- [x] Live table fed from the run's own thread
- [x] Sorting, filtering, search
- [x] Detail view
- [x] Profile cycling with live re-rank, no re-measurement
- [x] Colour semantics, `NO_COLOR`, colourblind palette
- [x] Graceful fallback when `TERM` is unset or `dumb`, or the output is piped

### M4 — Distribution (week 5)

- [x] Static release binaries, linux/amd64 + arm64
- [x] AUR package, Fedora Copr: the `PKGBUILD` and the spec, in `packaging/`
- [x] `v install` / VPM: `v.mod` is the manifest; publication needs an account
- [x] man page, shell completions (bash, zsh, fish)
- [x] `dnsbench update` with minisign verification
- [x] Reproducible-build documentation: `docs/RELEASING.md`

The three items that need an account rather than code, the GitHub release, AUR
and Copr, are listed in `docs/RELEASING.md` § Steps that need an account so a
release is not reported as finished when it is not.

`update` fetches and verifies. Nothing reads the cache yet: the `sdns://` stamp
parser and `--catalog dnscrypt` are Layer 2 of `docs/DATA.md` and are the next
piece, not part of this milestone's line.

### M5 — Beyond

- [ ] Region-aware domain sets and RIR table generation at release
- [ ] `history` aggregation and sparklines
- [x] `--catalog dnscrypt`: the `sdns://` parser, three-layer precedence merge,
      `--require`
- [ ] `--near` prefilter for `--catalog dnscrypt`
- [ ] DNS interception / hijack detection as a first-class check
- [ ] `--watch` mode for continuous monitoring with threshold alerts

## Open decisions

| # | Decision | Options | Leaning |
|---|---|---|---|
| 1 | Project name | `dnsbench` collides with GRC's product | **Decided: keep `dnsbench`** |
| 2 | Cold-probe zone | Project-operated vs. user-supplied only | **Decided: operate `probe.dnsbench.esli.blog`**, configurable |
| 3 | DoH HTTP/2 | libcurl binding vs. stay on h1.1 and label it | Label it for v1; libcurl later |
| 4 | DoQ | Out of scope until V has QUIC | Out of scope, documented |
| 5 | Privacy weight in `balanced` | Include declared claims at all? | Keep at 0.05, styled distinctly |
| 6 | Windows / macOS | Linux-only for v1 | Linux-only; core is portable, `netinfo` is not |
| 7 | Telemetry | None | None. Not negotiable |
| 8 | TLS trust anchor | System CA bundle vs. embedded | **Decided: system store + `--ca-bundle`.** See ARCHITECTURE |
| 9 | Percentile method | Nearest-rank vs. interpolated | **Decided: nearest-rank.** See METHODOLOGY |
| 10 | ASN and region lookup | Embedded RIR table vs. DNS lookup vs. neither | **Decided: two DNS queries, `--no-geo` to skip.** See ARCHITECTURE |

Decision 1 is settled: the project keeps the name `dnsbench`. GRC's product is Windows-only,
unrelated in distribution channel, and the collision is a naming overlap rather than a conflict.
The binary, the module and `tool.name` in the JSON all use `dnsbench`.

## Non-goals

Stated explicitly so they do not creep in:

- **Changing the user's DNS configuration.** Measure and report. There are already tools that
  switch resolvers, and combining the two invites a benchmark that recommends itself.
- **Being a load tester.** `dnsperf` and `flamethrower` exist and are better at it. We are
  measuring a consumer link, at polite rates.
- **A GUI.** A two-minute benchmark that outputs a table does not need a window. If demand
  appears, the path is webview + a local `veb` server consuming the same core, not a
  hand-rolled widget toolkit.
- **Verifying privacy claims.** We cannot, so we do not, and we say so where it appears.
- **Recommending a resolver.** The tool ranks under a published, editable weighting. The
  choice is the user's.

## Success criteria for v1.0

1. A user on any continent runs one command and gets a ranked table that reflects their link.
2. The ECS column changes at least one user's mind about a resolver they thought was fastest.
3. Someone reproduces a published result from the JSON metadata alone, months later.
4. No user has to read the source to understand why a provider ranked where it did.
