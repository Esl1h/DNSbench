# dnsbench

**Rank DNS resolvers from your own connection, including the metric nobody else measures.**

Every public DNS ranking answers the question *"which resolver is fast, on average, as seen
from datacenters around the world?"* That is a fine question. It is not your question.

Your question is *"which resolver is fast from my link, on my ISP, right now, and does it send
me to the right CDN edge afterwards?"*

`dnsbench` answers that. It is a single static binary with no runtime dependencies, no
telemetry, and no network access beyond the measurement itself. A CLI today, a TUI next to it
when M3 lands.

## Status

Pre-release, and the gap between what is specified and what is built is wide enough to state
up front. The documents in `docs/` are the specification and were written before any code;
they describe the finished tool, not the current binary.

**Working today.** UDP and TCP transports. The `warm`, `cold` and `tcp` probes. The composite
score with five weight profiles, run-relative normalisation, and tiers from a bootstrap
interval on the score. Table, JSON, CSV and Markdown output against a versioned schema.
Append-only JSONL history. Local caches and system resolvers measured and labelled apart.

**Not built yet.** DoT and DoH, so `--probes` accepts three names and not six. The ECS edge
probe, which is the headline claim below and lands in M2. The DNSSEC and filtering probes.
The TUI: `docs/TUI.md` specifies it in full and no code implements it, so there is no `--tui`
flag. The `history` and `update` subcommands. ASN and region detection, which is why every
run reports `region: global`. The pinned Tranco domain set, for which eight names stand in
under the honest label `builtin:top8`.

`docs/PLAN.md` has the state of every module and what each remaining phase involves.
`docs/ROADMAP.md` has the milestones.

## Why another DNS benchmark

| Capability | GRC Bench | dnsdiag | dnspyre | Web tools | dnsbench |
|---|---|---|---|---|---|
| UDP / TCP | yes | yes | yes | no | **shipped** |
| DoT | no | yes | yes | no | M2 |
| DoH | no | yes | yes | yes, only | M2 |
| Forced cold cache | yes | no | partial | no | **shipped** |
| p95 / jitter | yes | yes | yes | some | **shipped** |
| Persistent vs. fresh handshake | no | no | yes | n/a | M2 |
| **CDN edge latency (ECS quality)** | no | no | no | no | **M2** |
| Local / system resolver, correctly labelled | partial | no | no | no | **shipped** |
| Composite score with published weights | yes | no | no | some | **shipped** |
| Reproducible, versioned datasets | no | no | no | no | **shipped** |

The bold row is the whole point, and it is also the row that is not built yet. A resolver that
wins by 2 ms on lookup latency and loses by 90 ms on CDN edge selection has lost. No public
tool measures that today, which is the reason this project exists rather than a patch to one
of the others.

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
make build
```

Release binaries and packages are M4. The binary embeds its provider catalog and domain sets
and links nothing outside libc.

## Use

```sh
dnsbench                                  # measure, print the ranked table
dnsbench --format json                    # machine-readable to stdout
dnsbench --profile privacy                # reweight the score, no re-measurement needed
dnsbench --only cloudflare,quad9-ecs      # a subset, by catalog key
dnsbench --probes warm,tcp                # pick the probes
dnsbench --history ~/.local/share/dnsbench/runs.jsonl
```

`dnsbench --help` lists every flag the binary actually accepts, which is the list to trust.

A run refuses to start when a tunnel interface is up, because it would be measuring the tunnel
and not the link. `--force` overrides it and says so in the output.

### The cold probe

`--probes cold` asks for a name nobody has ever asked for, so every query is a cache miss by
construction and the resolver has to recurse. It needs a wildcard zone to ask against:

```sh
dnsbench --probes warm,cold --cold-zone probe.dnsbench.esli.blog
```

That zone is operated by this project: delegated, DNSSEC-signed, wildcard onto RFC-reserved
addresses that nothing can connect to. It is deliberately not hosted by any resolver in the
catalog, because `cold` measures the hop from a resolver to the authoritative and an
authoritative run by one of the resolvers under test would hand that resolver an advantage no
column would explain. `docs/DATA.md` has the reasoning, the records, and the verification
commands for pointing the flag at your own zone instead.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Run completed |
| 1 | Run completed with errors, or interrupted, with partial results emitted |
| 2 | Usage error |
| 3 | No provider reachable, likely no connectivity |
| 4 | Catalog verification failure on `update` |

Suitable for cron and CI. The distinction that matters is between 1 and 3: a job seeing 1 has
numbers to look at, and a job seeing 3 has nothing and should not page anyone about DNS
latency.

## What it does not do

- It does not change your DNS settings. It measures and reports; you decide.
- It does not phone home. The only network traffic is the measurement itself, plus an
  explicit `dnsbench update` once that exists.
- It does not verify privacy claims. Flags like `nolog` come from the provider's own
  statements and are rendered in a visually distinct style. **Declared, not measured**, and
  enforced by the type system rather than by convention.
- It does not count a refusal as a dropped packet. A resolver that answers REFUSED has
  answered, and saying otherwise blames the network for a decision the operator made.

## Documentation

The documents are the specification. Where the code and a document disagree, the code is the
bug.

| Document | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Module layout, data flow, concurrency model |
| [docs/METHODOLOGY.md](docs/METHODOLOGY.md) | What each probe measures and why; fairness rules |
| [docs/SCORING.md](docs/SCORING.md) | The composite score, weight profiles, tie handling |
| [docs/TUI.md](docs/TUI.md) | Screen layout, colour semantics, keybindings |
| [docs/DATA.md](docs/DATA.md) | Provider catalog, domain sets, and the cold-probe zone |
| [docs/OUTPUT.md](docs/OUTPUT.md) | JSON schema, JSONL history format, stability guarantees |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Milestones and open decisions |
| [docs/PLAN.md](docs/PLAN.md) | Development phases, settled decisions, verified V facts |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Adding providers, running tests, code style |

## Language policy

Everything ships in English: code, comments, identifiers, CLI output, TUI strings,
documentation, commit messages, issues. The tool is used from Bauru to Nairobi; English is
the lowest-friction common denominator, not a preference.

Numbers are formatted locale-independently, with `.` as the decimal separator, so output can
be piped into anything without surprises.

## Licence

MIT.

## Prior art and credit

- **GRC DNS Benchmark**, Steve Gibson. The v2 rewrite's insight that v1 over-weighted cache
  performance shaped our warm and cold split.
- **dnsdiag**, Babak Farrokhi. `dnseval` is the closest existing tool; if you only need
  latency comparison today, use it, it is more mature.
- **DNSCrypt public-resolvers**, Frank Denis. Optional catalog source, minisign-verified.
- **Tranco**, Le Pochat et al., NDSS 2019. Pinned, reproducible domain rankings.
- *Public DNS Resolvers Meet Content Delivery Networks* (arXiv:2502.05763), the paper whose
  regional CDN-mapping numbers motivated the ECS probe.
