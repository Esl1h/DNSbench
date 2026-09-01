module catalog

fn test_dnscrypt_entries_fill_in_new_keys() {
	base := Catalog{
		providers: [
			Provider{ key: 'quad9', label: 'Quad9', udp4: ['9.9.9.9'], homepage: 'https://quad9.net' },
		]
	}
	dnscrypt := [
		Provider{ key: 'cipherdns-ct1-doh-za', label: 'CipherDNS', doh: 'https://cipherdns.co.za/dns-query' },
	]

	result := merge(base, dnscrypt, []Provider{})

	assert result.skipped.len == 0
	assert result.catalog.providers.len == 2
	assert result.catalog.providers.map(it.key) == ['quad9', 'cipherdns-ct1-doh-za']
}

// The collision that actually exists between the two real catalogs: both name
// a provider "cloudflare". The curated embedded entry, with its udp4 and dot
// endpoints, must survive untouched.
fn test_a_colliding_dnscrypt_entry_never_replaces_the_embedded_one() {
	base := Catalog{
		providers: [
			Provider{
				key: 'cloudflare'
				label: 'Cloudflare'
				udp4: ['1.1.1.1']
				dot: 'cloudflare-dns.com'
				doh: 'https://cloudflare-dns.com/dns-query'
				homepage: 'https://developers.cloudflare.com/1.1.1.1/'
				notes: 'curated'
			},
		]
	}
	dnscrypt := [
		Provider{
			key: 'cloudflare'
			label: 'Cloudflare'
			dot4: ['1.0.0.1']
			doh: 'https://dns.cloudflare.com/dns-query'
			homepage: dnscrypt_source_page
		},
	]

	result := merge(base, dnscrypt, []Provider{})

	assert result.catalog.providers.len == 1
	kept := result.catalog.providers[0]
	assert kept.notes == 'curated'
	assert kept.udp4 == ['1.1.1.1']
	assert kept.dot == 'cloudflare-dns.com'
	assert result.skipped.len == 1
	assert result.skipped[0].contains('cloudflare')
	assert result.skipped[0].contains('already curated')
}

fn test_a_user_entry_overrides_both_other_layers() {
	base := Catalog{
		providers: [
			Provider{ key: 'quad9', label: 'Quad9', udp4: ['9.9.9.9'], homepage: 'https://quad9.net' },
		]
	}
	dnscrypt := []Provider{}
	user := [
		Provider{ key: 'quad9', label: 'Quad9 (mine)', udp4: ['192.0.2.1'], homepage: 'https://internal.example' },
	]

	result := merge(base, dnscrypt, user)

	assert result.catalog.providers.len == 1
	assert result.catalog.providers[0].label == 'Quad9 (mine)'
	assert result.catalog.providers[0].udp4 == ['192.0.2.1']
}

fn test_a_user_entry_with_a_new_key_is_added() {
	base := Catalog{
		providers: [
			Provider{ key: 'quad9', label: 'Quad9', udp4: ['9.9.9.9'], homepage: 'https://quad9.net' },
		]
	}
	user := [
		Provider{ key: 'homelab', label: 'Homelab', udp4: ['192.0.2.53'], homepage: 'https://internal.example' },
	]

	result := merge(base, []Provider{}, user)

	assert result.catalog.providers.map(it.key) == ['quad9', 'homelab']
}

fn test_cdn_hosts_travel_from_embedded_untouched() {
	base := Catalog{
		providers: [
			Provider{ key: 'quad9', label: 'Quad9', udp4: ['9.9.9.9'], homepage: 'https://quad9.net' },
		]
		cdn_hosts: [CdnHost{ host: 'www.example.com', cdn: 'akamai' }]
	}

	result := merge(base, []Provider{}, []Provider{})

	assert result.catalog.cdn_hosts.len == 1
	assert result.catalog.cdn_hosts[0].host == 'www.example.com'
}
