# public-resolvers (excerpt)

Real sections copied verbatim from the DNSCrypt project's `public-resolvers.md`
(https://github.com/DNSCrypt/dnscrypt-resolvers), fetched 2026-09-01. Chosen to
cover the stamp shapes the parser has to handle: two addresses under one key,
IPv6, a multi-hash pin set, an empty address (system-resolved, unusable here),
and a DNSCrypt-protocol entry with a non-default port (unusable here).

Never hand-edit the `sdns://` lines below; if a case is missing, copy another
real one in rather than constructing bytes by hand.

## a-and-a

Andrews & Arnold non-filtering resolver.
No logging, DNSSEC validation. Homepage: https://www.aa.net.uk/dns/
Operated by Andrews & Arnold. Service page: https://www.aa.net.uk/dns/

sdns://AgcAAAAAAAAADTIxNy4xNjkuMjAuMjIADWRucy5hYS5uZXQudWsKL2Rucy1xdWVyeQ
sdns://AgcAAAAAAAAADTIxNy4xNjkuMjAuMjMADWRucy5hYS5uZXQudWsKL2Rucy1xdWVyeQ


## a-and-a-ipv6

Andrews & Arnold non-filtering resolver.
IPv6 endpoint. No logging, DNSSEC validation. Homepage: https://www.aa.net.uk/dns/
Operated by Andrews & Arnold. Service page: https://www.aa.net.uk/dns/

sdns://AgcAAAAAAAAAEFsyMDAxOjhiMDo6MjAyMl0ADWRucy5hYS5uZXQudWsKL2Rucy1xdWVyeQ
sdns://AgcAAAAAAAAAEFsyMDAxOjhiMDo6MjAyM10ADWRucy5hYS5uZXQudWsKL2Rucy1xdWVyeQ


## cipherdns-ct1-doh-za

CipherDNS Cape Town privacy resolver.
Based in Cape Town, South Africa. Zero logging, DNSSEC validation, unfiltered raw resolution.

sdns://AgcAAAAAAAAADjEwMi4yMDkuMjEuMTc2oP_qvxWZFJ9BK1V6rOVWoUSdlRS9JwllVzJr6hoRRXifINqSeh5K4YpnPElAq-H8Z9W88gNANHsHDKWZn1t_0K1ID2NpcGhlcmRucy5jby56YQovZG5zLXF1ZXJ5


## dnshome-de

dnsHome.de public resolver in Germany.
No logging, no filtering, supports DNSSEC. Maintained by dnsHome.de.
Homepage: https://dnshome.de/

sdns://AgcAAAAAAAAAACAy7bsRzCWPvjPCzSShSScPC-b0RvVyZLO9HCW5hTMnLg5kbnMuZG5zaG9tZS5kZQovZG5zLXF1ZXJ5


## doh-cleanbrowsing-adult

CleanBrowsing Adult Filter.
Blocks adult, pornographic and explicit sites. Allows proxy and VPN domains and mixed-content sites. Google and Bing are set to Safe Mode.

Operated by CleanBrowsing. Service page: https://cleanbrowsing.org/filters/

sdns://AgMAAAAAAAAAAAAVZG9oLmNsZWFuYnJvd3Npbmcub3JnEi9kb2gvYWR1bHQtZmlsdGVyLw


## adguard-dns

AdGuard DNS Default public resolver.
Blocks ads, trackers, phishing and malicious domains.

Operated by AdGuard. Service page: https://adguard-dns.io/en/public-dns.html
Warning: This server is incompatible with anonymization.

sdns://AQMAAAAAAAAAETk0LjE0MC4xNC4xNDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20
sdns://AQMAAAAAAAAAETk0LjE0MC4xNS4xNTo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20


## cloudflare

Cloudflare 1.1.1.1 public resolver.
Global anycast, non-filtering.
Operated by Cloudflare. Service page: https://developers.cloudflare.com/1.1.1.1/

sdns://AgcAAAAAAAAABzEuMC4wLjEAEmRucy5jbG91ZGZsYXJlLmNvbQovZG5zLXF1ZXJ5
sdns://AgcAAAAAAAAABzEuMC4wLjEABzEuMC4wLjEKL2Rucy1xdWVyeQ
sdns://AgcAAAAAAAAADDE2Mi4xNTkuMzYuMQAMMTYyLjE1OS4zNi4xCi9kbnMtcXVlcnk
sdns://AgcAAAAAAAAADDE2Mi4xNTkuNDYuMQAMMTYyLjE1OS40Ni4xCi9kbnMtcXVlcnk
sdns://AgcAAAAAAAAADjEwNC4xNi4xMzIuMjI5ABJkbnMuY2xvdWRmbGFyZS5jb20KL2Rucy1xdWVyeQ
sdns://AgcAAAAAAAAADjEwNC4xNi4xMzMuMjI5ABJkbnMuY2xvdWRmbGFyZS5jb20KL2Rucy1xdWVyeQ
sdns://AgcAAAAAAAAADjEwNC4xNi4yNDkuMjQ5ABJjbG91ZGZsYXJlLWRucy5jb20KL2Rucy1xdWVyeQ
sdns://AgcAAAAAAAAADjEwNC4xNi4yNDguMjQ5ABJjbG91ZGZsYXJlLWRucy5jb20KL2Rucy1xdWVyeQ
