module core

// The request and response path is verified by hand against live endpoints,
// because a mock would only prove the client talks to the mock. What is
// asserted here is the framing, which is where a loose parser turns some other
// server's bytes into something that looks like a DNS message.
fn test_a_response_without_a_length_is_refused() {
	if length := content_length(map[string]string{}) {
		assert false, 'expected an error, got ${length}'
	} else {
		assert err.msg().contains('no content-length')
	}
}

fn test_chunked_is_refused_rather_than_half_read() {
	// Refusing beats half-implementing. A transfer encoding parsed loosely
	// produces a body that looks like a DNS message and is not one, and the
	// parser downstream would then be decoding chunk headers as wire format.
	if length := content_length({
		'transfer-encoding': 'chunked'
	}) {
		assert false, 'expected an error, got ${length}'
	} else {
		assert err.msg().contains('transfer-encoding')
	}
}

fn test_a_length_a_dns_message_cannot_have_is_refused() {
	// 65535 is what the length field of a DNS message can express. Anything
	// claiming more is not a reply worth reading into memory.
	if length := content_length({
		'content-length': '70000'
	}) {
		assert false, 'expected an error, got ${length}'
	} else {
		assert err.msg().contains('over the 65535')
	}

	if length := content_length({
		'content-length': '0'
	}) {
		assert false, 'expected an error, got ${length}'
	} else {
		assert err.msg().contains('content-length of 0')
	}
}

fn test_a_plain_length_is_read() ! {
	assert content_length({
		'content-length': '49'
	})! == 49
}

fn test_an_http_status_is_recovered_from_the_error() {
	// Quad9 answers 505 to every HTTP/1.1 request because it serves DoH over h2
	// only. That is an answer, and the caller has to be able to tell it from a
	// socket that went quiet, so the status travels in the message.
	assert http_status_of('doh endpoint answered HTTP 505')? == 505
	assert http_status_of('doh endpoint answered HTTP 429')? == 429

	assert http_status_of('connection closed inside the HTTP head') == none
	assert http_status_of('doh response carried no content-length') == none
}

fn test_a_doh_transport_used_before_open_is_an_error() {
	mut t := DohTransport{
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

fn test_a_doh_transport_without_a_path_refuses_to_open() {
	mut t := DohTransport{
		hostname: 'dns.example.net'
		ca_bundle: '/dev/null'
	}

	if _ := t.open(Target{ ip: '192.0.2.1', port: 443 }) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('request path')
	}
}
