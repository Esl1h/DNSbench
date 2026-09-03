module core

import time

// DNS over HTTPS forced to HTTP/2, through libcurl: the one dependency this
// file alone brings in. core/doh.v writes HTTP/1.1 by hand because V's
// stdlib has no h2 client and every other transport in this project needs
// nothing beyond it; this file exists only because Quad9 and Mullvad serve
// DoH over h2 alone and answer HTTP/1.1 with a 505, which core/doh.v's own
// comment already named. docs/ROADMAP.md § Open decisions, decision 3.
//
// The address is still an IP literal dialled directly, never a hostname
// resolved mid-measurement: CURLOPT_RESOLVE pins the connection to it while
// the URL keeps the real hostname, so SNI and the Host libcurl sends both
// carry the name the certificate is verified against, the same split every
// other transport in this project keeps between "what to connect to" and
// "what to verify against".
$if $pkgconfig ( 'libcurl' ) {
	#pkgconfig libcurl
} $else {
	#flag -lcurl
}

#include <curl/curl.h>

fn C.curl_easy_init() voidptr

fn C.curl_easy_cleanup(voidptr)

fn C.curl_easy_setopt(voidptr, int, voidptr) int

fn C.curl_easy_perform(voidptr) int

fn C.curl_easy_getinfo(voidptr, int, voidptr) int

fn C.curl_easy_strerror(int) &char

fn C.curl_slist_append(voidptr, &char) voidptr

fn C.curl_slist_free_all(voidptr)

// doh2_http_version is what a successful query over this transport reports,
// on the same terms core/doh.v's doh_http_version is a constant rather than
// a negotiation: this transport only ever asks for HTTP/2 and only ever
// reports having gotten it.
pub const doh2_http_version = '2'

// max_doh2_response mirrors core/doh.v's own ceiling: a DNS message cannot
// exceed the 65535 its length field can express.
const max_doh2_response = 65535

// on_doh2_write is libcurl's CURLOPT_WRITEFUNCTION callback. userdata is the
// &[]u8 query() passed in as CURLOPT_WRITEDATA; curl_easy_perform is
// synchronous, so nothing else touches that buffer while this runs.
fn on_doh2_write(ptr voidptr, size usize, nmemb usize, userdata voidptr) usize {
	total := size * nmemb
	if total == 0 {
		return 0
	}
	mut buf := unsafe { &[]u8(userdata) }
	if buf.len + int(total) > max_doh2_response {
		// Refusing to grow past the ceiling is enough: curl reads a short
		// return as an error and aborts the transfer on its own.
		return 0
	}
	chunk := unsafe { (&u8(ptr)).vbytes(int(total)) }
	unsafe {
		buf.push_many(chunk.data, chunk.len)
	}
	return total
}

// DohH2Transport is DNS over HTTPS, forced to HTTP/2, RFC 8484 over RFC 9113.
pub struct DohH2Transport {
mut:
	curl    voidptr = unsafe { nil }
	resolve voidptr = unsafe { nil }
	headers voidptr = unsafe { nil }
	target  Target
	open_   bool
	// hostname is both the certificate's expected name and the URL's host;
	// CURLOPT_RESOLVE is what keeps the connection itself going to target.ip
	// rather than whatever the name resolves to.
pub:
	hostname  string
	path      string
	ca_bundle string
}

// name is the label this transport carries into the output.
pub fn (t DohH2Transport) name() string {
	return 'doh'
}

// reusable is true: libcurl keeps the connection, TLS session and HTTP/2
// stream multiplexing included, across calls to curl_easy_perform on the
// same handle, the same amortised-handshake shape core/doh.v's own
// DohTransport gives HTTP/1.1.
pub fn (t DohH2Transport) reusable() bool {
	return true
}

// open builds the one curl handle this transport holds for the run: the
// pinned resolve entry, the content-type header RFC 8484 requires, and every
// option that does not vary between queries.
pub fn (mut t DohH2Transport) open(target Target) ! {
	t.close()

	if t.path == '' {
		return error('doh_h2 transport needs a request path')
	}
	if t.hostname == '' {
		return error('doh_h2 transport needs a verification hostname')
	}
	if t.ca_bundle == '' {
		return error('doh_h2 transport needs a CA bundle; V loads no system trust store')
	}

	curl := C.curl_easy_init()
	if curl == unsafe { nil } {
		return error('curl_easy_init failed')
	}

	resolve_entry := '${t.hostname}:443:${target.ip}'
	t.resolve = C.curl_slist_append(unsafe { nil }, resolve_entry.str)
	t.headers = C.curl_slist_append(unsafe { nil }, c'content-type: application/dns-message')
	t.headers = C.curl_slist_append(t.headers, c'accept: application/dns-message')

	C.curl_easy_setopt(curl, C.CURLOPT_RESOLVE, t.resolve)
	C.curl_easy_setopt(curl, C.CURLOPT_HTTPHEADER, t.headers)
	C.curl_easy_setopt(curl, C.CURLOPT_HTTP_VERSION, voidptr(usize(C.CURL_HTTP_VERSION_2_0)))
	C.curl_easy_setopt(curl, C.CURLOPT_SSL_VERIFYPEER, voidptr(usize(1)))
	C.curl_easy_setopt(curl, C.CURLOPT_SSL_VERIFYHOST, voidptr(usize(2)))
	C.curl_easy_setopt(curl, C.CURLOPT_CAINFO, voidptr(t.ca_bundle.str))
	C.curl_easy_setopt(curl, C.CURLOPT_TIMEOUT_MS, voidptr(usize(target.timeout.milliseconds())))
	C.curl_easy_setopt(curl, C.CURLOPT_WRITEFUNCTION, voidptr(on_doh2_write))
	C.curl_easy_setopt(curl, C.CURLOPT_POST, voidptr(usize(1)))

	t.curl = curl
	t.target = target
	t.open_ = true
}

// query POSTs one DNS message and reads the reply out of the response body,
// on the same RFC 8484 terms core/doh.v's query() does: POST rather than GET,
// so nothing in between can serve a cached answer.
pub fn (mut t DohH2Transport) query(msg []u8) !([]u8, f64) {
	if !t.open_ {
		return error('doh_h2 transport used before open()')
	}

	url := 'https://${t.hostname}${t.path}'
	mut body := []u8{cap: max_doh2_response}

	C.curl_easy_setopt(t.curl, C.CURLOPT_URL, voidptr(url.str))
	C.curl_easy_setopt(t.curl, C.CURLOPT_POSTFIELDS, msg.data)
	C.curl_easy_setopt(t.curl, C.CURLOPT_POSTFIELDSIZE, voidptr(usize(msg.len)))
	C.curl_easy_setopt(t.curl, C.CURLOPT_WRITEDATA, voidptr(&body))

	sw := time.new_stopwatch()
	rc := C.curl_easy_perform(t.curl)
	ms := f64(sw.elapsed().microseconds()) / 1000.0
	if rc != 0 {
		msg2 := unsafe { cstring_to_vstring(C.curl_easy_strerror(rc)) }
		return error('doh_h2 request failed: ${msg2}')
	}

	mut status := 0
	C.curl_easy_getinfo(t.curl, C.CURLINFO_RESPONSE_CODE, voidptr(&status))
	if status != 200 {
		return error('doh endpoint answered HTTP ${status}')
	}
	if body.len == 0 {
		return error('doh_h2 endpoint answered with an empty body')
	}

	return body, ms
}

// close releases the curl handle and the header lists built for it. Calling
// it twice, or before open, does nothing.
pub fn (mut t DohH2Transport) close() {
	if !t.open_ {
		return
	}
	C.curl_slist_free_all(t.resolve)
	C.curl_slist_free_all(t.headers)
	C.curl_easy_cleanup(t.curl)
	t.open_ = false
}
