# dnsbench

**Rank DNS resolvers from your own connection — including the metric nobody else measures.**

Every public DNS ranking answers the question *"which resolver is fast, on average, as seen
from datacenters around the world?"* That is a fine question. It is not your question.

Your question is *"which resolver is fast from my link, on my ISP, right now — and does it
send me to the right CDN edge afterwards?"*

`dnsbench` answers that. It is a single static binary with a CLI and a TUI, no runtime
dependencies, no telemetry, and no network access during the measurement phase.

---

## Why another DNS benchmark

| Capability | GRC Bench | dnsdiag | dnspyre | Web tools | **dnsbench** |
|---|---|---|---|---|---|
| UDP / TCP | ✓ | ✓ | ✓ | ✗ | ✓ |
| DoT | ✗ | ✓ | ✓ | ✗ | ✓ |
| DoH | ✗ | ✓ | ✓ | ✓ (only) | ✓ |
| Forced cold cache | ✓ | ✗ | partial | ✗ | ✓ |
| p95 / jitter | ✓ | ✓ | ✓ | some | ✓ |
| Persistent vs. fresh handshake | ✗ | ✗ | ✓ | n/a | ✓ |
| **CDN edge latency (ECS quality)** | ✗ | ✗ | ✗ | ✗ | **✓** |
| Local / system resolver, correctly labelled | partial | ✗ | ✗ | ✗ | ✓ |
| Composite score with published weights | ✓ | ✗ | ✗ | some | ✓ |
| Reproducible, versioned datasets | ✗ | ✗ | ✗ | ✗ | ✓ |

The bold row is the whole point. A resolver that wins by 2 ms on lookup latency and loses by
90 ms on CDN edge selection has lost. No public tool measures that today.

## The three claims this project makes

1. **Lookup latency is the least important of the three things a resolver does for you.**
   Answer quality (which CDN edge you get) and stability (p95, jitter, loss) matter more.
2. **A benchmark that opens a new TLS connection per query is measuring handshakes, not
   resolvers.** We measure both and label them differently.
3. **A ranking whose dataset changes between runs is not a ranking.** Domain lists are pinned
   by ID, shipped in the binary, and stamped into every result.

## Install

```sh
# from source (V >= 0.5.2)
git clone https://github.com/Esl1h/DNSbench && cd DNSbench
v -prod -o dnsbench cmd/cli.v

# release binary
curl -LO https://github.com/Esl1h/DNSbench/releases/latest/download/dnsbench-linux-amd64
```

No libc-external dependencies. The binary embeds its provider catalog and domain sets.

## Use

```sh
dnsbench                          # measure, print ranked table
dnsbench --tui                    # interactive
dnsbench --json                   # machine-readable to stdout
dnsbench --profile privacy        # reweight the score
dnsbench --only nextdns,quad9-ecs,system
dnsbench update                   # refresh the optional DNSCrypt catalog
dnsbench history --last 30d       # aggregate past runs, grouped by network
```

Exit codes: `0` success, `1` measurement error, `2` bad usage, `3` no provider reachable.

## What it does not do

- It does not change your DNS settings. It measures and reports; you decide.
- It does not phone home. The only network traffic is the measurement itself, plus an
  explicit `dnsbench update`.
- It does not verify privacy claims. Flags like `nolog` come from the provider's own
  statements and are rendered in a visually distinct style. **Declared, not measured.**

## Documentation

| Document | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Module layout, data flow, concurrency model |
| [docs/METHODOLOGY.md](docs/METHODOLOGY.md) | What each probe measures and why; fairness rules |
| [docs/SCORING.md](docs/SCORING.md) | The composite score, weight profiles, tie handling |
| [docs/TUI.md](docs/TUI.md) | Screen layout, colour semantics, keybindings |
| [docs/DATA.md](docs/DATA.md) | Provider catalog and domain sets: sourcing and updating |
| [docs/OUTPUT.md](docs/OUTPUT.md) | JSON schema, JSONL history format, stability guarantees |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Milestones and open decisions |
| [docs/PLAN.md](docs/PLAN.md) | Development phases, settled decisions, verified V facts |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Adding providers, running tests, code style |

## Language policy

Everything ships in English: code, comments, identifiers, CLI output, TUI strings,
documentation, commit messages, issues. The tool is used from Bauru to Nairobi; English is
the lowest-friction common denominator, not a preference.

Numbers are formatted locale-independently (`.` decimal separator) so output can be piped
into anything without surprises.

## Licence

MIT.

## Prior art and credit

- **GRC DNS Benchmark** — Steve Gibson. The v2 rewrite's insight that v1 over-weighted cache
  performance shaped our warm/cold split.
- **dnsdiag** — Babak Farrokhi. `dnseval` is the closest existing tool; if you only need
  latency comparison, use it, it is more mature.
- **DNSCrypt public-resolvers** — Frank Denis. Optional catalog source, minisign-verified.
- **Tranco** — Le Pochat et al., NDSS 2019. Pinned, reproducible domain rankings.
- *Public DNS Resolvers Meet Content Delivery Networks* (arXiv:2502.05763) — the paper whose
  regional CDN-mapping numbers motivated the ECS probe.
