# Development plan

The phase plan, the decisions already settled, and the facts verified against a compiler
before any code existed. `.bootstrap/` held the material this was derived from and is deleted
at the end of M0; nothing here may depend on it.

Companion documents: `docs/CHECKLIST.md` is the day-one ordering, `docs/ROADMAP.md` is the
milestone list, `docs/V-NOTES.md` is the verified V stdlib reference. This file is the bridge
between them.

## Working discipline

One milestone per session. `/clear` between them, then re-anchor on the documents rather than
on the conversation, because the documents are the memory and the conversation is not.

Every session opens by reading `CLAUDE.md`, this file and `docs/V-NOTES.md`, and states its
scope before writing anything. Scope creep across milestone boundaries is the
failure mode this structure exists to prevent.

Compile after every ~30 lines. `v -o /tmp/x .` is not optional, it is the only thing standing
between plausible V and V that runs.

## Settled decisions

| # | Decision | Outcome |
|---|---|---|
| 1 | Project name | `dnsbench`. GRC's product is Windows-only and unrelated in distribution |
| 2 | Cold-probe zone | `probe.dnsbench.esli.blog`, delegated to Bunny DNS, neutral and anycast, DNSSEC-signed |
| 8 | TLS trust anchor | System CA bundle located at runtime, `--ca-bundle` override, never embedded |
| 9 | Percentile method | Nearest-rank, no interpolation |
| 10 | Probe timeouts | 2 s plaintext, 5 s encrypted |
| 11 | Absent figures | `null`, never 0, for every latency figure and every subscore |
| 12 | Tier intervals | Bootstrap on the **composite score**, not on `p50` |
| 13 | ASN and region | Three DNS queries at startup, `--no-geo` to skip. No embedded RIR table |

Decisions 2, 8, 9 and 10 exist because they were undefined and every one of them silently
changes a number the tool prints.

Decisions 11 and 12 are different: they resolved documents that contradicted each other.
`METHODOLOGY.md` put the tier interval on `p50` while `SCORING.md` put it on the composite
score; the score is what orders the table, so a band drawn from `p50` would describe the
uncertainty of a different quantity from the one being read. And a `p50` of 0 for a resolver
that answered nothing is the best latency on the page, so it sorted first and the `latency`
subscore, `best_p50 / this_p50`, divided by it. Both are written into the specifications now.

The reasoning for each lives with the decision it belongs to, in `docs/ROADMAP.md`,
`docs/ARCHITECTURE.md`, `docs/METHODOLOGY.md` and `docs/SCORING.md`.

The cold-probe zone sits under `esli.blog`, the same domain that serves the write-up, which
keeps the tool and the article legible as one thing. It is **delegated** to nameservers that
belong to no resolver in the catalog, and that is a fairness requirement rather than operational
hygiene: `cold` measures the hop from a resolver to the authoritative, so an authoritative
operated by one of the resolvers under test hands that resolver an advantage no column would
explain. Blast radius is the second reason and the smaller one. The host is Bunny DNS, chosen
on measured latency, DNSSEC support and unmetered queries; the comparison and the two caveats
that come with it are in DATA § Where the zone is hosted is a fairness question and § The
operator, and how it was chosen.

## Where this stands

Phases 0 to 6 are done, which is M0 through M4. Every probe the milestone list names exists
and both frontends are built. `make check` is clean: `v fmt -verify`, `v vet`, fifteen test
files, and the golden run result validating against `schema/result.schema.json`.

| Module | What it does |
|---|---|
| `core/wire.v` | RFC 1035 encode and decode, EDNS0, compression pointers with a real cycle guard. `a_addresses` and `cname_targets` for the probes that read an answer's shape |
| `core/stats.v` | Percentiles by nearest rank, jitter, loss, refusals. Absent figures are absent, never 0 |
| `core/transport.v` | The `Transport` interface, UDP and TCP, plus `connect_ms` for the edge probe |
| `core/tls.v` | DoT per RFC 7858, the CA bundle cascade, and `dial_tls`, which both encrypted transports go through |
| `core/doh.v` | DoH per RFC 8484, HTTP/1.1 written by hand over TLS |
| `core/edge.v` | The ECS probe's arithmetic: per-host penalties against the run's own floor, the median, the misrouted count |
| `core/capability.v` | The `dnssec` verdict with its CD control, the `filter` reading, majority over repeated readings |
| `core/netinfo.v` | Resolvers, gateway, cache marking, tunnel detection, IPv6 availability |
| `core/fetch.v` | One HTTPS GET over a connection this tool verifies itself, because V's `net.http` verifies nothing |
| `core/geo.v` | The region cascade: public address over DNS, the ASN announcing it, its operator, the country to domain-set map, the timezone fallback |
| `core/schedule.v` | Interleaved rounds, per-round shuffle, discarded warm-up pass, 10 qps pacing, per-provider probe lists |
| `core/score.v` | The eight subscores, the five profiles, run-relative normalisation, five exclusion reasons |
| `core/tier.v` | Bootstrap intervals on the composite score, tier and rank assignment |
| `catalog/` | The embedded catalog, measured and declared tags held apart by the type, CDN hosts, DoT and DoH endpoints |
| `catalog/minisign.v` | minisign verification, both the file signature and the one over the trusted comment |
| `catalog/dnscrypt.v` | Where the optional catalog is fetched from and the key it is verified against |
| `store/report.v` | JSON, CSV, table, markdown, exit codes |
| `store/jsonl.v` | Append-only history with the network fingerprint on every line |
| `cmd/cli.v` | All of the above, wired, plus the `Watcher` a frontend follows a run with |
| `cmd/tui.v` | The `term.ui` frame loop, the keys, the drawing, and the palette |
| `cmd/tui_view.v` | What the frontend draws: which columns fit, what each cell says, what tone it earned, how the rows are ordered and filtered |

A full run today:

```sh
make build
./dnsbench --probes warm,cold,ecs,dot-fresh,dot-warm,doh,dnssec,filter \
           --cold-zone probe.dnsbench.esli.blog
```

`--force` is needed wherever a tunnel interface is up. Without it the run refuses and says why,
per METHODOLOGY § Fail loudly on interference.

### What the probes found, and what that cost

Worth keeping, because each of these was a bug or a specification gap that a number alone would
have hidden.

`cold` is live against the project's own zone. Cloudflare came sixth on it, which is the
evidence that hosting on Bunny DNS gave no resolver in the catalog a home-field advantage.

`ecs` reproduces the published regional finding: Control D and DNS4EU pay more than 200 ms on
Akamai and Fastly from São Paulo and nothing on the anycast hosts. Its first host set was half
anycast, which cannot express an ECS decision at all, and the median flipped between 192 ms and
1.4 ms across runs. Nine DNS-steered hosts across four CDN families fixed it, and the misrouted
count is published beside the median because the count does not flip.

`dot-fresh` against `dot-warm` is 4x to 12x on every provider measured. That gap is the reason
both exist.

`doh` cannot measure Quad9 or Mullvad: both serve DoH over HTTP/2 only, confirmed with
`curl --http1.1` against `curl --http2`, and V has no h2 client. The 505 is recorded as
`refused` with a warning, never as loss.

`dnssec` needs its CD control and three readings. Quad9's `9.9.9.10`, documented by its
operator as not validating, validates. AdGuard's fleet answers inconsistently enough that a
single reading is a coin flip, so it reports unknown rather than guessing.

`filter` probes `ads` only. The obvious test names all failed: `ads.doubleclick.net` is
NXDOMAIN even on resolvers that filter nothing, and the OpenDNS test domains resolve to the
same block page from every resolver.

### Outstanding, smaller than a phase

- **`dnsbench history`.** `store/jsonl.v` writes the file and the comparability rule is tested,
  but no subcommand reads it back and aggregates.
- **Concurrency.** ARCHITECTURE specifies one worker per provider; `cmd/cli.v` walks the plan in
  order. The reasoning for the departure is at the top of that file: the plan is already
  interleaved, so walking it in order measures every provider under the same conditions in turn,
  where concurrent workers would have them contending for the link they are measuring. Now that
  DoT and DoH pay a handshake, a full eight-probe run takes minutes, so this is worth
  revisiting: the handshakes are the part where waiting is not measuring.
- **Pacing outside the plan.** `measure_edge` and `measure_capabilities` walk their own passes
  and do not go through the `Pacer`. Few queries each, but the run's own politeness rule does
  not currently cover them.
- **The domain set.** `cmd/cli.v` ships eight names as `builtin:top8`, labelled honestly as not
  being the pinned Tranco set. Generating the real one is a release task; see DATA § Tranco.
- **The regional domain sets.** ASN, operator and region are detected now and travel in the
  output, but `region` does not yet choose a domain list: DATA § Domain sets describes seven
  files and the binary embeds none of them. Step 2 of the cascade, the config file, is also
  still missing, because there is no config file.
- **The cold-probe zone.** Live. `probe.dnsbench.esli.blog` is delegated to Bunny DNS, signed
  with algorithm 13, and answers a fresh random label with `192.0.2.1` at a TTL of 60. `delv`
  validates it from the root. Pointing `--cold-zone` at your own zone is still supported; DATA
  § Setting the zone up has the records and the verification commands.
- **`--require`.** METHODOLOGY § filter says the filtering verdict is usable as a filter,
  `--require filtering`. Nothing implements the flag.

### What the TUI cost, and what it changed underneath

The frame loop was the smaller half. Three things in the layer below had to change, and each
was a bug the CLI had been hiding.

**Loss had no live denominator.** `assemble` divided by the run's full expected count, so a
run watched while it happened showed every provider at a hundred per cent loss falling
steadily towards the truth. Attempts are now counted at dispatch, per provider and per probe,
which is also more honest for an interrupted run: it divides by what was sent rather than by
what was planned. At the end of a complete run the two numbers are identical, so no published
figure moved.

**A frontend could not re-rank.** `p` re-ranks under a different weight profile without
measuring again, which needs the samples and not the table. `build_samples` came out of
`assemble` so both callers share it, and the samples travel with every snapshot.

**`term.ui` panics rather than erroring when there is no TTY**, and its default signal list
would have reinstalled the SIGPIPE handler that M2 removed to keep an idle DoT connection from
killing the run. Both are handled at the call site and recorded in `docs/V-NOTES.md`.

Two deviations from `docs/TUI.md` as written, both now in the document. Rows with nothing
measured yet carry a dash rather than the `····` the mock showed, because the dash is what
every other output format in this tool prints for an absent figure. And the export menu has no
clipboard entry: reaching one would mean shelling out to a program that may not be installed,
and the binary is dependency-free by design.

### What M4 found

**CI had been red since the TUI landed.** The workflow ran `v -prod -o dnsbench cmd/cli.v`,
which compiles one file; the Makefile had moved to `cmd/` and the workflow had not. Every step
now calls a Makefile target so the two cannot drift again.

**Reproducibility has a third requirement nobody writes down.** Pinning the compiler and
stamping the version as a define were expected. The third is the build path:
`$embed_file` records the absolute path of the file it embedded, so the same source built in
two directories produces two binaries differing by one unused string. `docs/RELEASING.md` fixes
the path at `/build/dnsbench` for that reason.

**V's `net.http` validates nothing.** Expired, self-signed and wrong-host certificates all
return 200. `core/fetch.v` exists because of it, going through the same `dial_tls` the DoT and
DoH probes use. On this path the minisign signature is the integrity control regardless, but
shipping a client that accepts any certificate would have been a defect introduced knowingly.

### Next: the optional catalog, Layer 2

`dnsbench update` fetches and verifies the DNSCrypt list and nothing reads the cache. What is
missing is the `sdns://` stamp parser, `catalog/merge.v`, `catalog/userconf.v` and the
`--catalog dnscrypt`, `--require` and `--near` flags of `docs/DATA.md` § Layer 2. `--near`
matters at that scale: probing four hundred resolvers fully is slow and impolite.

## Phases

### Phase 0: foundation, no V code

Move the specification out of `.bootstrap/` into permanent locations, correct what the
compiler contradicted, add `LICENSE`. First commit is specification only, before any code, so
that later disagreements between code and spec have a dated baseline to point at.

Verification: `git status` shows nothing from `.bootstrap/`; the schema still parses; the
golden-file paths are no longer swallowed by `.gitignore`.

### Phase 1: M0 session 1, `wire` and `stats`

`core/wire.v`, RFC 1035 encode and decode plus EDNS0 per RFC 6891. Name encoding validates
label length and total length; name decoding follows compression pointers and **refuses
pointer loops**, because a malformed response must not be able to hang the parser.

```v
pub struct Header { id u16  qr bool  opcode u8  aa bool  tc bool  rd bool
                    ra bool  ad bool  cd bool  rcode u8
                    qdcount u16  ancount u16  nscount u16  arcount u16 }
pub struct Question { name string  qtype u16  qclass u16 }
pub struct ResourceRecord { name string  rtype u16  rclass u16  ttl u32  rdata []u8 }
pub struct Response { header Header  question []Question
                      answer []ResourceRecord  authority []ResourceRecord
                      additional []ResourceRecord }

pub struct QueryOpts { id u16  rd bool = true  dnssec_ok bool
                       udp_payload_size u16 = 1232 }

pub fn build_query(name string, qtype u16) ![]u8
pub fn build_query_opts(name string, qtype u16, opts QueryOpts) ![]u8
pub fn parse_response(buf []u8) !Response
pub fn rcode(buf []u8) u8
```

`core/stats.v`:

```v
pub struct Stats { n int  expected int  loss f64
                   p50 ?f64  p95 ?f64  max ?f64  mean ?f64  jitter ?f64 }

pub fn compute(latencies_ms []f64, expected int) Stats
pub fn percentile(sorted_ms []f64, p f64) ?f64
```

The latency fields are optional and absent when there was no sample to derive them from,
never 0. See METHODOLOGY § Nothing is not zero.

`compute` takes only the successful samples plus the expected total, so a timeout can never be
recorded as a latency value by construction rather than by care. No trimming. `jitter` is the
sample standard deviation with an `n-1` denominator. `mean` exists in the struct and reaches
JSON only, never a human-facing format.

Tests: `wire_test.v` asserts against captured bytes, `stats_test.v` against hand-computed
values that a reader can check with a calculator.

Exit: `v test .` green, `v -o /tmp/x .` clean, `docs/V-NOTES.md` written and committed.

### Phase 2: M0 session 2, `transport`, `netinfo`, `catalog`

`core/transport.v` implementing the interface in `docs/ARCHITECTURE.md`, UDP first, then TCP
with its 2-byte length prefix. `core/netinfo.v` reading `/etc/resolv.conf`, `resolvectl
status`, `ip route` and `ip -o link`, producing the stub / upstream / gateway classification
and the `is_cache` marking. `catalog/model.v` and `catalog/embedded.v` with `$embed_file` and
validation against the closed tag vocabulary. A throwaway `main` that queries one resolver and
prints a latency.

Tests: transports against a local mock authoritative server, never a public resolver; the
`resolv.conf` and `resolvectl` parsers against fixtures in `testdata/`; the catalog loader
against a file carrying a tag outside the vocabulary.

Exit, and the only criterion that matters in this phase: `warm` p50 within noise of `kdig` on
the same link against the same target, both numbers shown. Everything downstream is built on
this number being right.

### Phase 3: M1, the CLI

`core/schedule.v` (interleaved rounds, per-round shuffling, 10 qps per provider with jitter,
first sample per provider-probe pair discarded, SIGINT flushing partial results with
`complete: false`), `core/score.v` with the five profiles, `store/report.v` for table, JSON,
CSV and markdown, `store/jsonl.v` with the mandatory network fingerprint per line, tiering by
bootstrap CI, exit codes.

Tests: the worked example in `docs/SCORING.md` is a unit test and must produce 87.3; golden
files for each output format; every golden JSON validates against the schema; the scheduler is
tested with an injected clock and no network; `history` refuses to aggregate across
`cold_mode` or incompatible `domains` IDs.

### Phase 4: M2, encrypted transports and ECS

The next one, and the one the project exists for. Four pieces:

1. **DoT.** The three-step form is verified and recorded in V-NOTES: dial the IP literal as
   TCP, then hand the verification hostname to `SSLConn.connect`. Split into `dot-fresh` and
   `dot-warm`; only `dot-warm` feeds the score. The CA bundle question is already settled, see
   decision 8.
2. **DoH** over HTTP/1.1, carrying `http_version: "1.1"` in the output, because an h1.1
   measurement is not comparable to a browser's real h2 behaviour.
3. **`probe.ecs`.** Resolve each CDN host through each provider, TCP-connect to the answer on
   443, take the penalty against the run's own best. This is what makes `edge`, the largest
   weight in the balanced profile, stop being absent. Plus the CDN host health checks.
4. **The `dnssec` and `filter` probes**, which is what stops `capability` coming out at 10 for
   every provider.

Nothing here is blocked. The confidence intervals that decide tiers are wide today precisely
because `edge`, `encrypted` and `recursion` all contribute zero; this phase is what tightens
them.

Exit: the ECS column reproduces the published regional finding, a no-ECS resolver showing a
large edge penalty on Akamai-backed hosts from here.

### Phase 5: M3 TUI, and Phase 6: M4 distribution

As specified in `docs/TUI.md` and `docs/ROADMAP.md`. The TUI is last, deliberately: a pretty
table of wrong numbers is worse than no table.

## Capturing the test byte vectors

Neither `kdig` nor `dig` writes raw wire bytes to a file, so the bytes have to be taken off the
wire. `tcpdump` would do it and needs root; `tools/capture_wire.py` does it without, by relaying
UDP from `127.0.0.1:15353` to the resolver and writing both directions verbatim.

```sh
python3 tools/capture_wire.py minimal dnssec cname nxdomain &
kdig +noedns +nocookie -p 15353 @127.0.0.1 google.com A
kdig +dnssec           -p 15353 @127.0.0.1 google.com A
kdig +noedns +nocookie -p 15353 @127.0.0.1 www.microsoft.com A
kdig +noedns +nocookie -p 15353 @127.0.0.1 nxdomain-test-dnsbench.example A
```

The query bytes are the ones kdig produced and the response bytes are the ones the resolver
sent. The relay copies; it never rewrites. `CLAUDE.md` stands: real captured bytes, never bytes
we invented and never another implementation's rendering of them.

`+noedns +nocookie` on the first capture is load-bearing. Without it the query carries an OPT
record and a byte-for-byte comparison against `build_query`'s minimal form can never match.

What the four fixtures cover:

- `minimal`: no EDNS, one A answer, one compression pointer back to offset 12
- `dnssec`: EDNS0 OPT in both directions, payload size 1232, DO bit set. `google.com` has no
  DS, so there are no RRSIGs here and none are needed: what this proves is OPT round-tripping
- `cname`: three answers, two CNAMEs, and pointers that target the middle of an earlier
  record's rdata. A parser that only handles a pointer to offset 12 passes the rest and fails
  this one
- `nxdomain`: rcode 3, empty answer section, root SOA in authority, a 22-octet label

Port 15353 rather than 5353: mDNS holds 5353 on a desktop.

## Verified before writing any code

Every line below was confirmed by compiling and running, not by reading documentation.
Toolchain: V 0.5.2, commit `cbf4e85`, source at `/home/esli/GIT/v`.

The full API reference is `docs/V-NOTES.md`. What follows is the subset that changed a
decision.

**Multi-return with a result type is valid, including in an interface.** The form in an earlier
draft of `docs/ARCHITECTURE.md`, `!(([]u8), f64)`, has one pair of parentheses too many.
`!([]u8, f64)` compiles, and a struct satisfying an interface declaring it also compiles.

**`UdpConn.read` returns two values and `TcpConn.read` returns one**, and their receivers
differ:

```v
pub fn (mut c UdpConn) read(mut buf []u8) !(int, Addr)
pub fn (c TcpConn) read(mut buf []u8) !int
```

**DoT works, but not by the API the specification originally described.** `dial_ip` with a
`tls_hostname` parameter does not exist. The verified form dials the IP literal and hands the
verification hostname to the TLS layer:

```v
mut tcp := net.dial_tcp('1.1.1.1:853')!
mut s := ssl.new_ssl_conn(validate: true, verify: '/etc/ssl/certs/ca-certificates.crt')!
s.connect(mut tcp, 'cloudflare-dns.com')!
```

Measured on this link: handshake 32.18 ms, query on the established connection 5.62 ms. That
ratio is the `dot-fresh` versus `dot-warm` thesis of `docs/METHODOLOGY.md`, confirmed before a
line of the probe was written.

**`validate: true` without `verify:` fails every handshake.** V loads no system trust store.
mbedtls returns `MBEDTLS_ERR_SSL_CA_CHAIN_REQUIRED`; the OpenSSL backend returns
`SSL_get_verify_result = 19`. This is why decision 8 exists.

**Hostname verification is genuinely enforced.** Dialling `1.1.1.1:853` and passing an SNI of
`dns.google` fails with `MBEDTLS_ERR_X509_CERT_VERIFY_FAILED`. Connecting by IP literal is a
measurement decision, not a security shortcut.

**`json2` is the canonical module path** in 0.5.2. `x.json2` survives as a legacy alias, and
`CLAUDE.md` originally pointed at it.

**Struct names of a single capital letter are rejected**, reserved for generic type parameters.
A trivial trap, but it costs a compile cycle every time.

`toml.parse_text`, `json2.encode`, `rand.shuffle`, `time.new_stopwatch`, `spawn` and typed
channels were all exercised in one program that also performed a real DNS query and returned
`rcode=0` in 7.64 ms.
