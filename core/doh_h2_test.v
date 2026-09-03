module core

// The request and response path is verified by hand against live endpoints,
// Quad9 and Mullvad specifically, because a mock curl handle would only
// prove the client talks to itself. What is asserted here is the guard
// logic open() runs before it ever touches libcurl.
fn test_a_doh_h2_transport_used_before_open_is_an_error() {
	mut t := DohH2Transport{
		hostname: 'dns.example.net'
		path: '/dns-query'
		ca_bundle: '/dev/null'
	}

	if _, _ := t.query([u8(0), 1]) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('before open()')
	}
}

fn test_a_doh_h2_transport_without_a_path_refuses_to_open() {
	mut t := DohH2Transport{
		hostname: 'dns.example.net'
		ca_bundle: '/dev/null'
	}

	if _ := t.open(Target{ ip: '192.0.2.1', port: 443 }) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('request path')
	}
}

fn test_a_doh_h2_transport_without_a_hostname_refuses_to_open() {
	mut t := DohH2Transport{
		path: '/dns-query'
		ca_bundle: '/dev/null'
	}

	if _ := t.open(Target{ ip: '192.0.2.1', port: 443 }) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('hostname')
	}
}

fn test_a_doh_h2_transport_without_a_trust_anchor_refuses_to_open() {
	// V loads no system trust store, the same reason core/tls.v's dial_tls
	// refuses without one; libcurl would otherwise fall back to its own
	// build-time default, which this project never asked it to trust.
	mut t := DohH2Transport{
		hostname: 'dns.example.net'
		path: '/dns-query'
	}

	if _ := t.open(Target{ ip: '192.0.2.1', port: 443 }) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('CA bundle')
	}
}
