# Day-one checklist

What to do tomorrow morning, in order. Each item is small enough to finish before losing
momentum, and each unlocks the next.

## Before writing code

- [ ] **Decide the name.** `dnsbench` collides with GRC's commercial product. Check GitHub,
      AUR, crates.io, npm and VPM. This blocks the repo, the module path and every import in
      the codebase — deciding it later means a rename across every file.
- [ ] `git init`, MIT `LICENSE`, `.editorconfig`, `.gitignore`.
- [ ] Copy these docs in as the first commit, **before** any code. They are the spec; code
      that disagrees with them is the thing that is wrong.
- [ ] Create the cold-probe zone: delegate `probe.<name>.<yourdomain>` with a wildcard A and a
      60 s TTL. Verify recursion works from an external resolver before relying on it.

## First code, in this order

- [ ] `core/wire.v` — `build_query()`, `parse_header()`, `rcode()`. Nothing else.
- [ ] `testdata/` — capture three real responses with
      `kdig +noall +answer +additional google.com @1.1.1.1` and assert against the bytes.
      **Byte vectors, never another implementation's output.**
- [ ] `core/transport.v` — UDP only. Remember `UdpConn.read()` returns `(int, net.Addr)`.
- [ ] `core/stats.v` — percentiles, jitter, loss. Unit-tested against hand-computed values.
- [ ] A throwaway `main` that queries one resolver and prints a latency. **Compare against
      `kdig` on the same link.** If the numbers disagree, stop and fix it — everything else is
      built on this.

## Traps already identified

Each of these cost time during the research phase. They are documented so they cost nothing
now.

| Trap | Fix |
|---|---|
| `UdpConn.read()` returns two values | `n, _ := conn.read(mut buf)!` |
| `db.sqlite` needs `sqlite3.h` at build time | JSONL on the default path; SQLite behind a build flag |
| Resolving the DoT hostname per query pollutes the sample | Dial by IP literal, set SNI and verification hostname explicitly |
| Fresh TLS handshake per query inflates every provider by ~85 ms | Measure `dot-fresh` and `dot-warm` separately; score only `dot-warm` |
| Testing providers in sequential blocks penalises whoever goes first | Interleave rounds, shuffle order per round |
| The first sample carries handshake and route-setup cost | Discard the first sample per (provider, probe) |
| A local cache at 0.3 ms "beats" every network resolver | `is_cache: true`, excluded from the warm ranking, shown in its own section |
| Overwriting the mobile log with the fibre log | ASN + interface stamped into every JSONL line; `history` refuses to mix |
| Refreshing the domain list per run | Pin the Tranco ID; it travels in the output |
| DoH over HTTP/1.1 compared against browser HTTP/2 | Label `http_version` in the output; say so in the docs |

## Definition of done for week 1

A single command that:

1. Reads the embedded catalog.
2. Probes every provider over UDP with interleaved rounds and a discarded first sample.
3. Prints p50 / p95 / jitter / loss / n per provider.
4. Emits `--json` that validates against `schema/result.schema.json`.
5. Produces numbers within noise of `kdig` for the same provider on the same link.

No scoring, no TUI, no encryption, no ECS. Those are M1–M3. If item 5 fails, nothing else
matters yet.

## What to resist in week 1

- Starting with the TUI because it is the fun part. A pretty table of wrong numbers is worse
  than no table.
- Adding providers. Sixteen is plenty until the measurement is trustworthy.
- Implementing the score. It is meaningless until the probes it consumes are correct.
- Optimising. A benchmark that runs in 40 s instead of 47 s helps nobody.
