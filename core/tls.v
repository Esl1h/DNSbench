module core

import net
import net.ssl
import os
import time

// DNS over TLS, RFC 7858, and the trust anchor it needs.
//
// Two things here are not obvious and are both recorded in docs/V-NOTES.md
// because they cost time to discover. V loads no system trust store, so
// `validate: true` with no `verify:` path fails every handshake. And the
// connection has to be made to an IP literal with the verification hostname
// passed separately, because `SSLConn.dial` resolves the hostname itself and
// would put a system-resolver lookup inside every latency sample.

// ca_bundle_candidates is the cascade of docs/ARCHITECTURE.md § TLS trust
// anchor, first match wins.
//
// The system store is the anchor on purpose. An embedded bundle would keep
// trusting a distrusted CA until the next release, on a schedule this project
// does not control, and DoT verification would then reflect a private policy
// rather than the machine's real trust posture.
pub const ca_bundle_candidates = [
	'/etc/ssl/certs/ca-certificates.crt',
	'/etc/pki/tls/certs/ca-bundle.crt',
	'/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
	'/etc/ssl/cert.pem',
]

// find_ca_bundle locates the trust store, or says which paths it tried.
//
// An override that does not exist is an error rather than a fallback to the
// cascade: someone who passed --ca-bundle meant that file, and quietly using a
// different trust anchor than the one asked for is the wrong way to fail.
pub fn find_ca_bundle(override string) !string {
	if override != '' {
		if !os.exists(override) {
			return error('--ca-bundle ${override} does not exist')
		}
		return override
	}
	for path in ca_bundle_candidates {
		if os.exists(path) {
			return path
		}
	}
	return error('no CA bundle found; tried ${ca_bundle_candidates.join(', ')}. Pass --ca-bundle <path>')
}

// dial_tls_stream is dial_tls for a caller that only wants the TLS side.
//
// The socket underneath stays alive as long as the connection does; V's fmt
// discards a `mut` on the second half of a multi-return assignment, which turned
// the obvious form into a compile error, so the discard happens here instead.
fn dial_tls_stream(target Target, hostname string, ca_bundle string) !&ssl.SSLConn {
	_, tls := dial_tls(target, hostname, ca_bundle)!
	return tls
}

// DotTransport is DNS over TLS on port 853.
//
// The wire format is the TCP one: RFC 7858 carries the same two-octet length
// prefix as RFC 1035 § 4.2.2, inside the TLS record layer.
pub struct DotTransport {
mut:
	tcp    &net.TcpConn = unsafe { nil }
	tls    &ssl.SSLConn = unsafe { nil }
	target Target
	open_  bool
	// hostname is the name the certificate is verified against, and the SNI
	// sent. It comes from the catalog, never from a reverse lookup.
pub:
	hostname string
	// ca_bundle is the trust anchor. Empty is not "system default", it is a
	// handshake that will fail, so the caller resolves it before opening.
	ca_bundle string
}

// name is the label this transport carries into the output.
pub fn (t DotTransport) name() string {
	return 'dot'
}

// reusable is true, and the whole dot_fresh versus dot_warm split exists
// because real clients take it up: Android Private DNS, systemd-resolved,
// unbound with forward-tls-upstream and dnscrypt-proxy all hold the connection
// open and pay the handshake once per session.
pub fn (t DotTransport) reusable() bool {
	return true
}

// dial_tls opens a verified TLS connection to an address, checking the
// certificate against a hostname that is supplied rather than looked up.
//
// Both encrypted transports go through here, so the trust decision is made in
// exactly one place. Passing the hostname separately is what keeps a
// system-resolver lookup out of every latency sample, and it is not a
// verification bypass: the handshake still fails if the certificate does not
// match the name.
fn dial_tls(target Target, hostname string, ca_bundle string) !(&net.TcpConn, &ssl.SSLConn) {
	if hostname == '' {
		return error('a TLS connection needs a verification hostname')
	}
	if ca_bundle == '' {
		return error('a TLS connection needs a CA bundle; V loads no system trust store')
	}

	mut tcp := dial_tcp_bounded(target.dial_address()!, target.timeout)!
	tcp.set_read_timeout(target.timeout)
	tcp.set_write_timeout(target.timeout)

	mut conn := ssl.new_ssl_conn(validate: true, verify: ca_bundle) or {
		tcp.close() or {}
		return err
	}
	conn.connect(mut tcp, hostname) or {
		tcp.close() or {}
		return err
	}
	conn.set_read_timeout(target.timeout)

	return tcp, conn
}

// open pays for the TCP handshake and the TLS handshake.
//
// Whoever measures the fresh-connection variant must time this call and not
// just query(): the handshake is the entire difference the variant exists to
// show.
pub fn (mut t DotTransport) open(target Target) ! {
	t.close()

	tcp, tls := dial_tls(target, t.hostname, t.ca_bundle)!
	t.tcp = tcp
	t.tls = tls
	t.target = target
	t.open_ = true
}

// query sends one length-prefixed message and reads one back.
pub fn (mut t DotTransport) query(msg []u8) !([]u8, f64) {
	if !t.open_ {
		return error('dot transport used before open()')
	}
	if msg.len > 0xffff {
		return error('query message is ${msg.len} octets, over the 65535 the length prefix can express')
	}

	mut framed := []u8{cap: msg.len + 2}
	push_u16(mut framed, u16(msg.len))
	framed << msg

	sw := time.new_stopwatch()
	t.tls.write(framed)!

	mut prefix := []u8{len: 2}
	read_exact_tls(mut t.tls, mut prefix)!
	length := int(be16(prefix, 0))
	if length == 0 {
		return error('peer declared a zero-length response')
	}

	mut body := []u8{len: length}
	read_exact_tls(mut t.tls, mut body)!
	ms := f64(sw.elapsed().microseconds()) / 1000.0

	return body, ms
}

// close tears down TLS and the socket under it, in that order.
pub fn (mut t DotTransport) close() {
	if !t.open_ {
		return
	}
	t.tls.shutdown() or {}
	t.open_ = false
}

// read_exact_tls is read_exact over a TLS connection, and exists for the same
// reason: a single read is free to return fewer octets than asked for, and a
// short read taken for the whole message turns a stream into a corrupt one.
//
// It is a copy rather than a shared generic because SSLConn and TcpConn do not
// share a read signature V can dispatch on here, and twelve duplicated lines
// beat an abstraction that has to be explained.
fn read_exact_tls(mut conn ssl.SSLConn, mut buf []u8) ! {
	mut got := 0
	for got < buf.len {
		mut chunk := []u8{len: buf.len - got}
		n := conn.read(mut chunk)!
		if n <= 0 {
			return error('connection closed after ${got} of ${buf.len} octets')
		}
		for i in 0 .. n {
			buf[got + i] = chunk[i]
		}
		got += n
	}
}
