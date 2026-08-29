module core

import net
import os
import time

// Transports are exercised against mock servers on the loopback interface.
// No test in this repository sends a packet to a public resolver; see
// CONTRIBUTING.md. Manual verification against real resolvers happens outside
// the suite and is rate-limited by hand.
//
// The mocks reply with testdata/minimal.response.bin, whose id is 0xbdeb, so
// every test below asks its query with that same id and the two match without
// any byte-patching.
const mock_id = u16(0xbdeb)

const mock_timeout = 300 * time.millisecond

// Each _test.v file is compiled on its own, so wire_test.v's reader is not in
// scope here and this file carries its own.
fn fixture(name string) ![]u8 {
	return os.read_bytes(os.join_path(@VMODROOT, 'testdata', name))!
}

// listen_udp cannot report the port it landed on when asked to bind to 0, and
// UdpConn exposes no addr(), so a test picks its own port out of a small range.
fn bind_udp_mock() !(&net.UdpConn, int) {
	for port in 40000 .. 40100 {
		if conn := net.listen_udp('127.0.0.1:${port}') {
			return conn, port
		}
	}
	return error('no free UDP port in 40000..40100')
}

fn serve_udp(mut server net.UdpConn, datagrams [][]u8) {
	mut buf := []u8{len: 4096}
	_, client := server.read(mut buf) or { return }
	for d in datagrams {
		server.write_to(client, d) or { return }
	}
}

fn serve_udp_silently_dropping(mut server net.UdpConn) {
	mut buf := []u8{len: 4096}
	server.read(mut buf) or { return }
}

fn serve_tcp(mut listener net.TcpListener, reply []u8, dribble bool) {
	mut conn := listener.accept() or { return }
	defer {
		conn.close() or {}
	}

	mut prefix := []u8{len: 2}
	read_exact(mut conn, mut prefix) or { return }
	mut body := []u8{len: int(be16(prefix, 0))}
	read_exact(mut conn, mut body) or { return }

	mut framed := []u8{cap: reply.len + 2}
	push_u16(mut framed, u16(reply.len))
	framed << reply

	if !dribble {
		conn.write(framed) or {}
		return
	}
	// One octet per write, so the client's read_exact has to loop instead of
	// getting the whole response in a single read.
	for b in framed {
		conn.write([b]) or { return }
	}
}

// ── UDP ──────────────────────────────────────────────────────────────────────
fn test_udp_query_returns_the_reply_and_an_elapsed_time() ! {
	reply := fixture('minimal.response.bin')!
	mut server, port := bind_udp_mock()!
	server.set_read_timeout(mock_timeout)
	worker := spawn serve_udp(mut server, [reply])

	mut t := UdpTransport{}
	t.open(ip: '127.0.0.1', port: port, timeout: mock_timeout)!
	q := build_query_opts('google.com', qtype_a, id: mock_id)!
	got, ms := t.query(q)!
	t.close()
	worker.wait()
	server.close() or {}

	assert got == reply
	assert ms > 0.0
	assert ms < 300.0

	// The bytes that came back are a message, not just a blob of the right size.
	r := parse_response(got)!
	assert r.header.id == mock_id
	assert r.answer[0].rdata == [u8(172), 217, 172, 46]
}

fn test_udp_discards_a_reply_carrying_someone_elses_id() ! {
	// A late answer to an earlier query would otherwise be timed as this
	// query's reply and recorded as an implausibly fast sample. A wrong number
	// is worse than a missing one.
	good := fixture('minimal.response.bin')!
	mut stale := good.clone()
	stale[0] = 0xff
	stale[1] = 0xff

	mut server, port := bind_udp_mock()!
	server.set_read_timeout(mock_timeout)
	worker := spawn serve_udp(mut server, [stale, good])

	mut t := UdpTransport{}
	t.open(ip: '127.0.0.1', port: port, timeout: mock_timeout)!
	q := build_query_opts('google.com', qtype_a, id: mock_id)!
	got, _ := t.query(q)!
	t.close()
	worker.wait()
	server.close() or {}

	assert got == good
	assert rcode(got) == rcode_noerror
}

fn test_udp_query_times_out_when_nothing_answers() ! {
	mut server, port := bind_udp_mock()!
	server.set_read_timeout(mock_timeout)
	worker := spawn serve_udp_silently_dropping(mut server)

	mut t := UdpTransport{}
	t.open(ip: '127.0.0.1', port: port, timeout: mock_timeout)!
	q := build_query_opts('google.com', qtype_a, id: mock_id)!

	sw := time.new_stopwatch()
	if _, _ := t.query(q) {
		assert false
	}
	elapsed := sw.elapsed()
	t.close()
	worker.wait()
	server.close() or {}

	// It waited rather than failing instantly: the sample is loss, not an error
	// the scheduler should retry.
	assert elapsed >= mock_timeout
}

fn test_udp_query_before_open_is_an_error() ! {
	mut t := UdpTransport{}
	q := build_query_opts('google.com', qtype_a, id: mock_id)!

	if _, _ := t.query(q) {
		assert false
	} else {
		assert err.msg().contains('before open()')
	}
}

// ── TCP ──────────────────────────────────────────────────────────────────────
fn test_tcp_query_round_trips_through_the_length_prefix() ! {
	reply := fixture('minimal.response.bin')!
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	worker := spawn serve_tcp(mut listener, reply, false)

	mut t := TcpTransport{}
	t.open(ip: '127.0.0.1', port: int(port), timeout: mock_timeout)!
	q := build_query_opts('google.com', qtype_a, id: mock_id)!
	got, ms := t.query(q)!
	t.close()
	worker.wait()
	listener.close() or {}

	// The two-octet prefix is framing and is not part of the message.
	assert got == reply
	assert got.len == 44
	assert ms > 0.0

	r := parse_response(got)!
	assert r.header.id == mock_id
}

fn test_tcp_reassembles_a_response_split_across_reads() ! {
	// The server writes one octet at a time. A client that treats the first
	// read as the whole response gets a truncated message that still parses far
	// enough to look plausible, which is the failure this guards against.
	reply := fixture('cname.response.bin')!
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	worker := spawn serve_tcp(mut listener, reply, true)

	mut t := TcpTransport{}
	t.open(ip: '127.0.0.1', port: int(port), timeout: mock_timeout)!
	q := build_query_opts('www.microsoft.com', qtype_a, id: 0xded5)!
	got, _ := t.query(q)!
	t.close()
	worker.wait()
	listener.close() or {}

	assert got.len == 135
	assert got == reply

	r := parse_response(got)!
	assert r.answer.len == 3
	assert r.answer[2].name == 'e13678.dscb.akamaiedge.net'
}

fn test_tcp_query_before_open_is_an_error() ! {
	mut t := TcpTransport{}
	q := build_query_opts('google.com', qtype_a, id: mock_id)!

	if _, _ := t.query(q) {
		assert false
	} else {
		assert err.msg().contains('before open()')
	}
}

// ── interface conformance ────────────────────────────────────────────────────
fn test_both_transports_satisfy_the_interface() {
	// If either shape drifts from docs/ARCHITECTURE.md the assignment stops
	// compiling, which is the point of asserting it here.
	mut transports := [Transport(UdpTransport{}), Transport(TcpTransport{})]

	assert transports[0].name() == 'udp'
	assert transports[1].name() == 'tcp'
	assert transports[0].reusable()
	assert transports[1].reusable()
}

// ── target addressing ────────────────────────────────────────────────────────
fn test_a_hostname_is_refused_as_a_target() ! {
	// net.dial_udp('dns.google:53') succeeds perfectly happily, which is the
	// problem: the lookup lands inside the connect path and the round trips get
	// reported as clean latency. docs/METHODOLOGY.md § dot-fresh vs dot-warm.
	mut t := UdpTransport{}

	if _ := t.open(ip: 'dns.google') {
		assert false
	} else {
		assert err.msg().contains('not an IP literal')
	}
}

fn test_ipv6_targets_are_bracketed() ! {
	// Unbracketed works today only because V splits at the last colon. An
	// address that already contains colons should not depend on that.
	v6 := Target{
		ip: '2606:4700:4700::1111'
		port: 853
	}
	v4 := Target{
		ip: '1.1.1.1'
		port: 53
	}

	assert v6.dial_address()! == '[2606:4700:4700::1111]:853'
	assert v4.dial_address()! == '1.1.1.1:53'
}

fn test_is_ip_literal_separates_addresses_from_names() {
	assert is_ip_literal('1.1.1.1')
	assert is_ip_literal('192.0.2.113')
	assert is_ip_literal('2606:4700:4700::1111')
	assert is_ip_literal('::1')
	// A zone index still describes an address, and netinfo reports them.
	assert is_ip_literal('fe80::1%wlp3s0')

	assert !is_ip_literal('')
	assert !is_ip_literal('dns.google')
	assert !is_ip_literal('one.one.one.one')
	assert !is_ip_literal('1.1.1')
	assert !is_ip_literal('1.1.1.1.1')
	assert !is_ip_literal('256.0.0.1')
	assert !is_ip_literal('1.1.1.a')
}

fn test_udp_query_is_bounded_by_the_timeout_not_by_the_datagram_count() ! {
	// The mock answers with the wrong id every time. set_read_timeout is a
	// per-read deadline, so counting datagrams alone would let this run for
	// max_stale_datagrams times the timeout before erroring.
	good := fixture('minimal.response.bin')!
	mut stale := good.clone()
	stale[0] = 0xff
	stale[1] = 0xff

	mut server, port := bind_udp_mock()!
	server.set_read_timeout(mock_timeout)
	mut spray := [][]u8{len: max_stale_datagrams, init: stale}
	worker := spawn serve_udp(mut server, spray)

	mut t := UdpTransport{}
	t.open(ip: '127.0.0.1', port: port, timeout: mock_timeout)!
	q := build_query_opts('google.com', qtype_a, id: mock_id)!

	sw := time.new_stopwatch()
	if _, _ := t.query(q) {
		assert false
	}
	elapsed := sw.elapsed()
	t.close()
	worker.wait()
	server.close() or {}

	// Comfortably under max_stale_datagrams x mock_timeout, which is what the
	// datagram count alone would have allowed.
	assert elapsed < 3 * mock_timeout
}

// ── connect timing ───────────────────────────────────────────────────────────
fn test_connect_ms_times_a_connection_that_succeeds() ! {
	// A local listener, so the number is a floor rather than a measurement, but
	// it establishes that the happy path returns a time and not an error.
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	defer {
		listener.close() or {}
	}

	ms := connect_ms('127.0.0.1:${port}', 2 * time.second)!

	assert ms >= 0.0
	assert ms < 2000.0
}

fn test_connect_ms_fails_fast_on_a_refused_port() ! {
	// A closed port answers with RST immediately. This must be an error and not
	// a very fast connect: the edge probe would otherwise record a refusal as
	// the best edge in the run and hand that provider a perfect score.
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	listener.close() or {}

	if ms := connect_ms('127.0.0.1:${port}', 2 * time.second) {
		assert false, 'expected an error, got ${ms} ms'
	}
}

fn test_connect_ms_gives_up_at_the_budget() ! {
	// 192.0.2.1 is TEST-NET-1: routable nowhere, so the SYN goes unanswered.
	// V's dial_tcp has no connect timeout on the default build path, and the
	// operating system's own is minutes long, so without the budget one bad
	// address would stall a whole run.
	sw := time.new_stopwatch()
	if ms := connect_ms('192.0.2.1:443', 500 * time.millisecond) {
		assert false, 'expected a timeout, got ${ms} ms'
	}
	elapsed := sw.elapsed().milliseconds()

	assert elapsed >= 500
	assert elapsed < 1500
}
