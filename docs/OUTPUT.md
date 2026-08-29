# Output contract

Three formats, one guarantee: **anything that consumes `--json` will keep working.**

## Stability policy

- `schema_version` is the contract. It increments only on breaking change.
- New fields may be added within a major version. Consumers must ignore unknown fields.
- Fields are never renamed or repurposed within a major version. Removal requires a bump.
- Table and TUI layout carry **no** stability guarantee. Do not parse them; use `--json`.

## `--json` — single run

```json
{
  "schema_version": 1,
  "tool": { "name": "dnsbench", "version": "0.1.0", "commit": "a1b2c3d" },
  "run": {
    "started_at": "2026-08-28T09:14:02-03:00",
    "duration_s": 47.3,
    "complete": true,
    "rounds": 5,
    "profile": "balanced",
    "weights": {
      "latency": 0.20, "recursion": 0.10, "stability": 0.15, "reliability": 0.15,
      "edge": 0.25, "encrypted": 0.05, "capability": 0.05, "privacy": 0.05
    }
  },
  "network": {
    "asn": "AS27699",
    "asn_org": "TELEFONICA BRASIL S.A",
    "interface": "wlan0",
    "ipv6": false,
    "region": "SA",
    "region_source": "rir",
    "vpn_detected": false,
    "dns_interception": false
  },
  "datasets": {
    "catalog": { "source": "embedded", "version": 3, "providers": 16 },
    "domains": { "warm": "tranco:K2XVW", "regional": "sa", "cold_mode": "own" },
    "cdn_hosts": { "total": 4, "stale": 0 }
  },
  "results": [
    {
      "key": "nextdns",
      "label": "NextDNS",
      "rank": 1,
      "tier": 1,
      "score": 92.4,
      "is_cache": false,
      "excluded": null,
      "subscores": {
        "latency": 94.7, "recursion": 90.3, "stability": 83.4, "reliability": 100.0,
        "edge": 74.2, "encrypted": 94.7, "capability": 100.0, "privacy": 70.0
      },
      "probes": {
        "warm":      { "n": 40, "expected": 40, "refused": 0, "p50": 15.0, "p95": 24.8, "max": 32.8,
                       "mean": 16.2, "jitter": 3.1, "loss": 0.0 },
        "cold":      { "n": 40, "expected": 40, "refused": 0, "p50": 31.0, "p95": 44.2, "max": 51.0,
                       "mean": 33.1, "jitter": 6.0, "loss": 0.0 },
        "dot_fresh": { "n": 40, "expected": 40, "refused": 0, "p50": 101.4, "p95": 119.9, "max": 139.7,
                       "mean": 102.4, "jitter": 9.8, "loss": 0.0 },
        "dot_warm":  { "n": 40, "expected": 40, "refused": 0, "p50": 17.0, "p95": 25.9, "max": 30.1,
                       "mean": 18.1, "jitter": 3.4, "loss": 0.0 },
        "doh":       { "n": 40, "expected": 40, "refused": 0, "p50": 100.9, "p95": 117.7, "max": 129.6,
                       "mean": 101.8, "jitter": 8.9, "loss": 0.0,
                       "http_version": "1.1" }
      },
      "edge": {
        "median_penalty_ms": 3.9,
        "misrouted": 0,
        "measured": 9,
        "hosts": [
          { "host": "www.microsoft.com", "answer": "23.55.0.0",
            "connect_ms": 15.1, "penalty_ms": 3.9, "stale": false },
          { "host": "cdn.jsdelivr.net", "answer": "104.16.0.0",
            "connect_ms": 13.2, "penalty_ms": 1.0, "stale": false }
        ]
      },
      "capabilities": {
        "dnssec_validating": true,
        "filtering": { "ads": true, "malware": true },
        "transports": ["udp", "tcp", "dot", "doh"],
        "ipv6": true
      },
      "declared": ["nolog", "nofilter"],
      "warnings": []
    }
  ],
  "warnings": [
    { "level": "warn", "key": "quad9-ecs",
      "message": "27/35 TLS handshakes completed (22.9% loss) — possible MTU or CGNAT issue" }
  ]
}
```

### Field notes

- `declared` is separate from `capabilities` by design. `capabilities` is measured;
  `declared` is what the provider says. Consumers must not merge them.
- `excluded` is `null`, or one of `"cache"`, `"low_n"`, `"unreachable"`, `"refused"`,
  `"unscored"`, with the reason visible rather than the row silently absent. Three of those
  describe a provider that did answer. `"refused"` is a resolver that replies REFUSED,
  SERVFAIL or NXDOMAIN to everything: it answered, and calling that silence blames the network
  for a decision the operator made. `"unscored"` is a provider measured only on probes that do
  not rank, such as an encrypted-only entry asked for over DoH alone: it answered every
  question put to it and was never asked one the score is built from.
- `http_version` appears on DoH results only, and is always `"1.1"`. V's stdlib has no h2
  client, so the figure is not comparable with a browser's real h2 behaviour and the output
  says which one it is. Some endpoints, Quad9's among them, answer HTTP 505 to every HTTP/1.1
  request because they serve DoH over h2 only; that is recorded as `refused` with a warning
  naming the status, never as loss.
- `refused` counts attempts the resolver answered with a non-NOERROR rcode. They produce no
  latency, so they never reach `n`, and they are not `loss`, which counts only attempts
  that drew no answer at all. A provider can therefore show `loss` of 0.0 and still be
  excluded, which is the honest reading of a server that replies to everything and
  resolves nothing.
- `edge.misrouted`, out of `edge.measured`, is how many CDN hosts came back more than 25 ms
  adrift. It is reported because `median_penalty_ms` alone is a fragile summary of a bimodal
  set: see METHODOLOGY § Why the count is published next to the median. It informs and does
  not rank; the `edge` subscore reads the median.
- `mean` exists in JSON and appears in no human-facing output. See METHODOLOGY.
- `p50`, `p95`, `max`, `mean` and `jitter` are `null` when there was no sample to derive them
  from: all five when `n` is 0, and `jitter` also when `n` is 1, where the sample standard
  deviation is undefined. **They are never 0 for that reason**, because 0 is a latency, and the
  best one on the page: a resolver that answered nothing would otherwise sort first and the
  `latency` subscore, `best_p50 / this_p50`, would divide by it.
- Those five fields are always **present**. Null says the tool looked and there was nothing;
  an absent field would be indistinguishable from a producer that predates it, which the
  ignore-unknown-fields rule above makes ambiguous by design.
- A `subscores` entry is `null` on the same terms: the provider had no measurement to derive
  that component from. It contributes 0 to the composite and renders as `n/a`. Emitting 0 here
  would say the component was measured and came out worst, which is a different claim.
- `rank`, `tier` and `score` are `null` for a provider carrying an `excluded` reason. The row
  stays in the array: docs/ARCHITECTURE.md § Failure policy keeps it in the output, out of the
  ranking, with the reason visible.
- `http_version` on `doh` exists because an h1.1 measurement is not comparable to a browser's
  real h2 behaviour, and hiding that would be dishonest.
- `region_source` is one of `flag`, `config`, `rir`, `tz`, `default`.
- `score_ci` is the bootstrap confidence interval on the composite score, low and high.
  Providers whose intervals overlap share a tier, so carrying it is what makes that grouping
  checkable from the output alone rather than on trust. Null for a provider that was not
  ranked.
- `capabilities.transports` names transports, not probes. `warm` and `cold` are two questions
  asked over one UDP socket.

The full JSON Schema lives in `schema/result.schema.json` and is validated in CI against
every golden file in `testdata/`.

## `history` — JSONL

`$XDG_DATA_HOME/dnsbench/runs.jsonl`, append-only, one flattened measurement per line:

```json
{"ts":"2026-08-28T09:14:02-03:00","asn":"AS27699","ifname":"wlan0","ipv6":false,
 "provider":"quad9-ecs","probe":"warm","n":40,"refused":0,"p50":16.9,"p95":68.1,
 "jitter":14.2,
 "loss":0.0,"edge_penalty":11.4,"edge_misrouted":1,"score":58.7,"profile":"balanced",
 "catalog_version":6,"domains":"tranco:K2XVW+sa","cold_mode":"own","tool":"0.1.0"}
```

**Not SQLite**, deliberately. V's `db.sqlite` requires `sqlite3.h` at build time, which means
either linking against the system libsqlite3 (goodbye self-contained binary) or vendoring the
amalgamation (goodbye one-second builds). For a tool that runs a few times a week, JSONL is
sufficient, `jq`-able, `grep`-able, diffable, and attachable to a support ticket.

SQLite remains available behind an optional build flag (`-d use_sqlite`) for anyone doing
long-horizon trend analysis. It is not on the default path.

### Network fingerprint is mandatory on every line

`asn` and `ifname` are not optional metadata. Without them, history silently mixes fibre and
mobile measurements into one meaningless average. `dnsbench history` groups by them by default
and refuses to aggregate across `cold_mode` or across incompatible `domains` IDs.

This exists because that exact mistake — overwriting a mobile log with a fibre one — happened
during the research that motivated this tool.

```sh
dnsbench history --last 30d                    # grouped by network, default
dnsbench history --last 30d --asn AS27699
dnsbench history --provider nextdns --plot     # sparkline of p50 over time
```

## `--csv`

Flat, one row per (provider, probe). For spreadsheets and for people who will not install
`jq`. Same numbers, no nesting, header row included.

```
provider,probe,n,expected,refused,p50,p95,max,jitter,loss,edge_penalty,edge_misrouted,score
nextdns,warm,40,40,0,15.0,24.8,32.8,3.1,0.0,3.9,0,92.4
```

## `--format markdown`

Emits the ranked table as a GitHub-flavoured markdown table, for pasting into issues, tickets
and blog posts. Includes the header metadata block as a fenced comment so the result stays
self-describing when pasted.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Run completed |
| 1 | Run completed with errors, or interrupted (partial results emitted) |
| 2 | Usage error |
| 3 | No provider reachable — likely no connectivity |
| 4 | Catalog verification failure on `update` |

Suitable for cron and CI: a monitoring job can alert when the winning provider changes or when
`edge_penalty` for the configured resolver crosses a threshold.
