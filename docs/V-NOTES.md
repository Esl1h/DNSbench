# V stdlib notes

Verified API shapes, kept because V is thin in language-model training data and guessing
produces plausible code that does not compile. Every entry here was confirmed by compiling and
running, or by reading the V source at the line cited. Nothing in this file is from memory.

Toolchain: **V 0.5.2, commit `cbf4e85`**, source tree at `/home/esli/GIT/v`.

Two commands do most of the work:

```sh
grep -rn "pub fn dial_udp" ~/GIT/v/vlib
v doc -f net.UdpConn
```

When an API turns out not to exist, say so and propose an alternative. Do not wrap a guess and
call it verified.

## net

```v
pub fn dial_udp(raddr string) !&UdpConn                  // vlib/net/udp.c.v:41
pub fn dial_tcp(oaddress string) !&TcpConn               // vlib/net/tcp.c.v:44
```

Both take a single `host:port` string. There is no separate port argument, and no variant
taking a local bind address except `dial_tcp_with_bind`.

**`UdpConn.read` returns two values, `TcpConn.read` returns one, and their receivers differ.**
This is the single most common source of a failed compile in this codebase.

```v
pub fn (mut c UdpConn) read(mut buf []u8) !(int, Addr)   // vlib/net/udp.c.v:150
pub fn (c TcpConn) read(mut buf []u8) !int               // vlib/net/tcp.c.v:216
```

```v
mut buf := []u8{len: 4096}
n, _ := udp_conn.read(mut buf)!    // UDP: discard the peer Addr
n := tcp_conn.read(mut buf)!       // TCP
```

Timeout setters return nothing, so no `!` and no `or {}`:

```v
pub fn (mut c UdpConn) set_read_timeout(t time.Duration)
conn.set_read_timeout(2 * time.second)
```

Confirmed by a program that queried `1.1.1.1:53` with a hand-built DNS message and read back 44
bytes with `rcode=0` in 7.64 ms.

## net.ssl, for DoT

`dial_ip(ip, port, tls_hostname: ...)` **does not exist**. An early draft of the methodology
assumed it. The working form dials the IP literal as plain TCP, then hands the verification
hostname to the TLS layer:

```v
import net
import net.ssl

mut tcp := net.dial_tcp('1.1.1.1:853')!
mut s := ssl.new_ssl_conn(validate: true, verify: '/etc/ssl/certs/ca-certificates.crt')!
s.connect(mut tcp, 'cloudflare-dns.com')!
```

```v
pub fn new_ssl_conn(config SSLConnectConfig) !&SSLConn   // vlib/net/ssl/ssl_d_use_openssl.v:13
pub fn (mut s SSLConn) connect(mut tcp_conn net.TcpConn, hostname string) !
                                                         // vlib/net/openssl/ssl_connection.c.v:245
pub fn (mut s SSLConn) dial(hostname string, port int) ! // resolves the hostname itself
```

Use `connect`, never `dial`: `dial` performs a system-resolver lookup that would land inside
every latency sample.

`SSLConnectConfig` fields, from `vlib/net/openssl/ssl_connection.c.v`: `verify`, `cert`,
`cert_key`, `validate`, `in_memory_verification`, `alpn_protocols`.

**`validate: true` with no `verify:` path fails every handshake.** V loads no system trust
store. The default backend is mbedtls and reports `MBEDTLS_ERR_SSL_CA_CHAIN_REQUIRED`
(`-0x7680`); with `-d use_openssl` it reports `SSL_get_verify_result = 19`. See
`docs/ARCHITECTURE.md` § TLS trust anchor for where the bundle path comes from.

**Hostname verification is genuinely enforced.** Dialling `1.1.1.1:853` and passing an SNI of
`dns.google` fails with `MBEDTLS_ERR_X509_CERT_VERIFY_FAILED` (`-0x2700`, reported as `-9984`).
Connecting by IP literal is a measurement decision, not a verification bypass.

Measured on a live link: handshake 32.18 ms, then 5.62 ms for a query on the established
connection. That ratio is the `dot-fresh` versus `dot-warm` argument of `docs/METHODOLOGY.md`,
observed before the probe was written.

DNS over TCP and over TLS both use the RFC 7858 framing: a 2-byte big-endian length prefix
ahead of the message.

## toml, json2

```v
import toml
import json2

doc := toml.parse_text('version = 3')!       // vlib/toml/toml.v:365
doc := toml.parse_file(path)!                // vlib/toml/toml.v:347
v := doc.value('version').int()

s := json2.encode(some_struct)               // vlib/json2/encode.v:28
x := json2.decode[T](str)!                   // vlib/json2/decode.v:286
```

`json2` is the canonical module path in 0.5.2. `x.json2` also exists as a legacy alias; prefer
the short one.

## math, arrays, misc

```v
import math
math.ceil(x) // f64
math.sqrt(x) // f64
math.abs(x)  // f64
```

An array parameter that is not `mut` cannot be sorted in place, which is the compiler enforcing
that `compute` must not disturb its caller's sample:

```v
mut sorted := latencies_ms.clone()
sorted.sort()                        // ascending
```

Array literal with a computed initialiser, where `index` is an implicit binding:

```v
successes := []f64{len: 27, init: 20.0 + f64(index)}
```

`rand.shuffle(mut arr)!` returns a result and must be handled. Needed per round by
`docs/METHODOLOGY.md` § Interleave.

Elapsed time for a latency sample:

```v
import time

sw := time.new_stopwatch()
// ...
ms := f64(sw.elapsed().microseconds()) / 1000.0
```

Microseconds divided by 1000, not `.milliseconds()`, which truncates to integer milliseconds
and would quantise every sample on a fast link.

Concurrency, per `docs/ARCHITECTURE.md`: one worker per provider over a single channel.

```v
ch := chan ProbeResult{cap: providers.len * probes.len}
spawn worker(p, plan, ch)
got := <-ch
```

## Interfaces

An interface method may return a multi-value result type. The `Transport` interface in
`docs/ARCHITECTURE.md` depends on this, and it compiles:

```v
pub interface Transport {
	name() string
mut:
	open(target Target) !
	query(msg []u8) !([]u8, f64)
	close()
	reusable() bool
}
```

Note the parenthesisation: `!([]u8, f64)`, not `!(([]u8), f64)`.

## Language traps

**A struct named with a single capital letter is rejected.** Those names are reserved for
generic type parameters, and the error does not say so in a way that is obvious at first read:

```
error: single letter capital names are reserved for generic template types.
```

**A module directory needs a `main` or must be built as a library.** `v -o /tmp/x core/` fails
with `project must include a main module or be a shared library`. Until `cmd/cli.v` exists, the
compile check for a library module is:

```sh
v -shared -o /tmp/vcheck core/
v test core/
```

## Slices are implicit clones

**`arr[i..]` yields a copy, not a view.** Passing one as a `mut` read target means the socket
fills the copy and the caller's buffer stays untouched:

```v
mut chunk := buf[got..]
n := conn.read(mut chunk)!   // fills a clone; buf never changes, loop never ends
```

The compiler says so, as a `notice` rather than an error, and a notice is easy to scroll past:

```
notice: an implicit clone of the slice was done here
```

`core/transport.v` reads into a chunk sized to what is missing and copies it in. `unsafe {
buf[got..] }` would give a real view; the copy was preferred over reaching for `unsafe` on a
path this short.

## More net

`UdpConn` has **no `addr()`**, so a socket bound to port 0 cannot report the port it landed on.
A test that needs a known UDP port has to pick one and try. `TcpListener` does have it:

```v
mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
port := l.addr()!.port()!          // u16
```

```v
pub fn listen_udp(laddr string) !&UdpConn               // vlib/net/udp.c.v:320
pub fn listen_tcp(family AddrFamily, saddr string, options ListenOptions) !&TcpListener
pub fn (mut l TcpListener) accept() !&TcpConn
pub fn (mut c UdpConn) write_to(addr Addr, buf []u8) !int
```

`spawn f(mut x, y)` accepts a `mut` argument, which is how a test starts a mock server it has
already bound.

## toml, again

**`doc.value(key).array()` on a key that is not there returns a one-element array holding a
null**, not an empty array. A loop over it runs once on a phantom entry, so a missing table has
to be caught before the loop:

```v
entries := doc.value_opt('provider') or { return error('catalog contains no providers') }
for entry in entries.array() { ... }
```

Found by a test that expected "catalog contains no providers" and got "provider at index 0 has
no key".

`$embed_file` takes a path relative to the file that contains it:

```v
const embedded_toml = $embed_file('../data/providers.toml')  // from catalog/embedded.v
embedded_toml.to_string()
```

## Structs as named arguments

`@[params]` on a struct lets a call site name the fields, which is what makes `open()` and
`build_query_opts()` readable:

```v
@[params]
pub struct QueryOpts {
pub:
	rd bool = true
}

build_query_opts('google.com', qtype_a, id: 0xbdeb, ad: true)!
transport.open(ip: '127.0.0.1', port: port, timeout: mock_timeout)!
```

Field defaults apply to the fields the caller leaves out.

**An interface method declared under `mut:` needs a mutable receiver**, even when it only
reads. `reusable()` sits under `mut:` in the `Transport` interface, so an array of transports
has to be `mut` before it can be called on an element.

## Optional fields serialize as absent, not as null

`json2.encode` **omits** an `?T` struct field that holds none. It does not emit `null`:

```v
struct Probe {
	n   int
	p50 ?f64
}
json2.encode(Probe{ n: 30, p50: 15.0 })   // {"n":30,"p50":15}
json2.encode(Probe{ n: 0 })               // {"n":0}          <- no p50 key at all
```

`schema/result.schema.json` requires those keys and allows `null` for them, because an absent
key is indistinguishable from a producer that predates the field. So `store/report.v` has to
emit the null explicitly rather than handing an `?f64` to `json2.encode` and hoping.

Reading one back is deliberate at every call site, which is the point:

```v
value := stats.p50 or { return '-' }     // in a fn returning string
assert stats.p50? == 14.0                // in a test declared `fn test_x() ?`
```

`x!` does not unwrap an Option in a function returning a Result: "to propagate a Result, the
call must also return a Result type". Use `?` in a `?`-returning function, or `or {}`.

## rand.new_default frees the seed array you give it

```v
pub fn new_default(config_ config.PRNGConfigStruct) &PRNG {
	mut rng := &wyrand.WyRandRNG{}
	rng.seed(config_.seed_)
	unsafe { config_.seed_.free() }        // vlib/rand/rand.v:34
	return &PRNG(rng)
}
```

It takes ownership. Handing it a caller-owned array, or the same array twice, is a **double
free**, and it surfaces as an intermittent `free(): double free detected in tcache 2` a long
way from the call:

```v
rand.new_default(seed_: spec.seed)          // wrong: spec.seed is freed under the caller
rand.new_default(seed_: spec.seed.clone())  // right
```

Found by a scheduler test that built two plans from one spec to compare them. It passed roughly
two runs in three, which is the worst way for a bug like this to behave.

An instance PRNG is what makes a seeded shuffle reproducible without disturbing the global
generator that the rest of the process uses:

```v
mut rng := rand.new_default(seed_: [u32(0x5eed), u32(0xd0d0)])
order := rng.shuffle_clone(keys)!
```

## Timeouts are per read, not per call

`set_read_timeout` arms a deadline for each individual `read`, and it is re-armed every time.
A loop that reads several times gives the caller a budget of `n x timeout`, not `timeout`. Any
retry or discard loop has to track its own elapsed time against the caller's budget; see
`UdpTransport.query`.

## Module layout and imports

With `v.mod` at the repository root declaring `name: 'dnsbench'`, a subdirectory module is
imported by its **directory name alone**, not by a `dnsbench.` prefix:

```v
import core      // works
import dnsbench.core
// builder error: cannot import module "dnsbench.core" (not found)
```

The prefixed form is what the module name suggests and it does not resolve. Verified by
compiling both.

## Testing

Test files live beside the code as `*_test.v` with the same `module` line, so they reach
unexported functions directly.

`@VMODROOT` expands to the directory holding `v.mod`, which is how a test finds a fixture no
matter where it was invoked from:

```v
import os

fn capture(name string) ![]u8 {
	return os.read_bytes(os.join_path(@VMODROOT, 'testdata', name))!
}
```

A test function may return `!`, so a fixture that fails to load fails the test rather than
needing an `or {}` at every call.

**Asserting that a call fails, and fails for the right reason.** An if-guard binds `err` in its
`else` branch:

```v
if _ := build_query_opts('google..com', qtype_a) {
	assert false
} else {
	assert err.msg().contains('empty label')
}
```

Without the `else`, `v -stats test` reports the function as `NO asserts`: it still fails if the
call unexpectedly succeeds, but it accepts a failure for any reason at all, including a typo in
the test.

## Tooling

**`v fmt` is not idempotent on an `assert` carrying an end-of-line comment.** It inserts a
blank line after the statement, and `v fmt -verify` then still reports the file as unformatted,
so the file can never be made to pass. Put the comment on its own line above the assert.

This matters because `v fmt -verify` is what CI runs and what `make check` runs, so the file
would fail the build with no way to fix it by reformatting.

```sh
v fmt -verify core/     # what CI runs; make fmt rewrites and can never fail
v vet core/
v -stats test core/     # per-test names and assert counts
```

## SIGPIPE kills a network run with no output

V does not mask `SIGPIPE`, and neither does the TLS layer under `net.ssl`. Writing to a socket
whose peer has already closed it therefore terminates the process on the spot, with exit status
141 and nothing printed, rather than returning an error the caller can handle.

This is not theoretical for this tool. `dot_warm` holds one TLS connection per provider open
across the whole interleaved plan, so each connection sits idle while every other provider
takes its turn, and a DoT server is free to close an idle connection. The first run of the DoT
probe against three providers died this way part-way through, having printed nothing at all.

```v
// in main(), before anything opens a socket
os.signal_ignore(.pipe)
```

With that in place the write returns an error, which the transport already reports, and the
caller can reconnect. `os.signal_ignore` is variadic and takes `os.Signal` values, from
`vlib/os/signal.c.v`.

## net.dial_tcp has no connect timeout on the default build

`net.dial_tcp` performs a blocking `connect(2)`. The non-blocking path with a five-second
deadline exists in `vlib/net/tcp.c.v` but is behind `$if net_nonblocking_sockets ?`, which is
not enabled by default, so on an ordinary build the only bound is the operating system's, which
on Linux is over two minutes.

There is no public API to supply one: `TcpSocket.connect` is module-private, so a caller cannot
drive the non-blocking sequence itself. `core/transport.v` runs the connect on its own thread
and waits on a channel with a `select` deadline instead. The abandoned thread ends on its own
when the kernel gives up.

## term.ui panics when there is no TTY

`Context.run()` calls `termios_setup()` and unwraps the result with `or { panic(err) }`, so a
program that starts the interface with stdin or stdout redirected dies with

```
V panic: not running under a TTY
```

rather than returning an error the caller could fall back from. The check has to happen before
`run()` is reached. `os.is_atty` returns an `int`, not a `bool`:

```v
if os.is_atty(0) == 0 || os.is_atty(1) == 0 {
	// fall back to the non-interactive output
}
```

## term.ui installs handlers for every signal in Config.reset

The default is

```v
reset []os.Signal = [.hup, .int, .quit, .ill, .abrt, .bus, .fpe, .kill, .segv, .pipe, .alrm,
	.term, .stop]
```

and each one gets a handler that restores the terminal and calls `exit(0)`. `.pipe` is in that
list, so accepting the default silently undoes an earlier `os.signal_ignore(.pipe)` and puts
back the mid-run kill described above. Pass an explicit list without it.

Uppercase letters arrive as the lowercase `KeyCode` with the shift modifier set, not as a
separate code: `'S'` is `code: .s, modifiers: .shift, ascii: 83`.

## Channels have non-blocking forms

```v
mut value := Frame{}
state := ch.try_pop(mut value) // ChanState.success, .not_ready or .closed
ch.try_push(value)
```

Both return `ChanState`, both return immediately. `try_pop` takes its destination as `mut`.

## Format verbs take no sign flag and no computed width

`'${v:+6.1f}'` does not print a leading `+` for a positive number; it prints the verb
uninterpreted. `'${text:${width}s}'` does not compile. A column whose width lives in a table
has to be padded by hand.

## v fmt rewrites two forms into ones that do not compile

Both were hit while writing `cmd/`, and both are silent: the file still formats, and the next
compile fails somewhere the edit did not happen.

- A multi-value `return match { ... }` whose arm is long enough to wrap becomes a block, and
  the tuple turns into three statements with no return. Write the multi-value returns as `if`
  statements instead.
- `s#[..-1]`, the relative-slice form, is rewritten to `s[..-1]`, which is a compile error.
  Use `s.substr(0, s.len - 1)`.

## A module split across files needs the directory, not a file

`v -o dnsbench cmd/cli.v` compiles that one file and nothing else in `cmd/`, so the moment the
frontend grew a second file the build had to become `v -o dnsbench cmd/`. There is no error to
notice: the missing symbols are simply reported as unknown functions.

## $embed_file records an absolute path

`$embed_file('data/providers.toml')` compiles to a struct holding the file's
**absolute** path alongside its bytes:

```c
string _str_918 = {"/home/esli/GIT/DNSbench/data/providers.toml", 43, 1};
```

The path is never used at runtime, the bytes are already in the binary, but it
means the same source built in two different directories produces two different
binaries. Everything else about a `-prod` build is deterministic: two builds in
the same directory, with the same compiler and the same `-d` defines, are
byte-identical before and after `strip`.

So a reproducible release has to fix the build path, not only the toolchain.
`docs/RELEASING.md` § Reproducibility does that at `/build/dnsbench`.

## Compile-time defines reach the binary through $d()

```v
const tool_version = $d('version', '0.1.0')
```

Set with `-d version=0.1.0` on the command line. The second argument is the value
used when the flag is absent, so a plain `v -o dnsbench cmd/` still builds
outside a checkout. This is how the version and the commit are stamped without
rewriting a file to make a release.
