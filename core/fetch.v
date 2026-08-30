module core

import net.urllib
import time

// One HTTPS GET, over a connection this tool verified itself.
//
// `net.http` is not used, and the reason is not style. V's HTTP client performs
// no certificate validation at all: an expired certificate, a self-signed one
// and one issued for another host all return 200. Verified here, against
// badssl.com, and recorded in docs/V-NOTES.md. Everything below therefore goes
// through the same `dial_tls` the DoT and DoH probes use, which verifies against
// the system trust store and against the hostname.
//
// The name is resolved through the machine's own resolver rather than by the
// C library, for the same reason the probes dial IP literals: the address has to
// be known before the socket is opened.

// max_fetch_bytes bounds a response body. The DNSCrypt catalog is under a
// megabyte; anything claiming eight is not what was asked for.
pub const max_fetch_bytes = 8 * 1024 * 1024

// max_redirects is how many hops are followed. Three is enough for a mirror
// that moved and short enough that a redirect loop stops rather than spins.
const max_redirects = 3

pub struct FetchSpec {
pub:
	url string
	// resolver is where the hostname is looked up, normally the machine's own.
	resolver  string
	ca_bundle string
	timeout   time.Duration = 15 * time.second
}

// fetch returns the body, or an error naming what went wrong.
pub fn fetch(spec FetchSpec) ![]u8 {
	mut url := spec.url
	for _ in 0 .. max_redirects + 1 {
		body, location := fetch_once(url, spec)!
		if location == '' {
			return body
		}
		if !location.starts_with('https://') {
			// A relative redirect, or one down to plaintext. Neither is followed:
			// the second would be a downgrade and the first is not something any
			// of the published mirrors does.
			return error('redirect to "${location}" is not followed')
		}
		url = location
	}
	return error('more than ${max_redirects} redirects')
}

// fetch_once returns either a body or the location to try next.
fn fetch_once(raw string, spec FetchSpec) !([]u8, string) {
	url := urllib.parse(raw)!
	if url.scheme != 'https' {
		// There is no plaintext path. A catalog fetched over HTTP would be
		// whatever the network decided to hand back.
		return error('only https is fetched, not "${url.scheme}"')
	}
	host := url.hostname()
	if host == '' {
		return error('"${raw}" has no host')
	}
	if spec.resolver == '' {
		return error('no resolver configured to look up ${host}')
	}

	addresses := ask_a(spec.resolver, host, spec.timeout)!
	if addresses.len == 0 {
		return error('${host} resolved to no address')
	}

	mut path := url.path
	if path == '' {
		path = '/'
	}
	if url.raw_query != '' {
		path += '?${url.raw_query}'
	}

	target := Target{
		ip: addresses[0]
		port: 443
		timeout: spec.timeout
	}
	mut tls := dial_tls_stream(target, host, spec.ca_bundle)!
	defer {
		tls.shutdown() or {}
	}

	request := 'GET ${path} HTTP/1.1\r\n' + 'host: ${host}\r\n' + 'user-agent: dnsbench\r\n' + 'accept: */*\r\n' + 'accept-encoding: identity\r\n' + 'connection: close\r\n\r\n'
	tls.write(request.bytes())!

	status, headers := read_http_head(mut tls)!
	if status in [301, 302, 303, 307, 308] {
		location := headers['location'] or { return error('redirect ${status} with no location') }
		return []u8{}, location
	}
	if status != 200 {
		return error('${raw} answered HTTP ${status}')
	}

	length := content_length_max(headers, max_fetch_bytes, 'response from ${host}')!
	mut body := []u8{len: length}
	read_exact_tls(mut tls, mut body)!
	return body, ''
}
