# Architecture

## Design constraints

These are non-negotiable and every decision below follows from them.

1. **No network during measurement.** Catalog refresh, geo lookup, and dataset updates happen
   in a separate, explicit phase. A benchmark that downloads a domain list before measuring is
   benchmarking GitHub.
2. **Offline-first.** The binary is fully functional with no internet beyond the resolvers
   being tested. Everything it needs is embedded.
3. **The core knows nothing about frontends.** CLI and TUI are consumers. A third frontend
   must require zero core changes.
4. **Every result is self-describing.** Tool version, catalog version, domain set ID, network
   fingerprint and timestamp travel with the data. A result you cannot reproduce is an anecdote.
5. **Static binary.** No dynamic dependency beyond libc. This rules out `db.sqlite` on the
   default path (it requires `sqlite3.h` at build time).

## Module layout

```
dnsbench/
├── core/
│   ├── wire.v          DNS message encode/decode (RFC 1035), EDNS0 (RFC 6891)
│   ├── transport.v     udp, tcp, dot, doh — one interface, four implementations
│   ├── probe.v         the nine probe types; each returns []Sample
│   ├── schedule.v      interleaving, rate limiting, cancellation
│   ├── stats.v         p50/p95/max/jitter/loss, outlier policy
│   ├── score.v         composite score, weight profiles
│   ├── tier.v          bootstrap confidence intervals, tier and rank assignment
│   └── netinfo.v       system resolver discovery, network fingerprint, region
├── catalog/
│   ├── model.v         Provider struct, tag vocabulary
│   ├── embedded.v      $embed_file of data/providers.toml
│   ├── dnscrypt.v      sdns:// stamp parser + minisign verification
│   ├── userconf.v      $XDG_CONFIG_HOME override loading
│   └── merge.v         precedence resolution
├── store/
│   ├── jsonl.v         append-only run history
│   └── report.v        table / json / csv emitters
├── cmd/
│   ├── cli.v           flags, non-interactive output
│   └── tui.v           term.ui frontend
├── data/               embedded assets (see docs/DATA.md)
├── schema/             JSON Schema for the output contract
└── testdata/           golden files, captured DNS responses
```

## Data flow

```
                 ┌──────────────┐
                 │ catalog/     │  embedded.toml + optional dnscrypt cache
                 │  merge       │  + user overrides    → []Provider
                 └──────┬───────┘
                        │
  ┌──────────────┐      │      ┌──────────────┐
  │ core/netinfo │──────┼──────│ data/domains │  pinned sets, region-selected
  └──────┬───────┘      │      └──────┬───────┘
         │              │             │
         ▼              ▼             ▼
      ┌─────────────────────────────────────┐
      │            core/schedule            │  interleaved, rate-limited plan
      └──────────────────┬──────────────────┘
                         │  spawn N workers, one channel
                         ▼
      ┌─────────────────────────────────────┐
      │  core/probe → core/transport        │  the only code that touches the network
      └──────────────────┬──────────────────┘
                         │  []Sample
                         ▼
      ┌─────────────────────────────────────┐
      │        core/stats → core/score      │  Stats, Tier, Score
      └──────────────────┬──────────────────┘
                         │  RunResult
            ┌────────────┼────────────┐
            ▼            ▼            ▼
      store/report   store/jsonl   cmd/tui
      (table/json)   (history)     (live)
```

`cmd/tui` subscribes to the same channel the scheduler feeds, so the table fills in live
rather than appearing at the end. The CLI drains the channel silently and prints once.

## Concurrency model

V's `spawn` plus a single result channel. One goroutine per **provider**, not per query —
this keeps each provider's connection reuse honest and prevents one slow provider from
serialising the run.

```v
ch := chan ProbeResult{cap: providers.len * probes.len}
for p in providers {
    spawn worker(p, plan, ch)
}
```

Bounded by `--concurrency` (default: `min(providers.len, 8)`). Higher values saturate
consumer uplinks and corrupt the measurement — this is a benchmark, not a load test.

## Transport interface

```v
pub interface Transport {
    name() string                              // "udp" | "tcp" | "dot" | "doh"
mut:
    open(target Target) !                      // connect / handshake
    query(msg []u8) !([]u8, f64)               // wire bytes in, response + ms out
    close()
    reusable() bool                            // true if open() can be amortised
}
```

`reusable()` is what makes the warm/cold distinction possible without special-casing each
protocol in `probe.v`.

### Transport support matrix

| Transport | Status | Implementation |
|---|---|---|
| UDP/53 | ✅ | `net.dial_udp` |
| TCP/53 | ✅ | `net.dial_tcp`, 2-byte length prefix |
| DoT (853) | ✅ | `net.ssl.new_ssl_conn` + RFC 7858 framing |
| DoH (HTTP/1.1) | ⚠️ | Hand-written request over `net.ssl`; every result carries `http_version: "1.1"` |
| DoH (HTTP/2, /3) | ❌ | No h2/h3 client in V stdlib. Needs libcurl binding |
| DoQ | ❌ | No QUIC in V. Out of scope until one exists |

**This is documented, not hidden.** The output labels DoH results with the HTTP version used,
because comparing an h1.1 measurement against a browser's real h2 behaviour is misleading.

The limitation is not only cosmetic: some endpoints refuse HTTP/1.1 outright. Quad9 answers
`505 HTTP Version Not Supported` to every request, and Mullvad closes the connection without a
status. Both were confirmed with `curl --http1.1` against `curl --http2` on the same endpoint.
Those providers cannot be measured over DoH by this tool, and the run says so: the 505 is
recorded as `refused` with a warning naming the status, and never as loss.

`net.http` is not used, despite being the obvious choice. It resolves the URL's hostname
itself, which would put a lookup inside every latency sample and route that lookup through a
resolver that may be under test. The request is written by hand over a TLS connection dialled
to an IP literal, for the same reason DoT is.

## TLS trust anchor

V loads no system trust store of its own. `ssl.new_ssl_conn(validate: true)` with no `verify:`
path fails every handshake: mbedtls reports `MBEDTLS_ERR_SSL_CA_CHAIN_REQUIRED`, and the
OpenSSL backend reports `SSL_get_verify_result = 19`. The CA bundle path is therefore something
the tool must supply, and where it comes from is a decision, not a detail.

**We use the system trust store**, located at runtime, first match wins:

```
/etc/ssl/certs/ca-certificates.crt
/etc/pki/tls/certs/ca-bundle.crt
/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
/etc/ssl/cert.pem
--ca-bundle <path>                    overrides the cascade
```

We do **not** embed a CA bundle, despite the static-binary goal. Three reasons:

1. Static here means no dynamic dependency beyond libc, not zero filesystem reads. `netinfo`
   already reads `/etc/resolv.conf`, `ip route` and `resolvectl`, and is Linux-only by
   decision.
2. An embedded store keeps trusting a distrusted CA until the next release. That is a security
   regression the project would own, on a schedule it does not control.
3. The system store is the correct anchor: DoT verification then reflects the machine's actual
   trust posture rather than a parallel, invisible policy.

With no bundle found, DoT and DoH record `loss: 100` with the reason visible and the run
continues, per the failure policy below. The measurement degrades; it does not disappear, and
it never silently falls back to an unvalidated handshake. There is no `--insecure`.

## The system-resolver problem

The local resolver is not one target. It is up to three, and only some of them compete.

```
/etc/resolv.conf
├── 127.0.0.53   → systemd-resolved stub
│                   measure the stub (apps use it) AND the real upstream
│                   upstream via `resolvectl status` or DBus org.freedesktop.resolve1
├── 127.0.0.1    → local dnscrypt-proxy / unbound / dnsmasq
│                   same treatment
└── routable IP  → ISP or router resolver, competes normally

default gateway (`ip route`) → usually another valid resolver, probed separately
```

Rules enforced by `core/netinfo.v` and honoured by every frontend:

- A **cache** (`is_cache: true`) is excluded from the warm ranking. Comparing memory against
  network is the exact error GRC v1 made and v2 fixed.
- A cache **is** included in the cold ranking, where it acts as a pure forwarder and the
  comparison is valid.
- When both stub and upstream are known, the tool computes the delta and emits a diagnostic if
  the stub is materially worse than its own upstream. This detects the known
  `systemd-resolved` DoT PoP-selection bug (systemd#36383).
- Unidentifiable resolvers are labelled by IP. No invented names. PTR and ASN enrichment are
  opt-in and never on the measurement path.

## Region detection

Region affects **sample realism only**, never scoring correctness. The ECS probe is
self-calibrating (see METHODOLOGY) and needs no geography at all.

Cascade, first match wins:

```
1. --region <code>                        explicit flag
2. ~/.config/dnsbench/config.toml         persisted
3. public IP → RIR prefix table           embedded, offline, opt-out via --no-geo
4. TZ / LC_ALL heuristic                  offline fallback
5. "global"                               default
```

Step 3 obtains the public IP **over DNS**, not HTTP, because that is traffic the tool already
generates:

```
kdig +short myip.opendns.com @resolver1.opendns.com
kdig +short whoami.akamai.net @ns1-1.akamaitech.net
```

IP→region uses an embedded table derived from the five RIR `delegated-*-extended` files,
aggregated to prefix+country at release time. A few hundred KB, no GeoIP licence, no runtime
service.

Under a VPN this detects the exit node's region — **which is correct**. Your CDN mapping and
your realistic domain mix are those of the exit node, not of your timezone.

## Failure policy

| Condition | Behaviour |
|---|---|
| Provider unreachable | Record `loss: 100`, keep in output, exclude from ranking, show reason |
| Partial handshake loss | Record actual `n` and loss rate — **this is a finding**, not an error |
| Catalog fetch fails | Fall back to embedded, warn once, continue |
| Region detection fails | Fall back to `global`, continue silently |
| Interfering VPN/tun detected | Warn prominently before measuring; `--force` to proceed |
| SIGINT | Flush partial results with `complete: false`, exit 1 |

Nothing here aborts the run. A benchmark that dies on one bad provider is useless on the
networks where you most need it.
