# Data sources

Two datasets drive the tool: **who** to test (providers) and **what** to ask them (domains).
Both follow the same rule: shipped in the binary, versioned, refreshable only on demand.

## Precedence

```
--provider / --only flags
  > ~/.config/dnsbench/providers.toml      user overrides, merged by key
    > $XDG_CACHE_HOME/dnsbench/*.md        optional DNSCrypt catalog, minisign-verified
      > embedded data/providers.toml       curated default, compiled in
```

Later layers never delete earlier entries; they merge by `key`.

## Provider catalog

### Layer 1 — embedded, curated

`data/providers.toml`, embedded via `$embed_file`. ~16 entries. This is the default and it
works with no network, no config and no update.

Inclusion criteria, in order:

1. Publicly documented, stable endpoints.
2. Anycast or geo-steered — a single-PoP resolver produces meaningless global comparisons.
3. Meets the Privacy Guides baseline where applicable: DNSSEC, QNAME minimisation, ECS
   anonymised or disabled, no personal data logged to disk.
4. Represents a distinct trade-off. Two resolvers with identical behaviour add noise, not
   information.

Deliberately included despite failing (3): `google`, `opendns`. They are the ECS reference
implementations and excluding them would remove the best baseline for the edge probe. They
carry no `nolog` tag and the table shows that.

### Layer 2 — DNSCrypt public-resolvers (opt-in)

An authoritative, actively maintained, cryptographically signed catalog already exists:

```toml
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
  'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md',
  'https://cdn.jsdelivr.net/gh/DNSCrypt/dnscrypt-resolvers@master/v3/public-resolvers.md',
]
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
```

Hundreds of resolvers, each as a `sdns://` DNS Stamp encoding protocol, address, hostname and
capability flags. The stamp parser is ~80 lines and gives us protocol, IPv4/IPv6, hostname,
path, and the `dnssec` / `nolog` / `nofilter` properties for free.

**It is not the default, and that is deliberate.** The list's own header warns that it includes
servers which may censor content, servers which do not validate DNSSEC, and servers which will
collect and monetise queries. Ranking four hundred arbitrary resolvers by latency and crowning
a winner is irresponsible when the winner may be selling the user's queries.

```sh
dnsbench update                                     # fetch + verify + cache
dnsbench --catalog dnscrypt                         # opt in explicitly
dnsbench --catalog dnscrypt --require nolog,dnssec,nofilter
dnsbench --catalog dnscrypt --near                  # pre-filter by a fast reachability pass
```

`--near` matters at this scale: probing 400 resolvers fully takes too long and is impolite.
It runs a single low-rate reachability pass and keeps the fastest N (default 25) for the full
battery.

Verification is mandatory. If minisign fails, the cache is discarded and the tool falls back
to the embedded catalog with a warning. There is no `--insecure`.

### Layer 3 — user overrides

`~/.config/dnsbench/providers.toml`, same schema, merged by key. Adding your company's
internal resolver or your own unbound instance is one file.

### Schema

```toml
version = 3
generated = "2026-08-28"

[[provider]]
key      = "quad9-ecs"              # stable identifier, used in --only and in JSON
label    = "Quad9 (ECS)"            # display name
udp4     = ["9.9.9.11", "149.112.112.11"]
udp6     = ["2620:fe::11", "2620:fe::fe:11"]
dot      = "dns11.quad9.net"        # TLS verification hostname
doh      = "https://dns11.quad9.net/dns-query"
tags     = ["dnssec", "ecs", "malware", "nolog", "nofilter"]
homepage = "https://quad9.net"
notes    = "ECS-enabled variant; prefer over 9.9.9.9 where CDN performance matters"
```

Tag vocabulary — closed set, validated at load:

| Tag | Meaning | Verified? |
|---|---|---|
| `dnssec` | Claims DNSSEC validation | ✓ probed |
| `ecs` | Claims ECS support | ✓ inferred from edge probe |
| `nolog` | Claims no query logging | ✗ declared |
| `nofilter` | Claims no content manipulation | ✗ declared |
| `audited` | Published independent audit | ✗ declared |
| `malware` / `ads` / `family` | Filtering categories | ✓ probed |
| `nonprofit` | Non-profit operator | ✗ declared |
| `configurable` | Filtering is set by the user's own profile, not by the operator | ✗ declared |

The `Verified?` column is enforced in code, not by review: `catalog/model.v` partitions the
vocabulary into `measured` and `declared`, `parse` rejects any tag outside it, and a scorer
reaching a declared tag has to ask for it by that name.

`configurable` was in use by `nextdns` and both Control D entries before it was written down
here. It is declared: what such a resolver filters depends on a profile the tool cannot see.

`nofilter` is declared, not probed. The `filter` probe can *contradict* the claim by finding a
domain the resolver blocks, but no probe establishes that a resolver manipulates nothing
anywhere, and `nofilter` carries a weight inside `privacy`, which docs/SCORING.md defines as
declared and never measured. An earlier revision of this table called it "partially probed",
and the code followed the table.

### Adding a provider

Pull request against `data/providers.toml`, plus a CHANGELOG line. Requirements: public
documentation URL for every endpoint, and a one-line justification of the distinct trade-off
it represents. See CONTRIBUTING.md.

## Domain sets

One "top domains" list cannot serve every probe. Each probe needs a different property.

| Set | Source | Required property |
|---|---|---|
| `warm` | Tranco, pinned ID, top 25 | Popular, stable across runs, certainly cached |
| `cold` | Random label under a controlled wildcard zone | Never cached, real recursion |
| `ecs` | Hand-curated multi-PoP CDN hosts | Many edges, geographically distributed |
| `regional` | Tranco ccTLD filter + manual curation | Traffic the user actually generates |

### Tranco, pinned

Tranco is a one-million-domain ranking averaged over the previous 30 days across four
underlying rankings, built explicitly for reproducibility with permanent citable IDs. It
exists because dozens of published studies relied on rankings that were trivially manipulable
and undated.

**Pin the ID. Do not fetch the latest.**

```
# data/domains/global.txt
# tranco:K2XVW  retrieved 2026-08-15  top 25, no filter
google.com
youtube.com
...
```

If the dataset moves, June's results stop being comparable to August's and the `history`
feature becomes noise. Bumping the ID is a release decision with a CHANGELOG entry, and every
result carries `domains: "tranco:K2XVW+sa"`.

### Regional sets, built at release time

Tranco supports filtered and custom lists via its API. We generate them **once, offline, at
release**, never at runtime:

```
data/domains/
├── global.txt     top 25, unfiltered
├── sa.txt         .br .ar .cl .co ccTLD filter + manual curation
├── na.txt
├── eu.txt
├── apac.txt
├── af.txt
└── me.txt
```

25 domains × 7 regions = 175 lines. Negligible size, zero runtime network.

**ccTLD is not the same as regional popularity.** `google.com` and `youtube.com` dominate
Brazilian traffic and carry no `.br`. Therefore a regional run is always `global + regional`,
never regional alone, and manual curation (globo.com, uol.com.br, mercadolivre.com.br,
nubank.com.br) supplements the automatic filter.

```toml
[domains]
sets = ["global", "auto"]   # auto resolves to the detected region
```

### CDN hosts for the edge probe

Curated, embedded, health-checked. Global multi-PoP CDNs only — this is correctness, not
convenience. A two-PoP CDN cannot expose a bad ECS decision; a several-hundred-edge CDN can.

```toml
[[cdn_host]]
host = "www.microsoft.com"
cdn  = "akamai"
expect_cname_suffix = "akadns.net"

[[cdn_host]]
host = "cdn.jsdelivr.net"
cdn  = "multi"
expect_cname_suffix = ""
```

CDN hostnames rot — companies get acquired, hostnames disappear. Each entry is health-checked
at run start: if it fails to resolve, or the expected CNAME suffix is gone, it is marked
`stale`, excluded from scoring, and reported. Better a visible gap than a silently wrong
number.

Regional CDN hosts are an optional realism supplement (`--ecs-set global,regional`) and never
affect the score.

### Cold-probe zone

The project operates `probe.dnsbench.esli.blog` as a delegated subzone of `esli.blog`, with a
wildcard A record pointing at `192.0.2.1` (TEST-NET-1, RFC 5737, deliberately unroutable) and a
60 s TTL. The zone is DNSSEC-signed: a tool that scores resolvers on DNSSEC validation cannot
ship an unsigned reference zone. Every
resolver recurses to the same authoritative server with the same TTL — a clean comparison with
no NXDOMAIN collateral against third parties.

### Setting the zone up

What has to exist before `--probes cold` measures anything. Two zones are involved: the parent
`esli.blog`, which delegates, and the child `dnsbench.esli.blog`, which answers.

**1. In the parent zone `esli.blog`**, delegate the child and, if the child is signed, publish
its DS record:

```
dnsbench          IN  NS   ns1.<provider>.
dnsbench          IN  NS   ns2.<provider>.
dnsbench          IN  DS   <keytag> <alg> <digest-type> <digest>
```

The delegation is the isolation. A mistake inside the child, a nameserver migration, or an
unexpected volume spike stops here and never reaches the records that serve the site.

**2. In the child zone `dnsbench.esli.blog`**, one wildcard is the whole payload:

```
$TTL 3600
@                 IN  SOA  ns1.<provider>. hostmaster.esli.blog. (
                           2026082801   ; serial
                           7200         ; refresh
                           3600         ; retry
                           1209600      ; expire
                           3600 )       ; negative cache TTL
@                 IN  NS   ns1.<provider>.
@                 IN  NS   ns2.<provider>.

*.probe      60   IN  A    192.0.2.1
*.probe      60   IN  AAAA 2001:db8::1
```

The TTL of **60** on the wildcard is not decoration: it is what every resolver caches the
answer for, and it travels in the comparison. Changing it changes the measurement, so treat it
as a released constant rather than a knob.

`192.0.2.1` is TEST-NET-1 and `2001:db8::1` is the documentation prefix, both RFC-reserved and
unroutable. Nothing connects to them by accident, which is the point: the probe measures the
lookup and must never become a connection test.

**3. Sign the child zone.** A tool that scores resolvers on DNSSEC validation cannot ship an
unsigned reference zone. Most managed providers sign with one switch.

**4. Verify before trusting it.** In order, because each step depends on the one above:

```sh
# the delegation exists in the parent
kdig +norec NS dnsbench.esli.blog @ns1.<parent-provider>

# the child answers a name nobody has ever asked for
kdig +short A $(openssl rand -hex 8).probe.dnsbench.esli.blog

# a public resolver recurses to it, and the TTL comes back as 60
kdig A $(openssl rand -hex 8).probe.dnsbench.esli.blog @1.1.1.1

# the DNSSEC chain validates from the root
delv A $(openssl rand -hex 8).probe.dnsbench.esli.blog
```

The third command is the one that matters. If the TTL comes back as anything but 60, or the
answer is not `192.0.2.1`, the cold probe is measuring something other than what this document
describes.

**5. Then run it:**

```sh
dnsbench --probes warm,cold --cold-zone probe.dnsbench.esli.blog
```

### What this commits the operator to

Running the reference zone is an infrastructure commitment, and it is worth being explicit
about its shape before taking it on.

**Every cold query is a cache miss, by construction.** The label is random per query, so none
of this traffic is ever absorbed by a resolver's cache: all of it arrives at the authoritative
servers. One default run is `rounds x domains` queries per provider; sixteen providers at forty
samples is roughly 640 queries per user per run. On a managed provider that bills per query,
that is the line item to watch, and it grows with adoption rather than with usage by any one
person.

**A wildcard plus DNSSEC is not universally supported.** Some managed providers handle wildcard
records poorly once the zone is signed, or refuse the combination outright. Verify step 4 rather
than assuming.

**If the zone goes down, `cold` degrades to `wild` with a warning and never silently produces
wrong numbers.** That is the contract; it is also why the zone's availability is a published
promise rather than a private detail.

The zone is configurable so an operator can point at their own:

```toml
[domains.cold]
mode = "own"                         # own | wild | off
zone = "probe.dnsbench.esli.blog"
```

Running the reference zone is an infrastructure commitment the project must own. If it goes
down, `cold` degrades to `wild` with a warning; it never silently produces wrong numbers.
