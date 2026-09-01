module catalog

fn test_near_target_prefers_doh_over_dot_over_udp() {
	assert (Provider{
		key: 'p'
		doh: 'https://x/dns-query'
		dot4: ['192.0.2.1']
		udp4: [
			'192.0.2.2',
		]
	}).near_target() == '192.0.2.1:443'
	assert (Provider{ key: 'p', dot: 'x', udp4: ['192.0.2.2'] }).near_target() == '192.0.2.2:853'
	assert (Provider{ key: 'p', udp4: ['192.0.2.2'] }).near_target() == '192.0.2.2:53'
	assert (Provider{ key: 'p' }).near_target() == ''
}

fn test_near_rank_keeps_the_fastest_n() {
	providers := [
		Provider{ key: 'slow', doh: 'https://slow/dns-query', dot4: ['192.0.2.1'] },
		Provider{ key: 'fast', doh: 'https://fast/dns-query', dot4: ['192.0.2.2'] },
		Provider{ key: 'mid', doh: 'https://mid/dns-query', dot4: ['192.0.2.3'] },
	]
	measured := [
		NearMeasurement{ key: 'slow', ms: 300 },
		NearMeasurement{ key: 'fast', ms: 10 },
		NearMeasurement{ key: 'mid', ms: 100 },
	]

	kept := near_rank(providers, measured, 2)

	assert kept.map(it.key) == ['fast', 'mid']
}

// A provider dialled and never answered is dropped, not kept: that is the
// filter doing its job. Only a provider `near_target` could not address at
// all is exempt.
fn test_near_rank_drops_unreachable_testable_providers() {
	providers := [
		Provider{ key: 'reachable', doh: 'https://a/dns-query', dot4: ['192.0.2.1'] },
		Provider{ key: 'unreachable', doh: 'https://b/dns-query', dot4: ['192.0.2.2'] },
		Provider{ key: 'no-address', label: 'no address' },
	]
	measured := [
		NearMeasurement{ key: 'reachable', ms: 42 },
	]

	kept := near_rank(providers, measured, 25)

	assert kept.map(it.key).sorted() == ['no-address', 'reachable']
}

fn test_near_rank_never_excludes_an_untestable_provider() {
	providers := [
		Provider{ key: 'no-address-1', label: 'a' },
		Provider{ key: 'no-address-2', label: 'b' },
	]

	kept := near_rank(providers, []NearMeasurement{}, 1)

	assert kept.map(it.key).sorted() == ['no-address-1', 'no-address-2']
}
