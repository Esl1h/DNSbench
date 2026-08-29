# Scoring

A single number that ranks resolvers is a lie unless you publish exactly how it is computed
and let the user change it. This document is that publication.

## Principles

1. **Every weight is visible.** The active profile and its weights are printed in the header
   of every output format. Nothing is hidden in the binary.
2. **Measured and declared are never mixed.** Latency is measured. "No logging" is a claim by
   the provider. They occupy different columns and different visual styles.
3. **Normalisation is relative to the run**, not to absolute thresholds. A 30 ms p50 is
   excellent on mobile and mediocre on fibre; the run's own best defines the top.
4. **The score exists to order the table.** The underlying metrics are always shown next to
   it. A user who disagrees with the weights can read the raw columns.

## Subscores

Each is normalised to 0–100 within the run. Higher is better.

| Subscore | Source metric | Normalisation |
|---|---|---|
| `latency` | `warm.p50` | `100 × best_p50 / this_p50` |
| `recursion` | `cold.p50` | `100 × best_cold / this_cold` |
| `stability` | `warm.p95`, `warm.jitter` | `100 × (0.6 × best_p95/p95 + 0.4 × best_jitter/jitter)` |
| `reliability` | `loss` across all probes | `100 − loss`, where `loss` is the percentage |
| `edge` | `ecs_penalty` (ms above run best) | `100 × best_rtt / (best_rtt + penalty)` |
| `encrypted` | `dot-warm.p50` | `100 × best_dot_warm / this_dot_warm` |
| `capability` | DNSSEC validation, transports offered | discrete, see below |
| `privacy` | catalog tags — **declared** | discrete, see below |

Ratio normalisation (`best / this`) rather than min-max: it is bounded, monotonic, and it
degrades gracefully when one provider is catastrophically bad, whereas min-max would compress
every good provider into a narrow band.

### `edge` in detail

```
best_rtt      = min connect time to any CDN host, any provider, this run
penalty       = median(this_provider_connect − best_for_that_host)
edge subscore = 100 × best_rtt / (best_rtt + penalty)
```

A provider with zero penalty scores 100. With `best_rtt = 12 ms` and a 90 ms penalty it scores
`100 × 12 / 102 ≈ 12`. That is the intended severity: bad CDN mapping should be visible from
across the room.

### `capability`

```
+60  validates DNSSEC
+20  offers DoT
+10  offers DoH
+10  offers IPv6 and IPv6 is available on this network
```

Transports the network cannot reach do not count. Scoring a provider for DoQ on a link where
QUIC is blocked would be scoring a brochure.

### `privacy` — declared, never measured

```
+40  nolog        provider states it does not log
+30  nofilter     no content manipulation
+30  audited      published independent audit
```

These come from the catalog, which comes from provider statements. **The tool cannot verify
them and does not claim to.** In the TUI they render in a distinct style with a `~` prefix,
and the footer says `~ declared by provider, not measured`.

In the `privacy` profile these weights matter a lot. This is the one place where the tool
propagates unverified claims, so it is the one place with the loudest disclaimer.

## Profiles

```
Σ weights = 1.0
```

| Subscore | balanced | speed | privacy | streaming | gaming |
|---|---|---|---|---|---|
| `latency` | 0.20 | 0.35 | 0.10 | 0.10 | 0.25 |
| `recursion` | 0.10 | 0.15 | 0.05 | 0.05 | 0.10 |
| `stability` | 0.15 | 0.15 | 0.05 | 0.15 | 0.35 |
| `reliability` | 0.15 | 0.10 | 0.10 | 0.20 | 0.20 |
| `edge` | 0.25 | 0.20 | 0.10 | 0.40 | 0.05 |
| `encrypted` | 0.05 | 0.05 | 0.15 | 0.05 | 0.05 |
| `capability` | 0.05 | 0.00 | 0.15 | 0.05 | 0.00 |
| `privacy` | 0.05 | 0.00 | 0.30 | 0.00 | 0.00 |

Reasoning:

- **balanced** — `edge` is the largest single weight because it is the largest real-world
  effect and the one no other tool measures.
- **speed** — what people think they want. Still keeps `edge` high, because a fast lookup to a
  distant CDN edge is not speed.
- **privacy** — declared flags dominate, encrypted transports matter, raw latency mostly does
  not.
- **streaming** — `edge` is nearly half. Streaming is CDN-bound; DNS latency is irrelevant
  once the stream starts.
- **gaming** — `stability` dominates. Spikes cause visible lag; median does not.

Custom profiles:

```toml
# ~/.config/dnsbench/config.toml
[profile.mine]
latency = 0.30
edge = 0.40
stability = 0.20
reliability = 0.10
```

Missing keys default to 0. The tool normalises the sum to 1.0 and prints the effective
weights, so a typo produces a visible wrong header rather than a silently wrong ranking.

## Exclusions

| Case | Treatment |
|---|---|
| Local cache (`is_cache: true`) | Excluded from `latency` ranking; included in `recursion` |
| `n < 30` on any scored probe | `low-n` marker, no tier assignment |
| `n == 0` on the scored probe | Score `—`, sorted last, reason shown: `unreachable` when nothing came back, `refused` when every answer carried a non-NOERROR rcode |
| Provider missing a scored probe | Subscore = 0 for that component, marked `n/a` in detail view |
| Source metric is `null` | Same treatment. A probe with no sample has no p50, so there is nothing to divide by; see METHODOLOGY § Nothing is not zero |

The local cache exclusion is the single most important one. A `0.3 ms` cache hit is not
competing with a `15 ms` network round trip — it is a different measurement wearing the same
units. They are displayed in separate sections.

## Ties

Providers whose bootstrap confidence intervals on the composite score overlap share a rank
number and a tier band. See METHODOLOGY § Tiers.

The tool will never present a 0.3-point score difference as a winner.

## Worked example

```
Run: 6 providers, balanced profile
best_p50 = 14.2   best_cold = 28.0   best_p95 = 21.7
best_jitter = 2.4  best_rtt = 11.2    best_dot_warm = 16.1

Provider X: p50 15.0, cold 31.0, p95 24.8, jitter 3.1, loss 0,
            ecs_penalty 3.9, dot-warm 17.0, DNSSEC yes, DoT+DoH+v6, nolog+nofilter

latency     = 100 × 14.2/15.0                       =  94.7
recursion   = 100 × 28.0/31.0                       =  90.3
stability   = 100 × (0.6×21.7/24.8 + 0.4×2.4/3.1)   =  83.5
reliability = 100 − 0.0                             = 100.0
edge        = 100 × 11.2/(11.2+3.9)                 =  74.2
encrypted   = 100 × 16.1/17.0                       =  94.7
capability  = 60 + 20 + 10 + 10                     = 100.0
privacy     = 40 + 30                               =  70.0

score = 0.20(94.7) + 0.10(90.3) + 0.15(83.5) + 0.15(100.0)
      + 0.25(74.2) + 0.05(94.7) + 0.05(100.0) + 0.05(70.0)
      = 18.94 + 9.03 + 12.52 + 15.00 + 18.55 + 4.74 + 5.00 + 3.50
      = 87.3

The subscores above are shown rounded to one decimal; the composite is computed from the
unrounded values. Both routes give 87.3, and the test asserts that.
```

This exact computation is a unit test (`testdata/scoring_worked_example.json`). If the
implementation and this document ever disagree, the test fails and one of them is wrong.
