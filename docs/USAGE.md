# Using dnsbench

This is the task-oriented guide: what to run for a given question, and how to read what comes
back. Two other references sit beside it:

- `dnsbench --help` lists every flag the binary you have actually accepts. When this guide and
  `--help` disagree, trust `--help`.
- The man page, [`packaging/dnsbench.1`](../packaging/dnsbench.1), is the complete flag
  reference: every option, exit status, environment variable and file. `make install` puts it
  where `man dnsbench` finds it; from a checkout, `man ./packaging/dnsbench.1` reads it
  directly.

The rest of `docs/` is the specification: what each probe measures and why
([METHODOLOGY.md](METHODOLOGY.md)), how the score is built ([SCORING.md](SCORING.md)), and
the output contract ([OUTPUT.md](OUTPUT.md)).

## Before the first run

**Tunnels.** A run refuses to start while a tunnel interface (a VPN, WireGuard, and the like)
is up, because every number would describe the tunnel rather than your link. `--force`
measures anyway and says so in the output.

**What leaves the machine.** The measurement itself, plus four DNS queries at startup that name
the network you are on and compare two independent answers to detect transparent DNS
interception. The public address is used for the ASN lookup and then discarded; the output
carries the ASN and operator name, never the address. `--no-geo` skips the four queries; the
ASN is then null and the region falls back to the time zone. Nothing else is
sent: no telemetry, no update check. `dnsbench update` is the only command that downloads
anything, and only when you run it.

**Local caches.** A local cache or the system's own resolver is measured and labelled apart
from the public resolvers. A 0.3 ms cache hit and a 15 ms network round trip are different
measurements in the same unit, so the cache is kept out of the latency ranking.

## Quick start

```sh
dnsbench                                  # every catalog provider, warm UDP lookups
dnsbench --only cloudflare,quad9-ecs      # a subset, by catalog key
dnsbench --profile streaming              # reweight: CDN edge dominates
dnsbench --format json > run.json         # machine-readable
dnsbench --tui --probes warm,ecs          # watch it happen, edge probe included
dnsbench --quick                          # lookup and edge, in the fewest rounds that rank
```

The default run is the `warm` probe only. The metric this tool exists for, the CDN edge
penalty, comes from the `ecs` probe, which is not in the default set. For a ranking that
reflects real use, add it:

```sh
dnsbench --probes warm,ecs,dot-warm,dnssec,filter
```

`--quick` is the short version: `warm` and `ecs` only, and the fewest rounds that still give
every provider the 30 samples a ranked result needs, which is one round when a regional domain
set is in play and two with the global set alone. It runs in a fraction of the default time.
The intervals behind the tiers are wider with fewer samples, so more providers share a rank.
It is a preset, so it refuses `--rounds` and `--probes`; give those instead to choose.

Catalog keys are the `key` fields in [`data/providers.toml`](../data/providers.toml), for
example `cloudflare`, `google`, `quad9`, `quad9-ecs`, `adguard`, `mullvad`, `nextdns`,
`opendns`. `--only` also takes the address of one of the machine's own resolvers.

## Choosing probes

`--probes` takes a comma-separated list. Each probe answers a different question:

- **`warm`**: repeated lookups of a fixed domain set, the everyday case. The ranking's
  latency is built on it.
- **`tcp`**: the same question over TCP, the path a truncated answer falls back to.
- **`cold`**: a random name nobody has asked for, so every query is a cache miss and the
  resolver has to recurse. Asks under the project's own zone unless `--cold-zone` names
  another, see below.
- **`ecs`**: resolves DNS-steered CDN hostnames through each resolver and times a TCP connect
  to whatever address came back. Reports the median penalty against the best edge any
  resolver reached in this run. This is the `EDGE` column.
- **`dot-fresh`**: DNS over TLS with a new connection per query, so it times connect,
  handshake and query together. It exists to show how much of "DoT is slow" is handshakes.
- **`dot-warm`**: DNS over TLS on one held connection, which is what a real stub resolver
  does. Only this DoT variant feeds the score.
- **`doh`**: DNS over HTTPS (RFC 8484). HTTP/1.1 in the default build; see
  [DoH over HTTP/2](#doh-over-http2).
- **`dnssec`**: asks a deliberately broken zone twice, with and without the Checking Disabled
  bit, and reads from the pair whether the resolver validates.
- **`filter`**: asks for an advertising domain and reads whether it was resolved or blocked.

A figure that was not measured prints as a dash and is emitted as `null`, never as zero,
because zero is the best value in every latency column.

Some useful combinations:

```sh
# is encrypted DNS actually slower, or is it the handshake?
dnsbench --probes warm,dot-fresh,dot-warm,doh

# which resolvers really validate DNSSEC and which block ads
dnsbench --probes warm,dnssec,filter

# recursion cost, cache misses only
dnsbench --probes warm,cold

# more samples per provider for a tighter interval (default 5 rounds)
dnsbench --probes warm,ecs --rounds 10
```

### The cold probe and its zone

`cold` asks for random labels under a wildcard zone, so every query is a cache miss without
sending NXDOMAIN traffic to a third party. By default it asks under
`probe.dnsbench.esli.blog`, which the project operates for exactly this:

- **Delegated** from `esli.blog` and hosted separately on Bunny DNS, so a mistake or a
  traffic spike in the probe zone never touches the parent.
- **DNSSEC-signed** (algorithm 13). A tool that scores DNSSEC validation cannot ship an
  unsigned reference zone.
- **Wildcard onto unroutable addresses**, `192.0.2.1` (TEST-NET-1) and `2001:db8::1`. The
  probe measures a lookup and must never turn into a connection test.
- **A 60-second TTL**, which is part of the measurement: every resolver caches the answer for
  the same time.
- **Not operated by any resolver in the catalog.** `cold` measures the hop from a resolver to
  the authoritative; an authoritative run by one of the resolvers under test would give that
  resolver an advantage no column would explain. That ruled out Cloudflare and DigitalOcean.
- **Anycast with a São Paulo point of presence**, so the zone adds a small, comparable
  distance instead of a constant large enough to flatten the comparison.

To depend on your own zone instead, publish a wildcard DNSSEC-signed record with a short TTL
and pass it with `--cold-zone`. [DATA.md § Cold-probe zone](DATA.md#cold-probe-zone) has the
exact records and the `kdig`/`delv` commands to verify a zone before trusting it.

## Weight profiles

`--profile` changes how the subscores are weighted, not what is measured:

- **`balanced`** (default): CDN edge carries the largest single weight.
- **`speed`**: lookup latency first, edge still high.
- **`privacy`**: declared privacy claims and encrypted transports dominate.
- **`streaming`**: edge is close to half the score.
- **`gaming`**: stability (p95, jitter) dominates.

The weights are printed in the header of every output format and travel in the JSON.
[SCORING.md](SCORING.md) has the exact numbers. In the TUI, `p` cycles profiles and re-ranks
what was already measured, which is the quickest way to see how much of an answer is the
network and how much is the weighting.

### Reading the ranking

- **Tiers and shared ranks**: providers whose confidence intervals on the score overlap share
  a rank and a tier. A 0.3-point difference is never presented as a winner.
- **`low_n`**: fewer than 30 samples on a scored probe; the row gets no tier. Raise
  `--rounds`.
- **`unreachable` vs. `refused`**: nothing came back, versus every answer carried an error
  rcode. A resolver that answers REFUSED has answered; it is not packet loss.
- **Measured vs. declared badges**: `+DNSSEC` or `-ads` were established by a probe in this
  run. `~nolog` is the operator's own claim, styled differently, and never contributes to a
  measured subscore.

## Filtering the catalog

```sh
dnsbench --require dnssec,nofilter        # only providers carrying these tags
dnsbench --probes warm,filter --require filtering   # only those measured to filter ads
```

Tags come from the closed vocabulary in [DATA.md § Schema](DATA.md#schema). `filtering` is
special: it is the measured verdict of the `filter` probe, so it needs that probe in the run.

### Your own resolvers

`~/.config/dnsbench/providers.toml` (or `$XDG_CONFIG_HOME/dnsbench/providers.toml`) uses the
same schema as the embedded catalog and is merged by key, ahead of every other catalog.
Adding a company resolver or a local unbound instance is one entry:

```toml
version = 3

[[provider]]
key      = "home-unbound"
label    = "Home unbound"
udp4     = ["192.168.1.2"]
tags     = ["dnssec"]
homepage = "https://nlnetlabs.nl/projects/unbound/"
```

`key`, `label`, at least one endpoint and `homepage` are required; the catalog loader rejects
an entry without them.

```sh
dnsbench --only home-unbound,quad9-ecs,cloudflare --probes warm,ecs,dnssec
```

### The optional DNSCrypt catalog

```sh
dnsbench update                                          # fetch and verify
dnsbench --catalog dnscrypt --require nolog,dnssec,nofilter
dnsbench --catalog dnscrypt --near                       # fastest 25 reachable only
```

`dnsbench update` fetches the DNSCrypt public-resolvers list, several hundred entries, and
verifies its minisign signature against a key built into the binary. Verification is
mandatory with no flag to skip it: a file that fails is discarded, the previous cache is kept,
and the exit status is 4. The download transport is not trusted and does not need to be.

The list is never the default. Its own header warns that it includes servers that censor, skip
DNSSEC validation, or collect and monetise queries, so rank it under `--require` tags rather
than crowning a winner from hundreds of arbitrary servers. Only DoH stamps become providers.
A key already in the embedded catalog is never replaced by the list's copy.

`--near` runs a paced TCP connect against every candidate and keeps the 25 fastest for the
full battery. `--only` bypasses it, since it is already an explicit list.

## Output formats

```sh
dnsbench --format table       # default, for humans
dnsbench --format json        # the stable, versioned contract
dnsbench --format csv
dnsbench --format markdown    # for pasting into an issue or a wiki
```

Only JSON carries a stability guarantee and validates against
[`schema/result.schema.json`](../schema/result.schema.json); do not parse the others.
[OUTPUT.md](OUTPUT.md) documents every field. The output never contains your public address,
so a result is safe to paste into a bug report.

## History

```sh
# append a run
dnsbench --probes warm,ecs --history ~/.local/share/dnsbench/runs.jsonl

# read it back, one row per network and provider
dnsbench history
dnsbench history --last 30d
dnsbench history --last 30d --asn AS27699

# sparkline of p50 over time for one provider
dnsbench history --provider nextdns --plot
```

`--history <path>` on a normal run appends one JSONL line per run; nothing is written unless
you name a file. `dnsbench history` reads `$XDG_DATA_HOME/dnsbench/runs.jsonl` (usually
`~/.local/share/dnsbench/runs.jsonl`) unless `--file` points elsewhere. Without `--plot` it
prints, per network and provider, the run count, the mean, min and max p50, and the latest
score. `--plot` needs `--provider`, because a sparkline is one series and one provider can
appear on several networks.

Runs from different networks, cold modes, domain sets or probes are never averaged together.
Every line carries the network fingerprint (`network.asn`, `network.ifname`), which is why a
fibre run and a mobile run on the same laptop stay apart.

## Watch mode

```sh
# measure every 15 minutes, keep the history
dnsbench --watch 15m --only quad9,cloudflare \
         --history ~/.local/share/dnsbench/runs.jsonl

# alert when a provider's median edge penalty goes over 50 ms
dnsbench --watch 5m --alert-edge 50 --only quad9 --probes warm,ecs

# four measurements, then exit, for scripts
dnsbench --watch 15m --watch-count 4
```

`--watch <dur>` repeats the run at a fixed interval: a positive integer followed by `s`, `m`,
`h`, `d` or `w`. Each tick prints and, with `--history`, appends exactly as a single run
would; run `dnsbench history --provider <key> --plot` in another terminal and the plot grows
with every tick. A failed tick is logged and the loop carries on, since a link having bad
moments is the reason to watch it.

Alerts go to stderr: the winning provider changing, checked every tick, and, with
`--alert-edge <ms>`, any provider's edge penalty crossing that line. Without `--watch-count`
the loop runs until interrupted. `--watch` and `--tui` are refused together.

## The terminal interface

```sh
dnsbench --tui --probes warm,cold,ecs,dot-warm,dnssec,filter
```

Every provider has a row from the first frame and the table fills in as results arrive. Keys:

- `↑` `↓` `k` `j` move, `PgUp` `PgDn` `Home` `End` scroll
- `s` cycles the sort column, `S` reverses it, `1` to `9` sort by the Nth visible column
- `Tab` switches which probe fills the `p50`, `p95`, `JIT` and `LOSS` columns
- `p` cycles the weight profile and re-ranks without measuring again
- `f` filters, `/` searches by name
- `Enter` opens the detail view, with the per-CDN-host edge table
- `e` exports json, csv or markdown to the working directory
- `r` re-runs, `a` aborts and keeps partial results
- `?` shows help and the run's warnings, `q` or `Esc` quits

`--no-color` or `NO_COLOR` gives plain text; `--palette colorblind` swaps green and red for
blue and orange. When `TERM` is unset or `dumb`, or output is not a terminal, `--tui` says so
and prints the plain table instead. [TUI.md](TUI.md) has the layout.

## Scripting and cron

When stderr is a terminal, a run shows one progress line there, queries done, elapsed and an
estimate of what is left, and erases it before printing the result. When stderr is a pipe or
a file, nothing is written to it, so cron and CI output is unchanged.

Ctrl+C stops a run and prints what it measured so far, marked as partial (`complete: false`
in JSON, `INTERRUPTED` in the table), with exit status 1. A partial run is not appended to
history. Interrupted during the discarded warm-up pass, there is nothing counted yet to print.
A second Ctrl+C exits at once. Under `--watch`, Ctrl+C also ends the wait between runs.

Exit statuses:

- `0`: run completed
- `1`: completed with errors, or interrupted, and partial results were emitted
- `2`: usage error
- `3`: no provider reachable, most likely no connectivity
- `4`: catalog verification failed on `dnsbench update`

The distinction that matters is 1 against 3: a job seeing 1 has numbers to look at; a job
seeing 3 has nothing and should not page anyone about DNS latency.

```sh
# nightly, appended to history, JSON on stdout for anything downstream
dnsbench --probes warm,ecs,dot-warm --format json \
         --history ~/.local/share/dnsbench/runs.jsonl > /dev/null
```

For a comparable series, keep the probe set, domain set and cold mode fixed. `--seed <n>`
fixes the query shuffle when a run has to be reproduced exactly.

## Other options

- `--timeout <ms>`: per-query timeout, default 2000 for plaintext probes; encrypted probes use
  5000, since a handshake costs two more round trips.
- `--region <code>`: `global`, `sa`, `na`, `eu`, `apac`, `af` or `me`, overriding detection.
  It picks the regional domain set merged into the pinned global one.
- `--ca-bundle <path>`: CA bundle for DoT and DoH, overriding the search through the usual
  system locations.
- `-V`, `--version`: the version and the commit the binary was built from.

## DoH over HTTP/2

The default build speaks DoH over HTTP/1.1 only, because V's standard library has no HTTP/2
client and the binary stays dependency-free. Every DoH result records `http_version`, since an
HTTP/1.1 measurement is not comparable to a browser's HTTP/2 behaviour. A provider that
refuses HTTP/1.1, such as Quad9 with a 505, shows as refused, never as unreachable.

To measure those providers, build with libcurl (`libcurl-devel` or the distribution's
equivalent):

```sh
make build CURL=1
```

## Troubleshooting

- **"tunnel interfaces are up"**: disconnect the VPN, or pass `--force` knowing the numbers
  describe the tunnel.
- **`cold` shows heavy loss or refusals on every provider**: the zone may be unreachable.
  Check it with `dig +dnssec x.probe.dnsbench.esli.blog`, or point `--cold-zone` at your
  own.
- **DoT or DoH all failing**: point `--ca-bundle` at the system bundle, for example
  `/etc/ssl/certs/ca-certificates.crt` or `/etc/pki/tls/certs/ca-bundle.crt`.
- **A provider shows `refused` on DoH**: it probably requires HTTP/2; see above.
- **Rows marked `low_n`**: raise `--rounds`.
- **"no answer to the first 5 queries, stopped waiting on it for the round"**: that provider
  and probe never answered, so the run stopped spending a full timeout on every query to it
  and tries it once per round instead. Usually a system resolver the link cannot reach; check
  it with `dig @<address> example.com`.
  [METHODOLOGY.md § Give up on silence](METHODOLOGY.md#give-up-on-silence) has the rule.
- **`dns_interception` set in the output**: two independent address queries disagreed, which
  means something on the path is rewriting DNS. The run still completes; every plaintext
  number is suspect.
