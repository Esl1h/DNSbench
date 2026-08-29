module catalog

// The embedded catalog is the shipped artefact, so most of these assert against
// it directly rather than against a fixture. If data/providers.toml drifts, the
// build fails here rather than in a run.
fn test_the_embedded_catalog_loads() ! {
	c := embedded()!

	assert c.version == 7
	assert c.generated == '2026-08-29'
	assert c.providers.len == 16
}

// Mullvad publishes 194.242.2.2 and 2a07:e340::2, and its own help page says
// those addresses cannot be used over UDP/53 or TCP/53: the resolver listening
// there answers REFUSED to everything but its own hostnames. The addresses read
// like plaintext endpoints and are not, so the absence is asserted rather than
// left to whoever next copies the block.
fn test_mullvad_carries_no_plaintext_endpoint() ! {
	c := embedded()!

	for p in c.providers {
		if p.key !in ['mullvad', 'mullvad-base'] {
			continue
		}
		assert p.udp4.len == 0
		assert p.udp6.len == 0
		assert p.dot != ''
		assert p.doh != ''
		// The same addresses that refuse on 53 do serve DoT on 853, so they are
		// carried as what they are rather than dropped entirely.
		assert p.dot4.len == 1
		assert p.dot6.len == 1
		assert p.dot_address() == p.dot4[0]
	}
}

fn test_dot_falls_back_to_the_plaintext_address() ! {
	// For most providers the encrypted endpoint is the same machine on another
	// port, and repeating the address in the catalog would be a second copy to
	// keep in step with the first.
	c := embedded()!

	for p in c.providers {
		if p.dot == '' || p.dot4.len > 0 || p.udp4.len == 0 {
			continue
		}
		assert p.dot_address() == p.udp4[0]
	}
}

fn test_a_provider_with_no_dot_hostname_has_no_dot_address() {
	// An address alone is not a DoT endpoint: without a name to verify the
	// certificate against there is nothing to connect to safely.
	p := Provider{
		key: 'p'
		udp4: ['1.1.1.1']
	}

	assert p.dot_address() == ''
}

fn test_every_embedded_provider_is_probeable_and_documented() ! {
	c := embedded()!

	for p in c.providers {
		assert p.key != ''
		assert p.label != ''
		assert p.has_endpoint()
		// docs/DATA.md § Adding a provider: an endpoint nobody can look up is
		// an endpoint nobody can re-verify when it rots.
		assert p.homepage.starts_with('https://')
	}
}

fn test_embedded_keys_are_unique() ! {
	c := embedded()!
	mut seen := map[string]bool{}

	for p in c.providers {
		assert p.key !in seen
		seen[p.key] = true
	}
	assert seen.len == 16
}

fn test_the_ecs_comparison_pair_is_present() ! {
	// docs/METHODOLOGY.md § ecs leans on 9.9.9.9 versus 9.9.9.11 as the
	// clearest demonstration of what the edge probe measures. Losing either
	// half of that pair would quietly remove the project's headline example.
	c := embedded()!

	plain := c.providers.filter(it.key == 'quad9')
	ecs := c.providers.filter(it.key == 'quad9-ecs')

	assert plain.len == 1
	assert ecs.len == 1
	assert 'ecs' !in plain[0].tags
	assert 'ecs' in ecs[0].tags
	assert plain[0].udp4[0] == '9.9.9.9'
	assert ecs[0].udp4[0] == '9.9.9.11'
}

fn test_the_ecs_reference_resolvers_make_no_logging_claim() ! {
	// docs/DATA.md keeps google and opendns despite failing the logging
	// criterion, because they are the strongest ECS baseline available. The
	// price of keeping them is that the table must not imply they are private.
	c := embedded()!

	for key in ['google', 'opendns'] {
		matches := c.providers.filter(it.key == key)
		assert matches.len == 1
		assert 'nolog' !in matches[0].tags
	}
}

// ── the measured / declared separation ───────────────────────────────────────
fn test_declared_and_measured_tags_do_not_overlap() {
	// CLAUDE.md § 5: a declared tag must never reach a measured subscore. The
	// two partitions being disjoint and complete is what makes that structural
	// rather than a matter of remembering.
	for tag, kind in tag_vocabulary {
		assert tag != ''
		assert kind == .measured || kind == .declared
	}

	p := Provider{
		key: 'x'
		label: 'X'
		udp4: ['192.0.2.1']
		tags: ['dnssec', 'nolog', 'ecs', 'audited', 'nonprofit']
		homepage: 'https://example.invalid'
	}

	assert p.measured() == ['dnssec', 'ecs']
	assert p.declared() == ['nolog', 'audited', 'nonprofit']
	assert p.measured().len + p.declared().len == p.tags.len
}

fn test_every_tag_used_by_the_embedded_catalog_is_classified() ! {
	c := embedded()!

	for p in c.providers {
		for tag in p.tags {
			assert tag in tag_vocabulary
		}
		assert p.measured().len + p.declared().len == p.tags.len
	}
}

// ── validation ───────────────────────────────────────────────────────────────
const minimal_provider = 'version = 1
generated = "2026-01-01"

[[provider]]
key      = "example"
label    = "Example"
udp4     = ["192.0.2.1"]
tags     = ["dnssec"]
homepage = "https://example.invalid"
'

fn test_a_minimal_provider_is_accepted() ! {
	c := parse(minimal_provider)!

	assert c.version == 1
	assert c.providers.len == 1
	assert c.providers[0].udp4 == ['192.0.2.1']
	assert c.providers[0].dot == ''
}

fn test_an_unknown_tag_is_rejected() {
	text := minimal_provider.replace('["dnssec"]', '["dnssec", "superfast"]')

	if _ := parse(text) {
		assert false
	} else {
		assert err.msg().contains('not in the vocabulary')
	}
}

fn test_a_provider_with_no_endpoint_is_rejected() {
	text := minimal_provider.replace('udp4     = ["192.0.2.1"]\n', '')

	if _ := parse(text) {
		assert false
	} else {
		assert err.msg().contains('no endpoint')
	}
}

fn test_a_provider_with_no_homepage_is_rejected() {
	text := minimal_provider.replace('homepage = "https://example.invalid"\n', '')

	if _ := parse(text) {
		assert false
	} else {
		assert err.msg().contains('no homepage')
	}
}

fn test_a_duplicate_key_is_rejected() {
	// Merging by key is how user overrides work, so two entries claiming one
	// key make the merge order decide the result silently.
	text := minimal_provider + '
[[provider]]
key      = "example"
label    = "Example again"
udp4     = ["198.51.100.1"]
homepage = "https://example.invalid"
'

	if _ := parse(text) {
		assert false
	} else {
		assert err.msg().contains('duplicate provider key')
	}
}

fn test_an_empty_catalog_is_rejected() {
	if _ := parse('version = 1\ngenerated = "2026-01-01"\n') {
		assert false
	} else {
		assert err.msg().contains('no providers')
	}
}

fn test_nofilter_is_declared_not_measured() {
	// schema/result.schema.json lists nofilter in the declared enum,
	// docs/OUTPUT.md's example puts it there, and docs/SCORING.md gives it a
	// weight inside `privacy`, a subscore it calls declared and never measured.
	// The filter probe can contradict the claim by finding a blocked domain; no
	// probe can establish that a resolver manipulates nothing anywhere.
	assert tag_vocabulary['nofilter'] == TagKind.declared

	p := Provider{
		key: 'x'
		label: 'X'
		udp4: ['192.0.2.1']
		tags: ['dnssec', 'nofilter']
		homepage: 'https://example.invalid'
	}

	assert p.measured() == ['dnssec']
	assert p.declared() == ['nofilter']
}

fn test_the_declared_partition_matches_the_output_schema() {
	// If these drift apart, a serializer can emit a tag the contract rejects, or
	// the contract can accept one the code will never produce.
	schema_declared := ['nolog', 'nofilter', 'audited', 'nonprofit', 'configurable']

	mut declared := []string{}
	for tag, kind in tag_vocabulary {
		if kind == .declared {
			declared << tag
		}
	}
	declared.sort()
	mut expected := schema_declared.clone()
	expected.sort()

	assert declared == expected
}

// ── endpoint validation ──────────────────────────────────────────────────────
fn test_an_address_that_is_not_an_address_is_rejected() {
	// Nothing between the catalog and dial_udp checks this, so a typo here
	// would reach the socket verbatim.
	text := minimal_provider.replace('["192.0.2.1"]', '["dns.example.com"]')

	if _ := parse(text) {
		assert false
	} else {
		assert err.msg().contains('not an IPv4 literal')
	}
}

fn test_the_nextdns_entry_is_marked_as_needing_configuration() ! {
	// data/providers.toml ships __PROFILE__ placeholders and its comment
	// promises the entry is skipped without an id. Nothing implemented that, so
	// the placeholders would have been handed to dial_udp as written.
	c := embedded()!

	nextdns := c.providers.filter(it.key == 'nextdns')
	assert nextdns.len == 1
	assert nextdns[0].needs_config
	assert nextdns[0].dot.contains('__PROFILE__')

	// Every other entry is probeable as shipped.
	for p in c.providers {
		if p.key == 'nextdns' {
			continue
		}
		assert !p.needs_config
	}
}

fn test_a_provider_without_placeholders_is_not_marked() ! {
	c := parse(minimal_provider)!

	assert !c.providers[0].needs_config
}

// The edge probe is the reason the project exists, and it cannot run without
// targets. A catalog that silently lost its [[cdn_host]] table would leave the
// edge subscore null on every provider and look like a network problem.
fn test_the_embedded_catalog_carries_cdn_hosts_for_the_edge_probe() ! {
	c := embedded()!

	assert c.cdn_hosts.len == 9
	for h in c.cdn_hosts {
		assert h.host != ''
		assert h.cdn != ''
		assert !h.host.starts_with('http')
	}

	// Four CDN families, so that one operator's routing quirk cannot carry the
	// median on its own. docs/DATA.md § CDN hosts for the edge probe.
	mut families := map[string]int{}
	for h in c.cdn_hosts {
		families[h.cdn]++
	}
	assert families.len == 4
	for _, count in families {
		assert count >= 2
		// No family may hold half the set, or the median becomes that family's
		// opinion rather than the run's.
		assert count * 2 <= c.cdn_hosts.len
	}
}

fn test_a_cdn_host_without_a_cdn_is_refused() {
	// The cdn field is what the output attributes a penalty to. An entry that
	// does not say which CDN it probes produces a number nobody can act on.
	text := 'version = 1
generated = "2026-01-01"

[[provider]]
key = "p"
label = "P"
udp4 = ["1.1.1.1"]
homepage = "https://example.com"

[[cdn_host]]
host = "example.com"
'
	if _ := parse(text) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('does not say which CDN')
	}
}

fn test_a_doh_url_splits_into_a_hostname_and_a_path() ! {
	// The URL is never handed to an HTTP client to resolve, so it has to be
	// taken apart here: the hostname is what the certificate is checked against
	// and what the Host header carries, the path is the request target.
	c := embedded()!

	mut seen := 0
	for p in c.providers {
		if p.doh == '' {
			continue
		}
		seen++
		assert p.doh_host() != ''
		assert !p.doh_host().contains('/')
		assert p.doh_path().starts_with('/')
	}
	assert seen > 0
}

fn test_control_d_keeps_its_profile_path() ! {
	// Control D puts the profile in the path rather than the hostname, so a
	// splitter that assumed /dns-query would silently measure the wrong profile.
	c := embedded()!

	for p in c.providers {
		if p.key != 'controld-ads' {
			continue
		}
		assert p.doh_host() == 'freedns.controld.com'
		assert p.doh_path() == '/p2'
	}
}

fn test_a_url_with_no_path_becomes_a_root_request() {
	p := Provider{
		key: 'p'
		doh: 'https://dns.example.net'
		udp4: ['1.1.1.1']
	}

	assert p.doh_host() == 'dns.example.net'
	assert p.doh_path() == '/'
}

fn test_something_that_is_not_an_https_url_yields_nothing() {
	// An entry with a malformed DoH field must not become a request to a
	// hostname assembled out of the leftovers.
	p := Provider{
		key: 'p'
		doh: 'dns.example.net/dns-query'
		udp4: ['1.1.1.1']
	}

	assert p.doh_host() == ''
	assert p.doh_path() == ''
	assert p.doh_address() == ''
}
