# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

Score changes are **semver-minor at minimum** — users make decisions based on that number.
Dataset ID bumps (Tranco list, catalog version) get their own entry: they break historical
comparability and `history` must be able to detect it.

## [Unreleased]

### Added
- `core/edge.v`: the ECS probe, the metric the project exists for. Each CDN host is resolved
  through every provider and a TCP connect to the returned address is timed; the baseline for
  a host is the best connect any provider achieved in the same run, so the probe calibrates
  itself and needs no geolocation, IP database or country code
- `--probes ecs`, five `[[cdn_host]]` entries in the catalog, and an `EDGE` column in the
  table and Markdown output
- `core/transport.v`: `connect_ms`, a TCP connect bounded by a deadline. V's `net.dial_tcp`
  performs a blocking connect with no timeout on the default build path, so one CDN address
  that black-holes 443 would otherwise stall a run for as long as the kernel takes to give up
- `core/wire.v`: `Response.a_addresses` and `Response.cname_targets`, with `rdata_off` on
  every record so a compressed CNAME target can be decoded against the message it came from
- `refused` on every probe's stats, in JSON, CSV and the history lines: attempts the resolver
  answered with a non-NOERROR rcode. They produce no latency, so they never reach `n`
- `excluded: "refused"`, for a provider that answered every query and resolved none of them
- Project documentation and specification (ARCHITECTURE, METHODOLOGY, SCORING, TUI, DATA, OUTPUT)
- Curated provider catalog, 16 entries, endpoints verified 2026-08-28
- Domain sets pinned to `tranco:K2XVW` retrieved 2026-08-15
- JSON Schema for the output contract, `schema_version: 1`
- `docs/PLAN.md`: development phases, settled decisions, and the V stdlib facts verified
  against a compiler before any code was written
- MIT `LICENSE`
- `core/stats.v`: percentiles, max, mean, jitter and loss, with the timeout rule enforced
  structurally by taking successes and attempt count as separate arguments
- `core/stats_test.v`: 12 tests, 51 assertions, every expectation computed by hand and shown
  as the arithmetic that produced it
- `docs/V-NOTES.md`: verified V stdlib signatures, the DoT connect form, and the language and
  tooling traps found so far
- `core/wire.v`: DNS message encode and decode per RFC 1035, EDNS0 per RFC 6891. Compression
  pointers must point strictly backwards, which makes a pointer cycle unrepresentable rather
  than merely guarded against
- `core/wire_test.v`: 17 tests, 83 assertions, against four real exchanges captured from
  kdig 3.5.7 and 1.1.1.1
- `tools/capture_wire.py`: captures real wire bytes into testdata/ through a local UDP relay,
  without root
- `testdata/*.bin`: the captured fixtures, query and response for each exchange
- `core/transport.v`: the `Transport` interface with UDP and TCP behind it. A UDP reply whose
  id does not match the query is discarded rather than timed, so a late answer to an earlier
  query cannot be recorded as an implausibly fast sample for this one
- `core/netinfo.v`: resolver discovery from `/etc/resolv.conf`, `resolvectl status` and
  `ip route`, loopback resolvers marked as caches, and tunnel detection from interface flags
- `catalog/model.v` and `catalog/embedded.v`: the embedded catalog, with the tag vocabulary
  split into `measured` and `declared` so a scorer cannot reach a declared tag by accident
- `cmd/cli.v`: the M0 verification harness. Probes one resolver over UDP and reports the
  statistics kdig can be made to report, for comparison. Not the CLI
- `testdata/*.sample`: `ip route`, `ip -o link` and `resolv.conf` fixtures, real output with
  addresses moved to the RFC 5737 range and MACs to the RFC 7042 documentation MAC
- `core/transport_test.v`, `core/netinfo_test.v`, `catalog/model_test.v`
- `core/score.v`: the eight published subscores, the five weight profiles, run-relative
  normalisation and the composite. Caches set no warm best and take no latency or stability
  subscore; `privacy` reads declared tags and nothing else
- `core/score_test.v` and `testdata/scoring_worked_example.json`: the worked example from
  `SCORING.md` is now the test the document claims it is, reading its numbers from one shared
  source
- `core/schedule.v`: the measurement plan and its pacing. Interleaved rounds with a fresh
  shuffle each round, one discarded warm-up query per provider-probe pair, and a per-provider
  rate limit of 10 qps with jitter. It opens no socket and holds no clock, so the fairness
  rules are asserted directly rather than inferred from a run
- `core/schedule_test.v`
- `core/tier.v`: bootstrap confidence intervals on the composite score, and tier and rank
  assignment from them. Each replicate resamples every provider's latencies and recomputes the
  run's bests inside the replicate, because normalisation is relative to the run and holding
  the reference point fixed would understate every interval
- `store/report.v`: the JSON output contract, CSV, and the exit codes. The JSON is assembled
  from `json2.Any` maps rather than encoded from structs, because an absent option encodes as a
  missing key and the contract calls for an explicit null
- `store/jsonl.v`: append-only history with the network fingerprint on every line, and the
  comparability rule that stops `history` averaging a fibre run with a mobile one
- `testdata/golden/run.json`: the first golden run result, validated against the schema by
  `make check` and by CI
- `store/report_test.v`, `core/tier_test.v`, `core/score_test.v`
- `store/report.v`: table and markdown emitters. Neither carries a stability guarantee; the
  table puts unranked rows in their own section below the line and prints a dash where there is
  no figure
- `cmd/cli.v`: the real command line. Catalog, network discovery, plan, transports, statistics,
  scoring, tiering and four output formats, wired together. `--profile`, `--only`, `--rounds`,
  `--probes`, `--format`, `--history`, `--timeout`, `--cold-zone`, `--seed`, `--force`
- `cmd/cli_test.v`
- `PLAN.md` § Where this stands: the state of every module, what is outstanding below the level
  of a phase, and what Phase 4 involves. It was scratch in a gitignored directory, which meant
  the project's own status did not survive a clone
- `DATA.md` § Setting the zone up: the records to publish for the cold-probe zone, the
  verification commands, and what operating it commits the operator to. Every cold query is a
  cache miss by construction, so all of that traffic reaches the authoritative servers
- `score_ci` in the output: the confidence interval that decided a provider's tier
- `core/netinfo.v`: IPv6 availability, read from the default IPv6 route. It gates the IPv6
  component of the capability subscore, so a provider is not credited for an address family
  the link cannot carry

### Changed
- Catalog `version` 4 to 5: the `[[cdn_host]]` table is new, so a run against version 4 has
  no edge column and is not comparable
- `docs/DATA.md`: the CDN example claimed `www.microsoft.com` ends in `akadns.net`. Verified
  against four resolvers, the chain ends in `akamaiedge.net`, and an entry with the wrong
  expected suffix would mark itself stale on every run
- `docs/DATA.md`: the CDN health check is run-wide and drawn from the run's own answers,
  rather than a separate lookup at run start. A separate lookup needs a reference resolver,
  and every candidate is either under test or the system resolver; and one provider answering
  oddly is the signal the probe exists to catch, not evidence the entry has rotted
- `loss` now counts only attempts that drew no answer at all. A REFUSED, SERVFAIL or NXDOMAIN
  reply used to be counted as a lost packet, which reported a resolver that answered every
  query in 380 ms as 100% loss and unreachable, blaming the network for a decision the
  operator had made. A provider can now show `loss` of 0.0 and still be excluded
- The CSV gains a `refused` column after `expected`, and the history lines a `refused` key.
  Both are contract changes: a consumer reading the CSV by column index has to be updated
- Catalog `version` 3 to 4, `generated` 2026-08-29. Removing Mullvad's plaintext endpoints
  changes which providers a plaintext run covers, so runs across the bump are not comparable
  and `history` must treat them as separate populations
- `p50`, `p95`, `max`, `mean` and `jitter` are absent, and serialize as `null`, when there was
  no sample to derive them from: all five at `n = 0`, and `jitter` also at `n = 1`, where the
  sample standard deviation is undefined. They were 0, which is a latency and the best one on
  the page: a resolver that answered nothing sorted first, and the `latency` subscore divides
  by `p50`. The five fields stay required in the schema, so `null` is distinguishable from a
  producer that predates the field
- `subscores` entries may be `null`, on the same terms as the latency figures: the provider had
  no measurement to derive that component from. It contributes 0 to the composite and renders
  as `n/a`, where 0 would say it was measured and came out worst
- Tiers use a bootstrap interval on the **composite score**, not on `p50`. `METHODOLOGY.md` and
  `SCORING.md` disagreed about which; the score is what orders the table, so a band drawn from
  `p50` would describe the uncertainty of a different quantity from the one being read
- `testdata/golden/` holds run results, and `make schema` validates that directory rather than
  all of `testdata/`, which also holds fixtures that are inputs rather than outputs
- Cold-probe zone fixed at `probe.dnsbench.esli.blog`, a DNSSEC-signed subzone delegated to
  Bunny DNS. The host is a fairness constraint and not an operational detail: `cold` measures
  the hop from a resolver to the authoritative, so hosting it on an operator that also runs a
  resolver in the catalog would hand that resolver an intra-network advantage no column
  explains. Cloudflare and DigitalOcean are both disqualified by it, DigitalOcean because its
  nameservers are Cloudflare's. `DATA.md` § The operator, and how it was chosen carries the
  measured comparison
- Percentile method fixed at nearest-rank with no interpolation, and per-probe timeouts
  defined (2 s plaintext, 5 s encrypted). Both were previously unspecified and both silently
  change reported numbers

### Fixed
- `cmd/cli.v`: a provider with no plaintext endpoint was dropped from the run in silence,
  while a provider needing configuration got a warning. Both now say why they are absent, and
  `--only` on such a key reports that the key matched and was skipped rather than that it
  matched nothing
- `data/providers.toml`: `mullvad` and `mullvad-base` carried `udp4` and `udp6` addresses
  that are not plaintext endpoints. Mullvad's own help page, already the `homepage` of both
  entries, says those IPs "can only be used with DNS resolvers that support DoH or DoT, not
  with DNS over UDP/53 or TCP/53", and the resolver on port 53 answers REFUSED to every name
  but Mullvad's own. Both entries are now DoT and DoH only and return in M2
- `cmd/cli.v`: `--help` listed `warm, tcp` as the known probes and omitted `cold`, which the
  parser has always accepted and which the parser's own error message already named
- `ARCHITECTURE.md`: the `Transport.query` signature had a spurious pair of parentheses
- `METHODOLOGY.md`: the DoT dial example used `dial_ip`, which does not exist in V. Replaced
  with the `dial_tcp` plus `SSLConn.connect` form, verified against a live resolver
- `ARCHITECTURE.md`: documented that V loads no system trust store, so `validate: true`
  requires an explicit CA bundle path
- `CLAUDE.md`: `json2` is the canonical module path in V 0.5.2, not `x.json2`
- `Makefile`: `check` ran `fmt`, which rewrites files and can never fail, while CI ran
  `fmt -verify`. Added `fmt-check` so local and CI agree
- `Makefile`: the `schema` target only checked that golden files were JSON; it now validates
  against the schema, as CI does
- `.gitignore`: `*.csv` and `*.jsonl` silently excluded the golden files that `OUTPUT.md`
  requires
- `catalog/model.v`: `nofilter` was classified as measured. The output schema, `OUTPUT.md`
  and `SCORING.md` all treat it as declared, and it carries a weight inside `privacy`, a
  subscore defined as declared and never measured. `DATA.md`'s table said "partially probed"
  and the code followed the table
- `core/wire.v`: the compression-pointer rule compared each target against the current offset,
  which advances as labels are consumed after a jump, so a chain of 100 to 50, labels to 90,
  then 90 to 50 looked backwards at every step and looped. Only the jump ceiling terminated it,
  while the comment claimed a cycle was unrepresentable. Successive targets must now strictly
  decrease, which makes that claim true
- `core/transport.v`: `Target.ip` documented an IP-literal requirement that nothing enforced.
  V dials a hostname happily, which would put a resolver lookup inside the connect path and
  report the round trips as clean latency. IPv6 targets are also bracketed rather than relying
  on V splitting at the last colon
- `core/transport.v`: `set_read_timeout` is a deadline per read, so discarding up to eight
  mismatched datagrams gave a query eight times the caller's timeout. The loop now tracks
  elapsed time against that budget
- `core/netinfo.v`: a default route with no gateway was ignored, so a point-to-point tunnel
  route lost to a higher-metric one and a tunnelled run was filed under the untunnelled
  interface's name
- `core/netinfo.v`: the IPv6 zone index was stripped, turning a link-local upstream into a
  different address that would leave via whatever interface the kernel picked
- `catalog/model.v`: endpoint addresses were never checked for being addresses. The `nextdns`
  entry's unsubstituted `__PROFILE__` placeholders loaded clean and would have reached
  `dial_udp` verbatim; such entries are now marked `needs_config`
- `cmd/cli.v`: a negative sample count aborted the process on a negative capacity, and an
  unparsable one silently measured nothing and printed zeros
- `cmd/cli.v`: socket errors, timeouts and non-NOERROR replies were all folded into `loss` and
  indistinguishable. A refusal is counted apart, and the first failure is reported
- `cmd/cli.v`: a run with no successful samples printed `p50 0.00 ms` beside `loss 100.0 %`,
  which reads as the fastest resolver on the page
- `.github/workflows/ci.yml`: the schema step globbed `testdata/*.json`, which matches nothing
  yet, so the first push would have gone red. It calls `make schema`, which has the guard
- `core/schedule.v`: a round emitted one query rather than one pass over the domain set, so a
  five-round run produced five samples and every row fell below the thirty-sample floor with
  the whole table marked `low_n`. `docs/METHODOLOGY.md` says a fixed set queried repeatedly and
  a discarded first *pass*; `expected_samples` now takes both rounds and domains
- `cmd/cli.v`: `--cold-zone` was accepted and then ignored. The cold probe asked the warm
  domain set, which is cached by every resolver on Earth, so it measured a cache hit rather than
  recursion. It now draws a fresh random label under the zone per query, which is deliberately
  not reproducible from the plan's seed: a label the plan could reproduce would be cached the
  second time it was asked
- `cmd/cli.v`: `capabilities.transports` was fed probe names, which the output schema rejected.
  `warm` and `cold` are two questions over one UDP socket
- `cmd/cli.v`: an unrecognised option reported that it was missing a value instead of saying it
  was not recognised, because the value check ran before the name check
- `core/schedule.v`: `rand.new_default` frees the seed array it is given, so passing a
  caller-owned array made a second `build_plan` a double free. It surfaced as an intermittent
  `free(): double free detected`, passing roughly two runs in three
- `SCORING.md`: the worked example printed `stability` as 83.4 where the arithmetic gives
  83.4677, and carried that through to 12.51 in the breakdown. The composite was already 87.3
  either way; the intermediate figures now agree with themselves
- `tools/capture_wire.py`: the docstring named port 5353 while the code binds 15353
- `DATA.md`: the tag vocabulary omitted `configurable`, which `nextdns` and both Control D
  entries were already using. It is declared: what such a resolver filters depends on a profile
  the tool cannot see
- `PLAN.md`: `build_query` returned a bare `[]u8` and so had no way to report a name it cannot
  encode. It returns `![]u8`: a malformed packet must fail at the encoder rather than reach a
  socket and reappear later as an unexplained loss sample
- `METHODOLOGY.md`: the nearest-rank note claimed `p50` on an even `n` is the upper of the two
  central samples. `ceil(50 / 100 x n)` is `n / 2`, so it is the lower one
- `METHODOLOGY.md` and `SCORING.md`: `loss` was given as a bare ratio in one place and bounded
  to `[0, 100]` by the schema in another. It is a percentage, and `reliability` is `100 − loss`.
  The worked example is unchanged at 100.0
