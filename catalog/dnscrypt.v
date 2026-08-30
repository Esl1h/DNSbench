module catalog

// The DNSCrypt public-resolvers list.
//
// An authoritative, actively maintained, cryptographically signed catalog of
// several hundred resolvers already exists, and this is where it is fetched
// from. It is **not** the default and never becomes one: its own header warns
// that it lists servers which censor, which do not validate DNSSEC, and which
// collect and monetise queries. Ranking four hundred arbitrary resolvers by
// latency and crowning a winner is irresponsible when the winner may be selling
// the user's queries. docs/DATA.md § Layer 2.
//
// The sdns:// stamp parser that turns this file into providers lands here next.
// `dnsbench update` fetches and verifies it; nothing reads the cache yet.

// dnscrypt_sources are tried in order. Three mirrors of the same file, so a
// single unreachable host is not a failed update.
pub const dnscrypt_sources = [
	'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
	'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md',
	'https://cdn.jsdelivr.net/gh/DNSCrypt/dnscrypt-resolvers@master/v3/public-resolvers.md',
]

// dnscrypt_minisign_key is the list's published public key. It is embedded
// rather than fetched, because a key downloaded beside the thing it signs
// verifies nothing.
pub const dnscrypt_minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'

// dnscrypt_cache_name is what the verified file is called on disk.
pub const dnscrypt_cache_name = 'public-resolvers.md'
