module core

import os

// Assertions against real captured bytes. The fixtures in testdata/ are the
// exact octets kdig 3.5.7 put on the wire and the exact octets 1.1.1.1 sent
// back, relayed verbatim by tools/capture_wire.py. Nothing here was typed out
// from what this implementation happens to produce.
//
// Where a test needs a malformed message, it says so and builds one, because a
// well-behaved resolver will not send you a compression-pointer loop on request.
fn capture(name string) ![]u8 {
	return os.read_bytes(os.join_path(@VMODROOT, 'testdata', name))!
}

// ── build_query ──────────────────────────────────────────────────────────────
fn test_build_query_reproduces_a_captured_kdig_query() ! {
	// testdata/minimal.query.bin, from:
	//   kdig +noedns +nocookie -p 15353 @127.0.0.1 google.com A
	// id 0xbdeb, flags 0x0120. kdig sets AD as well as RD by default, so the
	// test asks for it explicitly: our own default is RD alone.
	want := capture('minimal.query.bin')!
	got := build_query_opts('google.com', qtype_a, id: 0xbdeb, ad: true)!

	assert got == want
	assert got.len == 28
}

fn test_build_query_with_edns_reproduces_a_captured_kdig_query() ! {
	// testdata/dnssec.query.bin, from:
	//   kdig +dnssec -p 15353 @127.0.0.1 google.com A
	// The OPT record carries kdig's default payload size of 1232 in the class
	// field and the DO bit in the TTL field, which is also our default.
	want := capture('dnssec.query.bin')!
	got := build_query_opts('google.com', qtype_a, id: 0xb3b9, ad: true, dnssec_ok: true)!

	assert got == want
	assert got.len == 39
}

fn test_build_query_defaults_to_recursion_without_ad() ! {
	// The random id makes a byte comparison impossible, so this checks shape:
	// the same 28 octets, RD set, AD clear, no OPT record.
	got := build_query('google.com', qtype_a)!
	hdr := parse_header(got)!

	assert got.len == 28
	assert hdr.rd
	assert !hdr.ad
	assert !hdr.cd
	assert !hdr.qr
	assert hdr.qdcount == 1
	assert hdr.arcount == 0
}

fn test_build_query_rejects_an_empty_label() {
	// A silently malformed packet reaching a socket would surface later as an
	// unexplained loss sample, so this fails at the encoder.
	if _ := build_query_opts('google..com', qtype_a) {
		assert false
	} else {
		assert err.msg().contains('empty label')
	}
}

fn test_build_query_rejects_an_oversized_label() {
	long_label := 'a'.repeat(64)
	if _ := build_query_opts('${long_label}.com', qtype_a) {
		assert false
	} else {
		assert err.msg().contains('over the 63 limit')
	}
}

fn test_build_query_rejects_an_oversized_name() {
	// Five maximum-length labels: every label is legal on its own and the name
	// as a whole is not.
	long_name := 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.'.repeat(5)
	if _ := build_query_opts(long_name, qtype_a) {
		assert false
	} else {
		assert err.msg().contains('over the 255 limit')
	}
}

// ── parse_response ───────────────────────────────────────────────────────────
fn test_parse_minimal_response() ! {
	// testdata/minimal.response.bin: one A record, one compression pointer.
	buf := capture('minimal.response.bin')!
	r := parse_response(buf)!

	assert r.header.id == 0xbdeb
	assert r.header.qr
	assert r.header.rd
	assert r.header.ra
	assert !r.header.aa
	assert !r.header.tc
	assert !r.header.ad
	assert r.header.rcode == rcode_noerror
	assert r.header.qdcount == 1
	assert r.header.ancount == 1

	assert r.question.len == 1
	assert r.question[0].name == 'google.com'
	assert r.question[0].qtype == qtype_a
	assert r.question[0].qclass == qclass_in

	assert r.answer.len == 1
	// The owner name is the two-octet pointer 0xc00c back to offset 12.
	assert r.answer[0].name == 'google.com'
	assert r.answer[0].rtype == qtype_a
	assert r.answer[0].rclass == qclass_in
	assert r.answer[0].ttl == 230
	assert r.answer[0].rdata == [u8(172), 217, 172, 46]
}

fn test_parse_response_carrying_an_edns_opt_record() ! {
	// testdata/dnssec.response.bin. google.com has no DS, so there are no
	// RRSIGs and AD is clear; what this fixture proves is OPT round-tripping.
	buf := capture('dnssec.response.bin')!
	r := parse_response(buf)!

	assert r.header.arcount == 1
	assert !r.header.ad
	assert r.answer.len == 1
	assert r.answer[0].ttl == 229

	assert r.additional.len == 1
	opt := r.additional[0]
	// RFC 6891: OPT is owned by the root, its class field is the payload size,
	// and its TTL field holds the extended rcode, version and flags.
	assert opt.name == '.'
	assert opt.rtype == qtype_opt
	assert opt.rclass == 1232
	assert opt.ttl == 0x00008000
	assert opt.rdata.len == 0
}

fn test_parse_cname_chain_follows_pointers_into_earlier_rdata() ! {
	// testdata/cname.response.bin, from www.microsoft.com. The strongest
	// fixture in the set: the second record's owner name points into the first
	// record's rdata, and the second record's rdata itself ends in a pointer to
	// a suffix inside that same rdata. A parser that only handles a pointer at
	// offset 12 passes the other tests and fails this one.
	buf := capture('cname.response.bin')!
	r := parse_response(buf)!

	assert r.header.ancount == 3
	assert r.question[0].name == 'www.microsoft.com'
	assert r.answer.len == 3

	assert r.answer[0].name == 'www.microsoft.com'
	assert r.answer[0].rtype == qtype_cname
	assert r.answer[0].ttl == 3585
	assert r.answer[0].rdata.len == 35

	assert r.answer[1].name == 'www.microsoft.com-c-3.edgekey.net'
	assert r.answer[1].rtype == qtype_cname
	assert r.answer[1].ttl == 885
	assert r.answer[1].rdata.len == 25

	assert r.answer[2].name == 'e13678.dscb.akamaiedge.net'
	assert r.answer[2].rtype == qtype_a
	assert r.answer[2].ttl == 5
	assert r.answer[2].rdata == [u8(23), 192, 58, 93]
}

fn test_parse_nxdomain_with_soa_in_the_authority_section() ! {
	// testdata/nxdomain.response.bin: .example is reserved, so the root SOA
	// comes back with rcode 3 and an empty answer section.
	buf := capture('nxdomain.response.bin')!
	r := parse_response(buf)!

	assert r.header.rcode == rcode_nxdomain
	assert r.header.ad
	assert r.header.ancount == 0
	assert r.header.nscount == 1

	assert r.question[0].name == 'nxdomain-test-dnsbench.example'
	assert r.answer.len == 0

	assert r.authority.len == 1
	assert r.authority[0].name == '.'
	assert r.authority[0].rtype == qtype_soa
	assert r.authority[0].ttl == 86400
	assert r.authority[0].rdata.len == 64
}

// ── rcode ────────────────────────────────────────────────────────────────────
fn test_rcode_reads_the_header_without_a_full_parse() ! {
	assert rcode(capture('minimal.response.bin')!) == rcode_noerror
	assert rcode(capture('cname.response.bin')!) == rcode_noerror
	assert rcode(capture('nxdomain.response.bin')!) == rcode_nxdomain
}

fn test_rcode_of_a_short_buffer_is_not_noerror() {
	// Reporting 0 here would turn a truncated read into an apparent success.
	assert rcode([]u8{}) == rcode_invalid
	assert rcode([u8(0), 0, 0, 0]) == rcode_invalid
	assert rcode_invalid != rcode_noerror
}

// ── malformed input ──────────────────────────────────────────────────────────
fn test_parse_rejects_a_self_referential_compression_pointer() {
	// Hand-built: no resolver sends this, which is exactly why it has to be
	// constructed. The pointer at offset 12 targets offset 12, so a parser
	// without the backwards-only rule spins here forever.
	mut msg := [u8(0x12), 0x34, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0]
	msg << [u8(0xc0), 0x0c]

	if _ := parse_response(msg) {
		assert false
	} else {
		assert err.msg().contains('points forward')
	}
}

fn test_parse_rejects_a_forward_compression_pointer() {
	// The pointer at offset 12 targets offset 14, ahead of itself. Forward
	// pointers are what make loops expressible; refusing them makes a cycle
	// unrepresentable rather than merely guarded against.
	mut msg := [u8(0x12), 0x34, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0]
	msg << [u8(0xc0), 0x0e, 0x00, 0x00, 0x01, 0x00, 0x01]

	if _ := parse_response(msg) {
		assert false
	} else {
		assert err.msg().contains('points forward to 14')
	}
}

fn test_parse_rejects_a_truncated_message() ! {
	// A real response cut short mid-answer, which is what a partial read looks
	// like.
	full := capture('minimal.response.bin')!

	// Cut inside the question name.
	if _ := parse_response(full[..20]) {
		assert false
	} else {
		assert err.msg().contains('runs past the end')
	}

	// Cut inside the answer's rdata, which the record header says is 4 octets.
	if _ := parse_response(full[..full.len - 2]) {
		assert false
	} else {
		assert err.msg().contains('past the end of the message')
	}
}

fn test_parse_rejects_a_header_count_the_message_does_not_back_up() ! {
	// The header claims two answers where the message carries one. Trusting the
	// count would read past the end; trusting the bytes would silently disagree
	// with the header.
	mut msg := capture('minimal.response.bin')!
	msg[7] = 2

	if _ := parse_response(msg) {
		assert false
	} else {
		assert err.msg().contains('runs past the end')
	}
}

fn test_parse_header_rejects_a_buffer_shorter_than_a_header() {
	if _ := parse_header([]u8{}) {
		assert false
	} else {
		assert err.msg().contains('shorter than a 12-octet header')
	}
	if _ := parse_header([u8(0), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) {
		assert false
	} else {
		assert err.msg().contains('11 octets')
	}
}

fn test_parse_rejects_a_pointer_chain_that_cycles_while_going_backwards() {
	// Every pointer here targets an offset below the offset it sits at, so the
	// "points backwards" rule alone accepts the whole chain and the parser
	// loops. Only a rule on successive targets rejects it outright.
	//
	// Layout, hand-built because no resolver sends this:
	//   0..11   header, qdcount 0, ancount 2
	//   12      answer 1, owner root, TXT, 40 octets of rdata at 23..62
	//   25..27  label "aa"          } inside that rdata, reachable by pointer
	//   28..30  label "bb"          }
	//   31..32  pointer to 25       } closes the loop
	//   63..64  answer 2's owner name: pointer to 25
	//
	// Decoding answer 2 jumps 63 -> 25, walks the two labels to 31, and finds a
	// pointer back to 25. Target 25 is below offset 31, so it looks backwards,
	// but it is not below the previous target, which was also 25.
	mut msg := [u8(0x12), 0x34, 0x81, 0x80, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00]
	msg << u8(0x00) // 12: answer 1 owner is the root
	msg << [u8(0x00), 0x10] // 13: TXT
	msg << [u8(0x00), 0x01] // 15: IN
	msg << [u8(0x00), 0x00, 0x00, 0x00] // 17: ttl
	msg << [u8(0x00), 0x28] // 21: rdlength 40, rdata spans 23..62

	msg << [u8(0x00), 0x00] // 23, 24: filler
	msg << [u8(0x02), `a`, `a`] // 25
	msg << [u8(0x02), `b`, `b`] // 28
	msg << [u8(0xc0), 0x19] // 31: pointer back to 25
	for _ in 33 .. 63 {
		msg << u8(0x00)
	}

	msg << [u8(0xc0), 0x19] // 63: answer 2's owner, pointer to 25
	msg << [u8(0x00), 0x01] // 65: A
	msg << [u8(0x00), 0x01] // 67: IN
	msg << [u8(0x00), 0x00, 0x00, 0x00] // 69: ttl
	msg << [u8(0x00), 0x00] // 73: rdlength 0

	assert msg.len == 75

	if _ := parse_response(msg) {
		assert false
	} else {
		assert err.msg().contains('not below the previous target')
	}
}

fn test_the_answer_helpers_read_what_the_edge_probe_needs() ! {
	// The edge probe wants two things from a CDN answer: the address to connect
	// to, and the CNAME chain that says which CDN answered. Both come out of
	// testdata/cname.response.bin, whose second CNAME target is itself a
	// compression pointer, so the chain cannot be read from the rdata slices
	// alone.
	buf := capture('cname.response.bin')!
	r := parse_response(buf)!

	assert r.a_addresses() == ['23.192.58.93']
	assert r.cname_targets(buf)! == ['www.microsoft.com-c-3.edgekey.net', 'e13678.dscb.akamaiedge.net']
}

fn test_an_answer_with_no_address_yields_no_address() ! {
	// A CNAME-only answer, or an NXDOMAIN, has nothing to connect to. The edge
	// probe has to see an empty list rather than a zero address.
	buf := capture('nxdomain.response.bin')!
	r := parse_response(buf)!

	assert r.a_addresses().len == 0
	assert r.cname_targets(buf)!.len == 0
}

fn test_a_txt_record_is_read_out_of_its_character_strings() ! {
	// testdata/txt_origin.response.bin, from:
	//   kdig +noedns +nocookie TXT 175.44.46.189.origin.asn.cymru.com
	// Two records, because the address falls inside two announced prefixes, and
	// each one carries its string with a leading length octet that is not part
	// of the string.
	buf := capture('txt_origin.response.bin')!
	response := parse_response(buf)!

	strings := response.txt_strings()
	assert strings.len == 2
	assert strings[0] == '27699 | 189.46.0.0/16 | BR | lacnic | 2007-06-22'
	assert strings[1] == '27699 | 189.46.0.0/15 | BR | lacnic | 2007-06-22'
}

fn test_the_asn_name_record_is_read_whole() ! {
	// testdata/txt_asn.response.bin, from:
	//   kdig +noedns +nocookie TXT AS27699.asn.cymru.com
	buf := capture('txt_asn.response.bin')!
	response := parse_response(buf)!

	strings := response.txt_strings()
	assert strings.len == 1
	assert strings[0] == '27699 | BR | lacnic | 2003-08-25 | AS27699 - TELEFONICA BRASIL S.A, BR'
}
