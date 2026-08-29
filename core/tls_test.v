module core

import os

// The handshake itself is verified by hand against a live resolver, because a
// mock TLS endpoint would prove that the code talks to the mock. What is
// asserted here is the part that decides whether a handshake is even attempted,
// and the part that would silently weaken it.
fn test_an_override_is_used_as_given() ! {
	path := os.join_path(os.vtmp_dir(), 'dnsbench-ca-${os.getpid()}.pem')
	os.write_file(path, 'not a real bundle')!
	defer {
		os.rm(path) or {}
	}

	assert find_ca_bundle(path)! == path
}

fn test_an_override_that_does_not_exist_is_an_error() {
	// Not a fallback to the cascade. Someone who passed --ca-bundle meant that
	// file, and verifying against a different trust anchor than the one asked
	// for is the wrong way to fail.
	missing := os.join_path(os.vtmp_dir(), 'dnsbench-no-such-bundle-${os.getpid()}.pem')

	if found := find_ca_bundle(missing) {
		assert false, 'expected an error, got ${found}'
	} else {
		assert err.msg().contains('does not exist')
	}
}

fn test_the_cascade_returns_a_path_from_the_published_list() ! {
	// docs/ARCHITECTURE.md § TLS trust anchor publishes the four paths and the
	// order. A build that found a bundle somewhere else would be verifying
	// against a store the documentation does not describe.
	// A machine with no system store is a legitimate state, and the error then
	// has to name what was tried so the user can pass --ca-bundle.
	found := find_ca_bundle('') or {
		assert err.msg().contains('--ca-bundle')
		return
	}

	assert found in ca_bundle_candidates
}

fn test_a_dot_transport_without_a_trust_anchor_refuses_to_open() {
	// V loads no system trust store, so validate: true with no verify: path
	// fails every handshake anyway. Refusing here makes that a clear error
	// instead of a mbedtls return code, and there is deliberately no --insecure
	// to fall back to.
	mut t := DotTransport{
		hostname: 'dns.example.net'
	}

	if _ := t.open(Target{ ip: '192.0.2.1', port: 853 }) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('CA bundle')
	}
}

fn test_a_dot_transport_without_a_hostname_refuses_to_open() {
	// The verification hostname comes from the catalog. Without it there is
	// nothing to check the certificate against, and connecting anyway would be
	// an unvalidated handshake wearing the name of a validated one.
	mut t := DotTransport{
		ca_bundle: '/dev/null'
	}

	if _ := t.open(Target{ ip: '192.0.2.1', port: 853 }) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('hostname')
	}
}

fn test_a_dot_transport_used_before_open_is_an_error() {
	mut t := DotTransport{
		hostname: 'dns.example.net'
		ca_bundle: '/dev/null'
	}

	if _, _ := t.query([u8(0), 1]) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('before open()')
	}
}
