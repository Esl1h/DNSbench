module core

import net
import time

// The transports. Everything that touches a socket lives behind this
// interface, so that probes, scheduling and scoring can be exercised with no
// network at all.
//
// UDP and TCP are here. DoT and DoH are M2 and will implement the same
// interface; see docs/ARCHITECTURE.md § Transport support matrix.

// Target is where to send a query. The address is always an IP literal: a
// hostname here would put a system-resolver lookup inside every latency
// sample, which is the exact error docs/METHODOLOGY.md warns about.
pub struct Target {
pub:
	ip      string
	port    int = 53
	timeout time.Duration = 2 * time.second
}

// dial_address renders a target for net.dial_*, and rejects anything that is
// not an IP literal.
//
// The rejection is the point. V's resolver accepts a hostname here perfectly
// happily, and a hostname would put a lookup inside the connect path and then
// report the round trips as clean latency. That is the error
// docs/METHODOLOGY.md § dot-fresh vs dot-warm calls out by name, and a comment
// on the field was not stopping it.
//
// IPv6 is bracketed. Unbracketed works today because V splits at the last
// colon, but an address that already contains colons should not rely on that.
fn (t Target) dial_address() !string {
	if !is_ip_literal(t.ip) {
		return error('target "${t.ip}" is not an IP literal; resolving a hostname would land inside the measurement')
	}
	if t.ip.contains(':') {
		return '[${t.ip}]:${t.port}'
	}
	return '${t.ip}:${t.port}'
}

// is_ip_literal accepts dotted-quad IPv4 and hexadecimal IPv6, including a zone
// index. It is a shape test, not a full parser: the socket layer is the
// authority on whether an address is usable, and this only has to be certain
// that a hostname never reaches it.
fn is_ip_literal(s string) bool {
	if s == '' {
		return false
	}
	if s.contains(':') {
		for c in s.all_before('%') {
			if !(c.is_hex_digit() || c == `:`) {
				return false
			}
		}
		return true
	}
	octets := s.split('.')
	if octets.len != 4 {
		return false
	}
	for octet in octets {
		if octet == '' || octet.len > 3 {
			return false
		}
		for c in octet {
			if !c.is_digit() {
				return false
			}
		}
		if octet.int() > 255 {
			return false
		}
	}
	return true
}

pub interface Transport {
	name() string
mut:
	open(target Target) !
	query(msg []u8) !([]u8, f64)
	close()
	// reusable reports whether several queries may share one open(). It says
	// nothing about whether they should: the fresh-versus-warm split is a
	// scheduling decision, and this only says the transport permits it.
	reusable() bool
}

// max_udp_response is the largest datagram we will accept. Above the 1232-octet
// EDNS payload size we advertise, a resolver truncates and sets TC rather than
// sending more, so this has room to spare.
const max_udp_response = 4096

// max_stale_datagrams bounds how many mismatched replies one query will discard.
//
// It is not by itself a time bound: set_read_timeout is a deadline per read, so
// counting datagrams would let a peer that paces them hold query() for eight
// times the configured timeout. query() tracks the elapsed time as well, and
// that is what actually bounds the wall clock.
const max_stale_datagrams = 8

// ── UDP ──────────────────────────────────────────────────────────────────────
pub struct UdpTransport {
mut:
	conn   &net.UdpConn = unsafe { nil }
	target Target
	open_  bool
}

// name is the label this transport carries into the output.
pub fn (t UdpTransport) name() string {
	return 'udp'
}

// reusable is true: a connected UDP socket serves any number of queries.
// There is no handshake to amortise, only a socket not worth reopening.
pub fn (t UdpTransport) reusable() bool {
	return true
}

// open connects a UDP socket. It costs no round trip, so it measures nothing
// and a caller timing it is timing a syscall.
pub fn (mut t UdpTransport) open(target Target) ! {
	t.close()
	// dial_udp connects the socket, so the kernel already drops datagrams from
	// anyone but the target. The id check in query() covers what remains: a
	// late reply to an earlier query on this same socket.
	t.conn = net.dial_udp(target.dial_address()!)!
	t.conn.set_read_timeout(target.timeout)
	t.conn.set_write_timeout(target.timeout)
	t.target = target
	t.open_ = true
}

// close releases the socket. Calling it twice, or before open, does nothing.
pub fn (mut t UdpTransport) close() {
	if !t.open_ {
		return
	}
	t.conn.close() or {}
	t.open_ = false
}

// query sends one message and returns the reply and the elapsed milliseconds.
//
// The clock starts before the write and stops when a reply whose id matches
// arrives. Replies with any other id are discarded rather than timed: a late
// answer to a previous query would otherwise be recorded as an implausibly fast
// sample for this one, which is a wrong number rather than a missing one.
pub fn (mut t UdpTransport) query(msg []u8) !([]u8, f64) {
	if !t.open_ {
		return error('udp transport used before open()')
	}
	if msg.len < 2 {
		return error('query message is ${msg.len} octets, too short to carry an id')
	}
	want_id := be16(msg, 0)

	sw := time.new_stopwatch()
	t.conn.write(msg)!

	mut buf := []u8{len: max_udp_response}
	for _ in 0 .. max_stale_datagrams {
		n, _ := t.conn.read(mut buf)!
		elapsed := sw.elapsed()
		if n >= header_size && be16(buf, 0) == want_id {
			return buf[..n].clone(), f64(elapsed.microseconds()) / 1000.0
		}
		// A discarded datagram does not buy more time. Without this the caller's
		// timeout would be a per-read budget rather than a per-query one, and
		// the scheduler's pacing would be built on a number that does not hold.
		if elapsed >= t.target.timeout {
			return error('timed out after ${elapsed.milliseconds()} ms discarding replies with other ids')
		}
	}
	return error('no reply with id ${want_id} after ${max_stale_datagrams} datagrams')
}

// ── TCP ──────────────────────────────────────────────────────────────────────
pub struct TcpTransport {
mut:
	conn   &net.TcpConn = unsafe { nil }
	target Target
	open_  bool
}

// name is the label this transport carries into the output.
pub fn (t TcpTransport) name() string {
	return 'tcp'
}

// reusable is true: RFC 1035 § 4.2.2 allows several queries on one connection,
// which is what makes amortising the handshake measurable.
pub fn (t TcpTransport) reusable() bool {
	return true
}

// open pays for the TCP handshake. Whoever measures a fresh-connection variant
// must time this call, not just query().
pub fn (mut t TcpTransport) open(target Target) ! {
	t.close()
	t.conn = net.dial_tcp(target.dial_address()!)!
	t.conn.set_read_timeout(target.timeout)
	t.conn.set_write_timeout(target.timeout)
	t.target = target
	t.open_ = true
}

// close releases the connection. Calling it twice, or before open, does nothing.
pub fn (mut t TcpTransport) close() {
	if !t.open_ {
		return
	}
	t.conn.close() or {}
	t.open_ = false
}

// query frames the message per RFC 1035 § 4.2.2: a two-octet big-endian length
// ahead of the message, in both directions.
//
// There is no id check here. TCP delivers one reply per query in order on a
// stream, so an out-of-order match is not expressible the way it is over UDP.
pub fn (mut t TcpTransport) query(msg []u8) !([]u8, f64) {
	if !t.open_ {
		return error('tcp transport used before open()')
	}
	if msg.len > 0xffff {
		return error('query message is ${msg.len} octets, over the 65535 the length prefix can express')
	}

	mut framed := []u8{cap: msg.len + 2}
	push_u16(mut framed, u16(msg.len))
	framed << msg

	sw := time.new_stopwatch()
	t.conn.write(framed)!

	mut prefix := []u8{len: 2}
	read_exact(mut t.conn, mut prefix)!
	length := int(be16(prefix, 0))
	if length == 0 {
		return error('peer declared a zero-length response')
	}

	mut body := []u8{len: length}
	read_exact(mut t.conn, mut body)!
	ms := f64(sw.elapsed().microseconds()) / 1000.0

	return body, ms
}

// read_exact fills buf completely. A single TcpConn.read is free to return
// fewer octets than asked for, and treating a short read as the whole response
// is the classic way to turn a stream into a corrupt message.
//
// The read goes into a chunk sized to what is still missing, never into a
// full-size scratch buffer: over-reading would swallow the front of the next
// response on a connection that carries several queries.
//
// It cannot read straight into `buf[got..]` either. V clones a slice
// implicitly, so the socket would fill a copy and this loop would never
// terminate. See docs/V-NOTES.md.
fn read_exact(mut conn net.TcpConn, mut buf []u8) ! {
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

// ── TCP connect timing, for the edge probe ───────────────────────────────────

// edge_connect_timeout is the budget for one CDN connect.
// docs/METHODOLOGY.md § Timeouts.
pub const edge_connect_timeout = 2 * time.second

struct ConnectOutcome {
	ms  f64
	err string
}

// connect_ms opens a TCP connection, times it, and closes it immediately.
//
// Connect only: never a TLS handshake and never a request. The edge probe
// measures the distance to the address a resolver chose, and a handshake would
// fold the server's own behaviour into that number.
//
// The connect runs in its own thread and the caller waits on a channel with a
// deadline. That is not concurrency for speed, it is the only way to bound it:
// V's net.dial_tcp performs a blocking connect on the default build path, with
// no timeout parameter, so a CDN address that black-holes 443 would stall the
// run for however long the operating system takes to give up, which on Linux is
// over two minutes. The abandoned thread ends on its own when the kernel does.
pub fn connect_ms(address string, budget time.Duration) !f64 {
	ch := chan ConnectOutcome{ cap: 1 }

	spawn fn (address string, ch chan ConnectOutcome) {
		sw := time.new_stopwatch()
		mut conn := net.dial_tcp(address) or {
			ch <- ConnectOutcome{
				err: err.msg()
			}
			return
		}
		elapsed := f64(sw.elapsed().microseconds()) / 1000.0
		conn.close() or {}
		ch <- ConnectOutcome{
			ms: elapsed
		}
	}(address, ch)
	select {
		outcome := <-ch {
			if outcome.err != '' {
				return error(outcome.err)
			}
			return outcome.ms
		}
		budget {
			return error('no connection to ${address} within ${budget.milliseconds()} ms')
		}
	}
	return error('connect to ${address} ended without an outcome')
}
