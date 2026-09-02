# AGENTS.md

Instructions for Claude Code working in this repository. Read this before anything else.

## What this project is

`dnsbench` benchmarks and ranks DNS resolvers **from the user's own connection**, including
CDN edge latency (ECS quality) — a metric no existing public tool measures. CLI + TUI, single
static binary, written in **V**.

## Non-negotiable rules

### 1. The documentation is the specification

`docs/` was written before any code. When code and docs disagree, **the docs are right and the
code is the bug** — unless you are explicitly asked to change the spec, in which case update
the doc **in the same commit**.

Read before touching related code:

| Before working on | Read |
|---|---|
| V stdlib API shapes | `docs/V-NOTES.md` |
| Any probe or measurement | `docs/METHODOLOGY.md` |
| Module boundaries, data flow | `docs/ARCHITECTURE.md` |
| Score, weights, tiers | `docs/SCORING.md` |
| JSON, CSV, JSONL, exit codes | `docs/OUTPUT.md` |
| Catalog, domain sets | `docs/DATA.md` |
| Terminal UI | `docs/TUI.md` |
| What to build next | `docs/PLAN.md`, `docs/ROADMAP.md` |

Do not invent measurement behaviour. Every probe's semantics are already defined.

### 2. `.bootstrap/` was scratch and was never committed

The `.bootstrap/` directory held the material used to start the project: the kickoff prompt and
three V prototypes. It was gitignored and does not exist in a clone.

Nothing may depend on it. Every verified stdlib fact it demonstrated is in `docs/V-NOTES.md`,
which is permanent, and that file is where any new one goes. If a copy of the directory is
still lying around on a working machine, it is stale by several milestones.

### 3. V is under-represented in your training data — verify, never guess

This is the single biggest risk in this repo. **You will confidently produce V code that does
not compile**, using APIs that look plausible but do not exist.

Rules:

- **Never write more than ~30 lines of V without compiling.** `v -o /tmp/x .` after every
  meaningful change.
- **Never assume a stdlib signature.** Check the actual source:
  ```sh
  grep -rn "pub fn dial_udp" ~/.vmodules ~/v/vlib 2>/dev/null
  v doc net
  v doc -f net.UdpConn
  ```
- If an API you expected does not exist, say so and propose an alternative. Do not invent a
  wrapper and pretend it works.
- Do not port idioms from Go or Rust. V's error handling is `!T` / `?T` with `or {}`, not
  `(T, error)` and not `Result<T, E>`.

Known gotchas already discovered — do not rediscover them:

| Gotcha | Correct form |
|---|---|
| `UdpConn.read()` returns two values | `n, _ := conn.read(mut buf)!` |
| `db.sqlite` needs `sqlite3.h` at build time | Do not use it. JSONL is the storage path |
| TLS client | `net.dial_tcp('<ip>:853')!` then `ssl.new_ssl_conn(...)!` then `.connect(mut tcp, sni_host)!` |
| `ssl.new_ssl_conn(validate: true)` with no `verify:` | Always fails; V loads no system CA store. Pass `verify: <ca bundle path>` |
| Terminal UI | `import term.ui as tui`, callback-based `event_fn` / `frame_fn` |
| Embedding assets | `$embed_file('data/providers.toml')`, `.to_string()` |
| TOML, JSON | `import toml`, `import json2` — both in stdlib, both verified working. `x.json2` is the legacy path |
| No QUIC in V | DoQ is out of scope. Do not attempt it |
| `net.http` is HTTP/1.1 | DoH results must carry `http_version: "1.1"` in output |

### 4. Everything in English

Code, identifiers, comments, commit messages, docs, CLI strings, TUI strings, test fixtures.
No exceptions. Numbers use `.` as decimal separator regardless of locale.

The maintainer speaks Portuguese; the project does not. If the maintainer writes to you in
Portuguese, reply in Portuguese but **write English into every file**.

### 5. Measured and declared are never mixed

`dnssec_validating` is probed. `nolog` is a claim by the provider. They live in separate
structs, separate JSON objects, and separate visual styles. A declared tag must never
contribute to a measured subscore. This is enforced in code, not by convention.

### 6. Correctness before features

Do not build the fun part before the correct part. A pretty table of wrong numbers is worse
than no table.

Any new probe or transport must match `kdig` on the same link, within noise, before anything
built on top of it is trusted.

## Build and test

```sh
make build          # v -o dnsbench cmd/cli.v
make run            # build and run
make test           # v test .
make fmt            # v fmt -w .   — required before every commit
make vet            # v vet .
make check          # fmt + vet + test + schema validation
```

Always run `make check` before proposing a commit.

## Verification is not optional

Do not tell the maintainer something works. Show the command and its output.

- New parsing code → a test with real captured bytes in `testdata/`, never bytes you invented.
- New measurement → compare against `kdig` on the same target and report both numbers.
- New output field → the golden JSON must still validate against `schema/result.schema.json`.
- Changed score → recompute the worked example in `docs/SCORING.md` and show before/after.

## Do not

- Send traffic to public resolvers from tests. Integration tests use a local mock authoritative
  server. Manual verification against real resolvers is fine and must be rate-limited.
- Add providers to `data/providers.toml` without a public documentation URL for every endpoint.
- Use `panic()` outside `main`.
- Add a dependency. The binary is static and dependency-free by design; raise it as a decision
  instead of adding one.
- Refresh domain lists at runtime. They are pinned. See `docs/METHODOLOGY.md` § Pin the dataset.
- Add telemetry of any kind.
- Reformat or restructure files you were not asked to touch.

## Working style

- Prefer small, compiling increments over large drafts.
- When a design decision is genuinely open, ask rather than picking silently — the open ones
  are listed in `docs/ROADMAP.md`.
- Comments explain **why**, not what. `// discard the first sample: it pays for the TLS
  handshake` is useful; `// loop over providers` is noise.
- If you find a real bug in the docs, say so directly. The docs were written before the code
  and have not been validated against a compiler.
