module catalog

import toml

// The provider catalog: who to test, and what they claim about themselves.
//
// The one rule this module exists to enforce is the separation in CLAUDE.md § 5.
// A tag is either something the tool can probe or something the provider merely
// asserts, and the two must not be mixed. Making that a property of the
// vocabulary rather than a convention means a scorer cannot reach a declared tag
// without asking for it by name.
pub enum TagKind {
	// measured tags are confirmed, or contradicted, by a probe during the run.
	measured
	// declared tags come from the provider's own statements. The tool cannot
	// verify them and never claims to. See docs/SCORING.md § privacy.
	declared
}

// tag_vocabulary is closed. A catalog carrying anything else fails to load
// rather than silently contributing an unrecognised flag to the output.
// See docs/DATA.md § Schema.
pub const tag_vocabulary = {
	'dnssec':       TagKind.measured
	'ecs':          TagKind.measured
	'malware':      TagKind.measured
	'ads':          TagKind.measured
	'family':       TagKind.measured
	// nofilter is declared, not measured. The filter probe can contradict it by
	// finding a blocked domain, but no probe can establish that a resolver
	// manipulates nothing anywhere. It feeds the privacy subscore, which
	// docs/SCORING.md defines as declared and never measured.
	'nofilter':     TagKind.declared
	'nolog':        TagKind.declared
	'audited':      TagKind.declared
	'nonprofit':    TagKind.declared
	'configurable': TagKind.declared
}

pub struct Provider {
pub:
	key   string
	label string
	udp4  []string
	udp6  []string
	dot   string // TLS verification hostname, not an address to dial
	// dot4 and dot6 are the addresses to dial for DoT. They exist because a
	// published address is not always a plaintext one: Mullvad's answer REFUSED
	// on port 53 by design and serve DoT on 853 from the same IPs. Empty means
	// the plaintext addresses are also the encrypted ones, which is the norm.
	dot4     []string
	dot6     []string
	doh      string
	tags     []string
	homepage string
	notes    string
	// needs_config marks an entry whose endpoints carry unsubstituted
	// placeholders, such as NextDNS's per-profile addresses. It is not probeable
	// until a profile id is supplied, and probing it as written would measure a
	// hostname that does not exist.
	needs_config bool
}

// CdnHost is one target for the edge probe. The set is curated and embedded
// for the same reason the provider list is: a host resolved at run time is a
// host that can change between two runs the tool claims are comparable.
pub struct CdnHost {
pub:
	host string
	cdn  string
	// expect_cname_suffix is what the answer's CNAME chain has to end in for the
	// entry to still be measuring the CDN it was chosen for. Empty means the
	// host answers with addresses directly and there is no chain to check.
	expect_cname_suffix string
}

pub struct Catalog {
pub:
	version   int
	generated string
	providers []Provider
	cdn_hosts []CdnHost
}

// declared returns the tags this provider asserts about itself and that no
// probe can confirm. They render in a distinct style and carry a disclaimer.
pub fn (p Provider) declared() []string {
	return p.tags.filter(tag_vocabulary[it] or { TagKind.measured } == .declared)
}

// measured returns the tags a probe can confirm or contradict during a run.
// A tag being here means the claim is checkable, not that it has been checked.
pub fn (p Provider) measured() []string {
	return p.tags.filter(tag_vocabulary[it] or { TagKind.declared } == .measured)
}

// has_endpoint reports whether there is anything at all to probe.
pub fn (p Provider) has_endpoint() bool {
	return p.udp4.len > 0 || p.udp6.len > 0 || p.dot != '' || p.doh != ''
}

// doh_host and doh_path split the DoH URL into the name the certificate is
// verified against and the request target.
//
// The URL is never handed to an HTTP client to resolve: that would put a lookup
// inside every sample, through a resolver that may itself be under test.
pub fn (p Provider) doh_host() string {
	if !p.doh.starts_with('https://') {
		return ''
	}
	rest := p.doh['https://'.len..]
	return rest.all_before('/')
}

pub fn (p Provider) doh_path() string {
	host := p.doh_host()
	if host == '' {
		return ''
	}
	rest := p.doh['https://'.len + host.len..]
	return if rest == '' { '/' } else { rest }
}

// doh_address is the address to dial for DoH. The encrypted endpoints share an
// address everywhere in this catalog, so it follows the DoT chain.
pub fn (p Provider) doh_address() string {
	if p.doh_host() == '' {
		return ''
	}
	if p.dot4.len > 0 {
		return p.dot4[0]
	}
	if p.udp4.len > 0 {
		return p.udp4[0]
	}
	return ''
}

// dot_address is the address to dial for DoT, or empty when the entry cannot be
// measured over TLS.
//
// It falls back to the plaintext address because for most providers they are
// the same machine on a different port, and repeating the list in the catalog
// would be a second copy to keep in step with the first.
pub fn (p Provider) dot_address() string {
	if p.dot == '' {
		return ''
	}
	if p.dot4.len > 0 {
		return p.dot4[0]
	}
	if p.udp4.len > 0 {
		return p.udp4[0]
	}
	return ''
}

// parse reads a catalog and rejects anything it cannot vouch for.
//
// Validation is strict on purpose. A provider with an unknown tag, a duplicate
// key or no endpoint is a mistake in the data, and a run that quietly skips it
// produces a ranking with a hole in it that nobody notices.
pub fn parse(text string) !Catalog {
	doc := toml.parse_text(text)!

	mut providers := []Provider{}
	mut seen := map[string]bool{}

	// value('provider').array() on a document with no [[provider]] table yields
	// a one-element array holding a null, not an empty one, so a missing table
	// has to be caught before the loop rather than by the count after it.
	entries := doc.value_opt('provider') or { return error('catalog contains no providers') }

	for entry in entries.array() {
		m := entry.as_map()
		key := m['key'] or { toml.Any('') }.string()
		if key == '' {
			return error('provider at index ${providers.len} has no key')
		}
		if key in seen {
			return error('duplicate provider key "${key}"')
		}
		seen[key] = true

		tags := string_list(m, 'tags')
		for tag in tags {
			if tag !in tag_vocabulary {
				return error('provider "${key}" carries tag "${tag}", which is not in the vocabulary')
			}
		}

		// An address field that is not an address would reach dial_udp verbatim.
		// Placeholders are the one legitimate exception and are marked instead.
		needs_config := has_placeholder(m)
		if !needs_config {
			for ip in string_list(m, 'udp4') {
				if !looks_like_ipv4(ip) {
					return error('provider "${key}" has udp4 entry "${ip}", which is not an IPv4 literal')
				}
			}
			for ip in string_list(m, 'dot4') {
				if !looks_like_ipv4(ip) {
					return error('provider "${key}" has dot4 entry "${ip}", which is not an IPv4 literal')
				}
			}
			for ip in string_list(m, 'udp6') {
				if !looks_like_ipv6(ip) {
					return error('provider "${key}" has udp6 entry "${ip}", which is not an IPv6 literal')
				}
			}
		}

		p := Provider{
			key: key
			label: m['label'] or { toml.Any('') }.string()
			udp4: string_list(m, 'udp4')
			udp6: string_list(m, 'udp6')
			dot4: string_list(m, 'dot4')
			dot6: string_list(m, 'dot6')
			dot: m['dot'] or { toml.Any('') }.string()
			doh: m['doh'] or { toml.Any('') }.string()
			tags: tags
			homepage: m['homepage'] or { toml.Any('') }.string()
			notes: m['notes'] or { toml.Any('') }.string()
			needs_config: needs_config
		}
		if p.label == '' {
			return error('provider "${key}" has no label')
		}
		if !p.has_endpoint() {
			return error('provider "${key}" has no endpoint to probe')
		}
		// docs/DATA.md § Adding a provider: every entry cites where its
		// endpoints are published, so a stale one can be re-checked later.
		if p.homepage == '' {
			return error('provider "${key}" has no homepage documenting its endpoints')
		}

		providers << p
	}

	if providers.len == 0 {
		return error('catalog contains no providers')
	}

	mut cdn_hosts := []CdnHost{}
	mut seen_host := map[string]bool{}
	// A catalog with no [[cdn_host]] is legal: the edge probe is then simply not
	// runnable, which the CLI reports rather than treating as a broken catalog.
	if entries_cdn := doc.value_opt('cdn_host') {
		for entry in entries_cdn.array() {
			m := entry.as_map()
			host := m['host'] or { toml.Any('') }.string()
			if host == '' {
				return error('cdn_host at index ${cdn_hosts.len} has no host')
			}
			if seen_host[host] {
				return error('duplicate cdn_host "${host}"')
			}
			seen_host[host] = true
			cdn := m['cdn'] or { toml.Any('') }.string()
			if cdn == '' {
				return error('cdn_host "${host}" does not say which CDN it probes')
			}
			cdn_hosts << CdnHost{
				host: host
				cdn: cdn
				expect_cname_suffix: m['expect_cname_suffix'] or { toml.Any('') }.string()
			}
		}
	}

	return Catalog{
		version: doc.value('version').int()
		generated: doc.value('generated').string()
		providers: providers
		cdn_hosts: cdn_hosts
	}
}

// has_placeholder reports whether any endpoint field still carries a __TOKEN__
// left for a later substitution step.
fn has_placeholder(m map[string]toml.Any) bool {
	for key in ['udp4', 'udp6', 'dot4', 'dot6', 'dot', 'doh'] {
		value := m[key] or { continue }
		if value.string().contains('__') {
			return true
		}
		for item in string_list(m, key) {
			if item.contains('__') {
				return true
			}
		}
	}
	return false
}

fn looks_like_ipv4(s string) bool {
	octets := s.split('.')
	if octets.len != 4 {
		return false
	}
	for octet in octets {
		if octet == '' || octet.len > 3 || octet.int() > 255 {
			return false
		}
		for c in octet {
			if !c.is_digit() {
				return false
			}
		}
	}
	return true
}

fn looks_like_ipv6(s string) bool {
	if !s.contains(':') {
		return false
	}
	for c in s {
		if !(c.is_hex_digit() || c == `:`) {
			return false
		}
	}
	return true
}

fn string_list(m map[string]toml.Any, key string) []string {
	value := m[key] or { return []string{} }
	return value.array().map(it.string())
}
