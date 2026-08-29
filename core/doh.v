module core

import net
import net.ssl
import strings
import time

// DNS over HTTPS, RFC 8484.
//
// The request is written by hand rather than through `net.http`, for the same
// reason DoT dials an IP literal: `net.http` resolves the URL's hostname
// through the system resolver, which would put a lookup inside every latency
// sample and, worse, route it through a resolver that may itself be under test.
// Here the address is dialled directly, the certificate is verified against the
// hostname from the catalog, and that hostname travels again in the Host header
// so the server can route the request.
//
// The version is HTTP/1.1 and it is labelled as such in the output. V's stdlib
// has no h2 client, and comparing an HTTP/1.1 measurement against a browser's
// real h2 behaviour would be misleading. docs/ARCHITECTURE.md § Transport
// support matrix.

// doh_http_version is what the output records for every DoH result. It is a
// constant because it is a limitation, not a negotiation.
pub const doh_http_version = '1.1'

// max_doh_response bounds a response body. A DNS message cannot exceed the
// 65535 its length field can express, and anything claiming more is not a
// reply this tool should be reading into memory.
const max_doh_response = 65535

// DohTransport is DNS over HTTPS on port 443.
pub struct DohTransport {
mut:
	tcp    &net.TcpConn = unsafe { nil }
	tls    &ssl.SSLConn = unsafe { nil }
	target Target
	open_  bool

	// hostname is both the certificate's expected name and the Host header.
pub:
	hostname string
	// path is the request target, `/dns-query` for almost every provider.
	path      string
	ca_bundle string
}

// name is the label this transport carries into the output.
pub fn (t DohTransport) name() string {
	return 'doh'
}

// reusable is true: HTTP/1.1 keep-alive carries several requests on one
// connection, which is how a browser or a stub resolver would use it.
pub fn (t DohTransport) reusable() bool {
	return true
}

// open pays for the TCP handshake and the TLS handshake.
pub fn (mut t DohTransport) open(target Target) ! {
	t.close()

	if t.path == '' {
		return error('doh transport needs a request path')
	}

	tcp, tls := dial_tls(target, t.hostname, t.ca_bundle)!
	t.tcp = tcp
	t.tls = tls
	t.target = target
	t.open_ = true
}

// query POSTs one DNS message and reads the reply out of the response body.
//
// POST rather than GET: RFC 8484 allows both, but GET carries the query
// base64url-encoded in the URL, which makes the request cacheable by anything
// in between. A cached answer is not a measurement of a resolver.
pub fn (mut t DohTransport) query(msg []u8) !([]u8, f64) {
	if !t.open_ {
		return error('doh transport used before open()')
	}

	mut req := strings.new_builder(256)
	req.write_string('POST ${t.path} HTTP/1.1\r\n')
	req.write_string('host: ${t.hostname}\r\n')
	req.write_string('accept: application/dns-message\r\n')
	req.write_string('content-type: application/dns-message\r\n')
	req.write_string('content-length: ${msg.len}\r\n')
	req.write_string('\r\n')

	mut framed := req.str().bytes()
	framed << msg

	sw := time.new_stopwatch()
	t.tls.write(framed)!

	status, headers := read_http_head(mut t.tls)!
	if status != 200 {
		return error('doh endpoint answered HTTP ${status}')
	}

	length := content_length(headers)!
	mut body := []u8{len: length}
	read_exact_tls(mut t.tls, mut body)!
	ms := f64(sw.elapsed().microseconds()) / 1000.0

	return body, ms
}

// close tears down TLS and the socket under it.
pub fn (mut t DohTransport) close() {
	if !t.open_ {
		return
	}
	t.tls.shutdown() or {}
	t.open_ = false
}

// read_http_head reads the status line and headers, one octet at a time.
//
// Byte at a time is deliberate and is not a performance question at this size:
// the body must be left untouched in the socket for the caller to read by
// Content-Length. A buffered read would swallow the front of it, and on a
// keep-alive connection carrying the next response as well.
fn read_http_head(mut conn ssl.SSLConn) !(int, map[string]string) {
	mut head := []u8{cap: 1024}
	mut one := []u8{len: 1}

	for {
		n := conn.read(mut one)!
		if n <= 0 {
			return error('connection closed inside the HTTP head')
		}
		head << one[0]
		if head.len >= 4 && head[head.len - 4] == `\r` && head[head.len - 3] == `\n` && head[head.len - 2] == `\r` && head[head.len - 1] == `\n` {
			break
		}
		if head.len > 8192 {
			return error('HTTP head longer than 8192 octets')
		}
	}

	lines := head.bytestr().split('\r\n').filter(it != '')
	if lines.len == 0 {
		return error('empty HTTP response')
	}

	// "HTTP/1.1 200 OK"
	parts := lines[0].split(' ')
	if parts.len < 2 {
		return error('malformed status line "${lines[0]}"')
	}
	status := parts[1].int()

	mut headers := map[string]string{}
	for line in lines[1..] {
		key, value := line.split_once(':') or { continue }
		headers[key.to_lower().trim_space()] = value.trim_space()
	}

	return status, headers
}

// content_length is the only framing this client accepts.
//
// A DoH answer is one small DNS message and every endpoint sends it with a
// length. Refusing chunked is better than half-implementing it: a transfer
// encoding parsed loosely produces a body that looks like a DNS message and is
// not one.
fn content_length(headers map[string]string) !int {
	if 'transfer-encoding' in headers {
		return error('doh endpoint used transfer-encoding ${headers['transfer-encoding']}, which this client does not read')
	}
	raw := headers['content-length'] or { return error('doh response carried no content-length') }
	length := raw.int()
	if length <= 0 {
		return error('doh response declared a content-length of ${raw}')
	}
	if length > max_doh_response {
		return error('doh response declared ${length} octets, over the ${max_doh_response} a DNS message can be')
	}
	return length
}

// http_status_of recovers the status from the error query() produced.
//
// Threading a status out through a transport interface that returns bytes and
// milliseconds would mean a wider interface for one caller, so it travels in
// the message and is read back here rather than parsed at the call site.
pub fn http_status_of(message string) ?int {
	prefix := 'doh endpoint answered HTTP '
	if !message.contains(prefix) {
		return none
	}
	digits := message.all_after(prefix).trim_space()
	status := digits.int()
	if status == 0 {
		return none
	}
	return status
}
