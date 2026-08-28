# Methodology

Everything in this document exists because a naive implementation gets it wrong. Each rule
below is a bug we are pre-emptively fixing.

## The nine probes

| Probe | Transport | What it measures | In score |
|---|---|---|---|
| `warm` | UDP/53 | Cached lookup latency to the PoP | ✓ |
| `cold` | UDP/53 | Full recursion — the authoritative network | ✓ |
| `tcp` | TCP/53 | Fallback path, large-response handling | — |
| `dot-fresh` | DoT | New TCP+TLS handshake per query | — |
| `dot-warm` | DoT | Persistent connection, amortised handshake | ✓ |
| `doh` | DoH | HTTP request latency (version-labelled) | ✓ |
| `ecs` | UDP + TCP | **Latency to the CDN edge the resolver chose** | ✓ |
| `dnssec` | UDP/53 | Does it validate? (bad-signature domain → SERVFAIL) | ✓ (capability) |
| `filter` | UDP/53 | Does it block? (known ad domain → NXDOMAIN/0.0.0.0) | — (informational) |

Probes not in the score are still measured, reported and available in JSON. They inform; they
do not rank.

### warm

Fixed domain set, queried repeatedly. After the first pass every resolver has the record
cached, so this isolates network RTT to the PoP.

**A round is one pass over the whole set, not one query.** Sample count is therefore
`rounds x domains`, and the 30-sample floor below is a constraint on that product rather than
on the round count alone.

Discard the first pass per provider. It warms the resolver's cache and would penalise whoever
happens to be measured first. The whole pass goes, not its first query: every name in the set
needs warming, not just the one asked first.

### cold — forced recursion

Popular domains are cached by every resolver on Earth. To measure recursion you need a name
nobody has looked up.

**Do not use `<random>.google.com`.** It works, but it generates NXDOMAIN floods against
third-party infrastructure and measures the distance to *their* authoritative servers, which
varies per domain and pollutes the comparison.

Use a controlled wildcard zone with a low TTL:

```
*.probe.dnsbench.esli.blog.  60  IN  A  192.0.2.1
```

Every resolver then recurses to the **same** authoritative zone with the **same** TTL. Clean
comparison, no collateral damage.

One honest caveat: the reference zone is served by an anycast authoritative network, chosen for
reliability. Different resolvers therefore reach different PoPs of it, so `cold` measures
distance to the nearest instance of one authoritative network rather than to one machine. That
residual is small next to the cost of recursion itself, it is identical in kind for every
resolver in the run, and pretending otherwise would be the sort of unstated assumption this
document exists to prevent.

Modes:

| Mode | Behaviour | Trade-off |
|---|---|---|
| `own` (default) | Wildcard under the project zone | Controlled target; measures distance to one authoritative |
| `wild` | Random label under public domains | More representative of real authoritative diversity; noisier, impolite |
| `off` | Skip | For constrained networks |

The chosen mode is stamped into the output. Results from different modes are not comparable
and the tool refuses to merge them in `history`.

### dot-fresh vs dot-warm — the measurement that fixes the classic error

Most DNS benchmarks in circulation open a new TCP connection and a new TLS handshake for every
single query, then conclude that encrypted DNS is slow.

The tell is a **constant delta across all providers**. Observed on a real link:

| Provider | UDP p50 | DoT p50 (fresh) | Delta |
|---|---|---|---|
| A | 15.0 | 101.4 | +86 |
| B | 16.9 | 101.9 | +85 |
| C | 16.8 | 93.0 | +76 |

When the "problem" is identical for everyone, the problem is the method. That delta is
`SYN RTT + TLS 1.3 RTT + query RTT + endpoint hostname bootstrap`.

Real clients — Android Private DNS, `systemd-resolved`, `unbound` with
`forward-tls-upstream`, `dnscrypt-proxy` — hold the connection open. The handshake is paid
once per session.

So we measure both, and **only `dot-warm` feeds the score**:

- `dot-fresh` — connect, handshake, one query, close. Repeated.
- `dot-warm` — connect and handshake once, then N queries on the same connection, discarding
  the first.

The TUI shows both side by side, because the difference is itself the educational payload.

Additional rule: **connect by IP literal with explicit SNI/verification hostname.** Resolving
`dns.example.net` through the system resolver before every DoT query adds a variable lookup to
the measurement.

```v
// correct — dial the IP literal, then hand TLS the verification hostname
mut tcp := net.dial_tcp('9.9.9.11:853')!
mut tls := ssl.new_ssl_conn(validate: true, verify: ca_bundle_path)!
tls.connect(mut tcp, 'dns11.quad9.net')!

// wrong — resolves the hostname through the system resolver on every sample
mut tls := ssl.new_ssl_conn(validate: true, verify: ca_bundle_path)!
tls.dial('dns11.quad9.net', 853)!
```

Two constraints on that first form, both verified against a live resolver:

- `validate: true` without `verify:` always fails. V loads no system trust store, so the CA
  bundle path must be supplied. See ARCHITECTURE § TLS trust anchor.
- Hostname verification is genuinely enforced by `connect()`. Dialling `1.1.1.1:853` and
  passing an SNI of `dns.google` fails the handshake with `MBEDTLS_ERR_X509_CERT_VERIFY_FAILED`.
  Connecting by IP literal is therefore not a verification bypass.

### ecs — the probe that justifies the project

EDNS Client Subnet lets a resolver tell the authoritative server a prefix of your network,
typically a /24. With it, a CDN returns a nearby edge. Without it, the CDN only sees the
resolver, and guesses.

Published median latency to the Akamai edge in South America, by resolver:

| Resolver | IPv4 | IPv6 |
|---|---|---|
| Google | 9.86 ms | 10.26 ms |
| OpenDNS | 10.14 ms | 10.08 ms |
| Cloudflare | 14.86 ms | 15.21 ms |
| Quad9 | **108.38 ms** | **148.60 ms** |

That is not DNS latency. That is the latency of every connection you open **afterwards**, to
the address that resolver handed you. Winning by 2 ms on lookup and losing by 90 ms on the
edge is losing.

**Procedure**

1. For each CDN host in the set, resolve `A` through the provider under test.
2. Open a TCP connection to the returned address on 443 and record `time_connect`.
3. Repeat across all providers.
4. For each host, find the minimum connect time achieved by **any** provider in this run.
5. A provider's ECS penalty for that host is `its_connect_time − best_connect_time`.
6. Its `ecs_penalty` is the median penalty across hosts.

**The probe is self-calibrating.** The baseline comes from the run itself, not from
geolocation, not from an IP database, not from a country code. It is equally valid in São
Paulo, Lagos and Helsinki with zero geo code.

**Host selection.** Use globally distributed, many-PoP CDNs. This is correctness, not
convenience: a CDN with two PoPs cannot expose a bad ECS decision; one with hundreds can.
Akamai, Cloudflare, Fastly, Google and Netflix OpenConnect are the strongest ECS probes
anywhere on Earth. Regional CDNs are an optional realism supplement and never affect scoring.

**Confounders we control for**

- TCP connect only, never a full TLS handshake or HTTP request — we are measuring distance,
  not server behaviour.
- Same host, same port, same moment (interleaved), for all providers.
- Anycast CDN targets can shift mid-run; the interleaved schedule bounds this.
- If a host fails to resolve on a provider, that host is dropped for that provider and the
  count is reported. A provider that resolves fewer CDN hosts is flagged, not silently
  favoured.

### dnssec

Query a domain with a deliberately broken signature. `SERVFAIL` means the resolver validated
and rejected — correct behaviour. A successful answer means no validation.

This is a **capability**, not a latency measurement. It contributes a fixed component to the
score, and appears as a badge in the table.

### filter

Query a well-known advertising domain. `NXDOMAIN`, `0.0.0.0`, `::` or an empty answer means
blocking is active.

Deliberately **not scored**. Whether filtering is good depends entirely on what the user
wants, and a benchmark that quietly rewards blocking is expressing an opinion it has no
business expressing. Shown as a badge; usable as a filter (`--require filtering`).

## Fairness rules

These prevent systematic bias. Violating any one of them invalidates the ranking.

### 1. Interleave, never batch

Wrong:

```
provider A: all queries → provider B: all queries → provider C: ...
```

The first provider pays for cold upstream caches and an unwarmed local network path; the last
benefits from a network that has been in use for two minutes.

Right:

```
round 1: [A, C, B] shuffled → round 2: [B, A, C] shuffled → ...
```

Shuffle the provider order **per round**. Report the number of rounds.

### 2. Discard the first sample per (provider, probe)

It carries handshake, ARP, route setup, and cache-fill costs that no subsequent query pays.

### 3. Rate limit, and be a good citizen

Default: **maximum 10 queries per second per provider**, jittered. These are free public
services, many run by non-profits. A benchmark that hammers them is a benchmark that gets
its users rate-limited.

`--aggressive` exists, is documented as impolite, and prints a warning.

### 4. Report `n`, always

A provider returning 26 of 35 expected samples is not a rounding error — it is the finding.
Observed in the field: on a mobile network, one provider lost 17–43 % of TLS handshakes while
two others lost none. No global ranking would ever surface that.

`n`, `expected` and `loss` appear in every output format.

### 5. Fail loudly on interference

Before measuring, detect and warn:

| Condition | Detection | Action |
|---|---|---|
| VPN / tun interface up | `ip -o link` for `tun*`, `wg*`, `tailscale*` | Warn; you are measuring the tunnel |
| Android Private DNS | platform-specific | Warn |
| Local intercepting proxy | `resolv.conf` is loopback + unexpected process | Inform, label correctly |
| Transparent DNS hijack | `o-o.myaddr.l.google.com TXT @8.8.8.8` returns unexpected egress | Report prominently |

The last one is a security finding, not a measurement caveat.

### 6. Pin the dataset

Domain lists are shipped in the binary with a fixed Tranco list ID. They are **not** refreshed
per run. A moving dataset makes June's results incomparable with August's, which destroys the
history feature.

Every result carries `domains: "tranco:<ID>"`. Bumping the ID is a release decision with a
CHANGELOG entry.

## Statistics

### Metrics

| Metric | Definition | Why |
|---|---|---|
| `p50` | Median | Typical experience; robust to outliers |
| `p95` | 95th percentile | The tail users actually notice |
| `max` | Maximum | Worst observed |
| `jitter` | Sample standard deviation | Predictability |
| `loss` | `100 x failed / attempted`, a percentage in `[0, 100]` | Reliability |

**Mean is not reported as a headline.** It is available in JSON and nowhere else. A mean of
15 ms with a p95 of 68 ms is a worse experience than a mean of 22 ms with a p95 of 26 ms, and
means hide that.

### Percentile method

Nearest-rank over the ascending-sorted successful samples. For percentile `p` on `n` samples
the index is `ceil(p / 100 x n)`, 1-based, clamped to `[1, n]`.

No interpolation. Every percentile the tool prints is a value some query actually returned,
which keeps the output traceable to a real measurement and keeps the unit tests
hand-computable. On an even `n`, `p50` is therefore the lower of the two central samples and
not their average: `ceil(50 / 100 x n)` is exactly `n / 2`. This is stated because it is a
real choice: interpolated percentiles are smoother and are not reproducible by hand from the
JSON.

### Timeouts

| Probe | Timeout |
|---|---|
| `warm`, `cold`, `dnssec`, `filter` (UDP/53) | 2 s |
| `tcp` (TCP/53) | 2 s |
| `ecs` (TCP connect to the CDN host) | 2 s |
| `dot-fresh`, `dot-warm` | 5 s |
| `doh` | 5 s |

The encrypted budgets are larger because they cover a TCP handshake and a TLS handshake before
any DNS byte moves. A sample that exceeds its timeout is recorded as loss and never as a
latency value; see Outliers.

### Sample size

Minimum 30 samples per (provider, probe) for a ranked result. Below that, the row is shown
with a `low-n` marker and excluded from tier assignment.

With `n < 20`, "p95" is arithmetically close to the maximum and should not be presented as a
percentile. The tool reports `max` instead and says so.

### Outliers

No trimming, no winsorising. A 400 ms spike is not noise — it is the user's experience. p50
and p95 already handle the distribution correctly, and silently deleting bad samples is how
benchmarks become marketing.

The single exception: samples exceeding the timeout are recorded as **loss**, not as a
latency value, because their true value is unbounded.

### Nothing is not zero

When a probe collects no successful sample, it has no median, no percentile, no maximum, no
mean and no spread. Those are reported as absent, never as 0.

This is not presentation. 0 ms is the best latency on the page, so a resolver that answered
nothing would sort to the top of a table ordered by `p50`, and the `latency` subscore in
docs/SCORING.md is `100 x best_p50 / this_p50`, which would divide by it. `jitter` is worse
still: 0 reads as perfect stability, the most flattering value the column has.

The same holds for `jitter` at `n = 1`. The sample standard deviation is undefined for one
observation, and claiming perfect stability on the strength of a single measurement is the
opposite of what a single measurement supports.

`n`, `expected` and `loss` are always known and are always reported.

### Tiers — do not rank noise

Ranking provider #1 above #2 when the difference is 0.4 ms with 12 ms of jitter is fiction.

After scoring, group providers into tiers. Two providers are in the same tier when their
**composite score** confidence intervals overlap, using a bootstrap estimate over the collected
samples.

The interval is on the score and not on `p50`, because the score is what orders the table. A
band drawn from `p50` while the column beside it is sorted by score would be describing the
uncertainty of a different quantity from the one the reader is looking at.

Each bootstrap replicate resamples every provider's latency samples with replacement, at the
same `n`, and then recomputes **everything** downstream: the per-probe statistics, the run's
best figures, all eight subscores and the composite. Recomputing the bests inside the replicate
is the point of doing it this way: normalisation is relative to the run, so the reference point
is itself uncertain, and holding it fixed would understate every interval.

`ecs_penalty` is held constant within a replicate. It is a median of per-host connect times
rather than a sample of the same kind, and resampling it as if it were would be inventing a
distribution.

Tiers are assigned by walking the table from the top: a provider joins the current tier when
its interval overlaps that of the provider who **leads** the tier, and starts a new one when it
does not. Comparing against the leader rather than the previous row stops a long chain of
pairwise overlaps from collapsing a whole table into one band.

Same-tier providers share a rank number and are displayed with a shared tier band:

```
  1  ▍ nextdns             92
  1  ▍ cloudflare          91     ← same tier, statistically indistinguishable
  ─────────────────────────────
  3  ▍ google              78
```

This is rare in benchmark tools and is the single most honest thing this project does.
