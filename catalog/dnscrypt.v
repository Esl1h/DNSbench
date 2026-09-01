module catalog

import encoding.base64

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
// `dnsbench update` fetches and verifies the file; this is what reads it. The
// format is one `## key` heading per resolver followed by free-text prose and
// one or more `sdns://` DNS Stamps: https://dnscrypt.info/stamps-specifications.
//
// A stamp is `base64url( protocol[1] || props[8] || protocol-specific )`. Only
// two protocol bytes appear anywhere in the current list, checked against a
// full fetch of the real file on 2026-09-01: 877 stamps, all either 0x01 or
// 0x02, but the parser does not assume that stays true.

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

// StampProtocol is the byte a stamp opens with. `unsupported` covers every
// value this tool has no transport for, DoT and DoQ stamps included, so a
// future addition to the list degrades to a skipped entry instead of an error.
pub enum StampProtocol {
	dnscrypt // 0x01, no transport in this tool speaks it; see providers_from_entries
	doh // 0x02
	unsupported
}

pub struct Stamp {
pub:
	protocol StampProtocol
	// address is exactly what the stamp names: "ip", "[ipv6]", "ip:port" or
	// "[ipv6]:port", or empty when the stamp asks the client to resolve
	// hostname itself. Never dialled directly; see split_stamp_address.
	address  string
	hostname string // TLS/SNI hostname for doh; provider name for dnscrypt
	path     string // DoH request path; empty for dnscrypt
	dnssec   bool
	nolog    bool
	nofilter bool
}

// read_lp reads one length-prefixed field: a length byte, whose top bit marks
// whether another field of the same kind follows, then that many octets.
fn read_lp(b []u8, offset int) !([]u8, int, bool) {
	if offset >= b.len {
		return error('stamp is truncated: expected a length byte at offset ${offset}')
	}
	raw_len := b[offset]
	more := raw_len & 0x80 != 0
	n := int(raw_len & 0x7f)
	start := offset + 1
	end := start + n
	if end > b.len {
		return error('stamp is truncated: a ${n}-octet field at offset ${start} runs past the end')
	}
	return b[start..end], end, more
}

// read_lp_set reads a run of length-prefixed fields, such as the hash pins on
// a DoH stamp or the public keys on a DNSCrypt one. The values themselves are
// not needed for anything this tool measures, so only the end offset matters.
fn skip_lp_set(b []u8, offset int) !int {
	mut i := offset
	mut more := true
	for more {
		_, next, cont := read_lp(b, i)!
		i = next
		more = cont
	}
	return i
}

// parse_stamp decodes one `sdns://` DNS Stamp.
//
// The hash and public-key sets carry pinning material this tool has no use
// for: providers are dialled by IP literal and the TLS chain is verified
// against the system trust store, not against a pin shipped by a third-party
// list. They are still walked, never skipped, because skipping them would
// misread every field that follows.
pub fn parse_stamp(raw string) !Stamp {
	prefix := 'sdns://'
	if !raw.starts_with(prefix) {
		return error('"${raw}" does not start with "${prefix}"')
	}

	blob := base64.url_decode(raw[prefix.len..])
	if blob.len < 9 {
		return error('stamp decodes to ${blob.len} octets, shorter than the 9-octet protocol and properties header')
	}

	protocol_byte := blob[0]
	mut props := u64(0)
	for k in 0 .. 8 {
		props |= u64(blob[1 + k]) << (8 * k)
	}
	dnssec := props & 0x01 != 0
	nolog := props & 0x02 != 0
	nofilter := props & 0x04 != 0

	address, after_addr, _ := read_lp(blob, 9)!

	match protocol_byte {
		0x02 {
			after_hashes := skip_lp_set(blob, after_addr)!
			hostname, after_host, _ := read_lp(blob, after_hashes)!
			path, _, _ := read_lp(blob, after_host)!
			return Stamp{
				protocol: .doh
				address: address.bytestr()
				hostname: hostname.bytestr()
				path: path.bytestr()
				dnssec: dnssec
				nolog: nolog
				nofilter: nofilter
			}
		}
		0x01 {
			after_keys := skip_lp_set(blob, after_addr)!
			provider_name, _, _ := read_lp(blob, after_keys)!
			return Stamp{
				protocol: .dnscrypt
				address: address.bytestr()
				hostname: provider_name.bytestr()
				dnssec: dnssec
				nolog: nolog
				nofilter: nofilter
			}
		}
		else {
			return Stamp{
				protocol: .unsupported
				dnssec: dnssec
				nolog: nolog
				nofilter: nofilter
			}
		}
	}
}

// DnscryptEntry is one `## key` section: a resolver name and every stamp
// listed under it. A section commonly carries more than one stamp, either
// redundant addresses for the same service or an IPv4/IPv6 pair.
pub struct DnscryptEntry {
pub:
	key    string
	stamps []Stamp
}

pub struct DnscryptParseResult {
pub:
	entries []DnscryptEntry
	// skipped names every stamp that failed to decode, by section. A malformed
	// stamp in a list this size is a fact about one entry, not the file.
	skipped []string
}

// parse_resolvers_md reads the file `dnsbench update` cached: one `## key`
// heading per resolver, free-text prose, then one or more `sdns://` lines.
// Nothing before the first heading is a resolver, so it is skipped rather
// than parsed.
pub fn parse_resolvers_md(text string) DnscryptParseResult {
	lines := text.split_into_lines()
	mut entries := []DnscryptEntry{}
	mut skipped := []string{}
	mut i := 0
	for i < lines.len {
		if !lines[i].starts_with('## ') {
			i++
			continue
		}
		key := lines[i][3..].trim_space()
		i++
		mut stamps := []Stamp{}
		for i < lines.len && !lines[i].starts_with('## ') {
			trimmed := lines[i].trim_space()
			i++
			if !trimmed.starts_with('sdns://') {
				continue
			}
			stamp := parse_stamp(trimmed) or {
				skipped << '${key}: ${err.msg()}'
				continue
			}
			stamps << stamp
		}
		if stamps.len > 0 {
			entries << DnscryptEntry{
				key: key
				stamps: stamps
			}
		}
	}
	return DnscryptParseResult{
		entries: entries
		skipped: skipped
	}
}

// split_stamp_address separates a stamp address into the bare literal
// catalog.Provider stores and the port, if any. IPv6 literals are bracketed
// in the stamp format; the brackets are not part of the literal itself.
fn split_stamp_address(addr string) (string, string) {
	if addr.starts_with('[') {
		bracket := addr.index(']') or { return addr, '' }
		host := addr[1..bracket]
		rest := addr[bracket + 1..]
		port := if rest.starts_with(':') { rest[1..] } else { '' }
		return host, port
	}
	if addr.count(':') == 1 {
		parts := addr.split(':')
		return parts[0], parts[1]
	}
	return addr, ''
}

// label_from_key turns a list key such as "cloudflare-security" into
// "Cloudflare Security". The list carries no separate display name, so this
// is a mechanical fallback rather than a curated label.
fn label_from_key(key string) string {
	return key.split('-').map(it.capitalize()).join(' ')
}

// dnscrypt_source_page is carried as `homepage` for every provider this file
// produces: there is no per-resolver homepage in the list's format, only free
// text, and this is where the entry actually came from.
const dnscrypt_source_page = 'https://github.com/DNSCrypt/dnscrypt-resolvers'

// providers_from_entries turns parsed sections into providers.
//
// Only DoH stamps become providers. A DNSCrypt-protocol stamp names an
// address this tool has no transport for, and a stamp with no address asks
// the client to resolve a hostname itself, which every probe in this tool
// refuses to do mid-run: docs/METHODOLOGY.md § Fairness rules. Both are
// reported in the second return value rather than silently dropped.
//
// The address is carried as `dot4` / `dot6`, not `udp4` / `udp6`. Nothing
// here establishes that the same machine also answers plain UDP on port 53,
// the assumption `udp4` carries for the embedded catalog's hand-verified
// entries; `dot4` is exactly the field docs/DATA.md defines for an address
// that is known to speak an encrypted protocol and nothing else.
pub fn providers_from_entries(entries []DnscryptEntry) ([]Provider, []string) {
	mut providers := []Provider{}
	mut skipped := []string{}
	for entry in entries {
		mut dot4 := []string{}
		mut dot6 := []string{}
		mut doh := ''
		mut has_dnssec := false
		mut has_nolog := false
		mut has_nofilter := false
		for stamp in entry.stamps {
			if stamp.protocol == .dnscrypt {
				skipped << '${entry.key}: DNSCrypt-protocol stamp, no transport in this tool speaks it'
				continue
			}
			if stamp.protocol == .unsupported {
				skipped << '${entry.key}: stamp uses an unrecognised protocol'
				continue
			}
			if stamp.address == '' {
				skipped << '${entry.key}: stamp names no address, endpoints here are always dialled by IP literal'
				continue
			}
			host, port := split_stamp_address(stamp.address)
			if port != '' {
				skipped << '${entry.key}: stamp asks for port ${port}, which the provider schema has no field for'
				continue
			}
			if host.contains(':') {
				dot6 << host
			} else {
				dot4 << host
			}
			if doh == '' {
				doh = 'https://${stamp.hostname}${stamp.path}'
			}
			has_dnssec = has_dnssec || stamp.dnssec
			has_nolog = has_nolog || stamp.nolog
			has_nofilter = has_nofilter || stamp.nofilter
		}
		if doh == '' {
			continue
		}
		mut tags := []string{}
		if has_dnssec {
			tags << 'dnssec'
		}
		if has_nolog {
			tags << 'nolog'
		}
		if has_nofilter {
			tags << 'nofilter'
		}
		providers << Provider{
			key: entry.key
			label: label_from_key(entry.key)
			dot4: dot4
			dot6: dot6
			doh: doh
			tags: tags
			homepage: dnscrypt_source_page
			notes: 'sourced from the DNSCrypt public-resolvers list'
		}
	}
	return providers, skipped
}
