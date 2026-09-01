module catalog

import os

// Every stamp asserted here is a real line from the DNSCrypt project's
// public-resolvers.md, captured in testdata/sdns_samples.md. The expected
// fields were derived by decoding the same bytes by hand, not by running this
// parser and copying its output: docs/V-NOTES.md's rule for wire formats
// applies here just as it does to core/wire_test.v.
fn sample_text() !string {
	return os.read_file(os.join_path(@VMODROOT, 'testdata', 'sdns_samples.md'))!
}

fn test_a_doh_stamp_with_a_single_hash() ! {
	s := parse_stamp('sdns://AgcAAAAAAAAADTIxNy4xNjkuMjAuMjIADWRucy5hYS5uZXQudWsKL2Rucy1xdWVyeQ')!
	assert s.protocol == .doh
	assert s.address == '217.169.20.22'
	assert s.hostname == 'dns.aa.net.uk'
	assert s.path == '/dns-query'
	assert s.dnssec
	assert s.nolog
	assert s.nofilter
}

fn test_a_doh_stamp_with_an_ipv6_address() ! {
	s := parse_stamp('sdns://AgcAAAAAAAAAEFsyMDAxOjhiMDo6MjAyMl0ADWRucy5hYS5uZXQudWsKL2Rucy1xdWVyeQ')!
	assert s.protocol == .doh
	assert s.address == '[2001:8b0::2022]'
}

// The one stamp in the real list that pins two hashes rather than one. The
// second hash has to be walked, not skipped, or the hostname and path that
// follow would be read from the wrong offset.
fn test_a_doh_stamp_with_two_pinned_hashes() ! {
	s := parse_stamp('sdns://AgcAAAAAAAAADjEwMi4yMDkuMjEuMTc2oP_qvxWZFJ9BK1V6rOVWoUSdlRS9JwllVzJr6hoRRXifINqSeh5K4YpnPElAq-H8Z9W88gNANHsHDKWZn1t_0K1ID2NpcGhlcmRucy5jby56YQovZG5zLXF1ZXJ5')!
	assert s.protocol == .doh
	assert s.address == '102.209.21.176'
	assert s.hostname == 'cipherdns.co.za'
	assert s.path == '/dns-query'
}

// address is empty when the stamp asks the client to resolve a hostname
// itself, which this tool never does mid-run.
fn test_a_doh_stamp_with_no_address() ! {
	s := parse_stamp('sdns://AgcAAAAAAAAAACAy7bsRzCWPvjPCzSShSScPC-b0RvVyZLO9HCW5hTMnLg5kbnMuZG5zaG9tZS5kZQovZG5zLXF1ZXJ5')!
	assert s.protocol == .doh
	assert s.address == ''
	assert s.hostname == 'dns.dnshome.de'
}

fn test_a_dnscrypt_stamp_carries_a_provider_name_not_a_path() ! {
	s := parse_stamp('sdns://AQMAAAAAAAAAETk0LjE0MC4xNC4xNDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20')!
	assert s.protocol == .dnscrypt
	assert s.address == '94.140.14.14:5443'
	assert s.hostname == '2.dnscrypt.default.ns1.adguard.com'
	assert s.path == ''
	assert s.nolog
	assert !s.nofilter
}

fn test_an_unrecognised_protocol_is_not_an_error() ! {
	// Same layout as the DoH sample above, protocol byte changed from 0x02 to
	// 0x09. A future stamp type must degrade to "unsupported", not fail update.
	s := parse_stamp('sdns://CQcAAAAAAAAADTIxNy4xNjkuMjAuMjIADWRucy5hYS5uZXQudWsKL2Rucy1xdWVyeQ')!
	assert s.protocol == .unsupported
}

fn test_a_non_stamp_string_is_refused() {
	if _ := parse_stamp('https://example.com') {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('sdns://')
	}
}

fn test_a_truncated_stamp_is_refused() {
	// "sdns://AQ" decodes to a single octet, short of the 9-octet header.
	if _ := parse_stamp('sdns://AQ') {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('octets')
	}
}

fn test_parse_resolvers_md_reads_every_section() ! {
	result := parse_resolvers_md(sample_text()!)
	assert result.skipped.len == 0

	mut by_key := map[string]DnscryptEntry{}
	for e in result.entries {
		by_key[e.key] = e
	}
	assert result.entries.len == 7
	assert by_key['a-and-a'].stamps.len == 2
	assert by_key['cloudflare'].stamps.len == 8
	assert by_key['adguard-dns'].stamps.len == 2
}

fn test_providers_from_entries_keeps_usable_doh_stamps() ! {
	result := parse_resolvers_md(sample_text()!)
	providers, skipped := providers_from_entries(result.entries)

	mut by_key := map[string]Provider{}
	for p in providers {
		by_key[p.key] = p
	}

	// Two addresses, ipv4, become dot4, never udp4: nothing here establishes
	// that a DoH-only entry also answers plain UDP on port 53.
	a_and_a := by_key['a-and-a']
	assert a_and_a.dot4 == ['217.169.20.22', '217.169.20.23']
	assert a_and_a.udp4.len == 0
	assert a_and_a.doh == 'https://dns.aa.net.uk/dns-query'
	assert 'dnssec' in a_and_a.tags
	assert 'nolog' in a_and_a.tags
	assert 'nofilter' in a_and_a.tags
	assert a_and_a.homepage == dnscrypt_source_page

	ipv6 := by_key['a-and-a-ipv6']
	assert ipv6.dot4.len == 0
	assert ipv6.dot6 == ['2001:8b0::2022', '2001:8b0::2023']

	cloudflare := by_key['cloudflare']
	assert cloudflare.dot4.len == 8
	assert cloudflare.doh == 'https://dns.cloudflare.com/dns-query'

	// dnshome-de and doh-cleanbrowsing-adult name no address; adguard-dns is
	// DNSCrypt-protocol. None of the three has a usable stamp, so none becomes
	// a provider, and each is named in `skipped` instead.
	assert 'dnshome-de' !in by_key
	assert 'doh-cleanbrowsing-adult' !in by_key
	assert 'adguard-dns' !in by_key
	assert providers.len == 4
	assert skipped.any(it.contains('dnshome-de'))
	assert skipped.any(it.contains('doh-cleanbrowsing-adult'))
	assert skipped.filter(it.contains('adguard-dns')).len == 2
}

fn test_a_stamp_with_a_nonstandard_port_is_skipped_not_mismeasured() ! {
	// AdGuard's DNSCrypt entry asks for :5443; reused here only for the address
	// shape, with the protocol byte changed to 0x02 (doh) so the port check is
	// what triggers the skip rather than the protocol check.
	entries := [
		DnscryptEntry{
			key: 'ported'
			stamps: [
				Stamp{
					protocol: .doh
					address: '94.140.14.14:5443'
					hostname: 'example.test'
					path: '/dns-query'
				},
			]
		},
	]
	providers, skipped := providers_from_entries(entries)
	assert providers.len == 0
	assert skipped.any(it.contains('ported') && it.contains('5443'))
}
