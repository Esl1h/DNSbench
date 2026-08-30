module core

import rand

// DNS message encoding and decoding: RFC 1035 for the message format, RFC 6891
// for EDNS0.
//
// This module touches no socket. It turns names into wire bytes and wire bytes
// into structs, so that everything above it can be tested without a network.
pub const qtype_a = u16(1)
pub const qtype_ns = u16(2)
pub const qtype_cname = u16(5)
pub const qtype_soa = u16(6)
pub const qtype_txt = u16(16)
pub const qtype_aaaa = u16(28)
pub const qtype_opt = u16(41)

pub const qclass_in = u16(1)

pub const rcode_noerror = u8(0)
pub const rcode_formerr = u8(1)
pub const rcode_servfail = u8(2)
pub const rcode_nxdomain = u8(3)
pub const rcode_refused = u8(5)

// rcode_invalid is what `rcode` reports for a buffer too short to hold a
// header. A real header rcode is four bits, so it can never collide.
pub const rcode_invalid = u8(0xff)

const header_size = 12
const max_label_len = 63
const max_name_len = 255

// Each compression pointer must target an offset strictly below the previous
// pointer's target, which makes a cycle unrepresentable: the targets form a
// strictly decreasing sequence and cannot return to a visited offset.
//
// Comparing against the *current* offset instead would not be enough. That
// offset advances as labels are consumed after a jump, so 100 -> 50, labels to
// 90, then 90 -> 50 satisfies "backwards" at every step and loops forever.
//
// The jump ceiling stays as a cheap second guard against a message crafted to
// make the parser walk a long chain for every name in it.
const max_pointer_jumps = 64

pub struct Header {
pub:
	id     u16
	qr     bool
	opcode u8
	aa     bool
	tc     bool
	rd     bool
	ra     bool
	ad     bool
	cd     bool
	rcode  u8
	// Section counts as declared by the header, which is not necessarily what
	// the message actually carries. Parsing enforces the agreement.
	qdcount u16
	ancount u16
	nscount u16
	arcount u16
}

// Question names are returned without a trailing dot, with the root zone as
// ".". `google.com`, not `google.com.`.
pub struct Question {
pub:
	name   string
	qtype  u16
	qclass u16
}

// ResourceRecord keeps rdata as raw bytes. Decoding it depends on the type and
// belongs to whoever asked for that type, not here.
pub struct ResourceRecord {
pub:
	name   string
	rtype  u16
	rclass u16
	ttl    u32
	rdata  []u8
	// Where rdata begins in the message it was parsed from. A name inside rdata,
	// a CNAME target above all, may carry a compression pointer into any earlier
	// part of that message, so decoding it needs the whole buffer and this
	// offset rather than the rdata slice on its own.
	rdata_off int
}

pub struct Response {
pub:
	header     Header
	question   []Question
	answer     []ResourceRecord
	authority  []ResourceRecord
	additional []ResourceRecord
}

@[params]
pub struct QueryOpts {
pub:
	id               u16 // 0 is a legitimate id; callers wanting randomness use build_query
	rd               bool = true
	ad               bool // kdig sets this by default; we do not
	cd               bool
	edns             bool // emit an OPT record, RFC 6891
	dnssec_ok        bool // the DO bit; implies edns, since DO has nowhere else to live
	udp_payload_size u16 = 1232 // the OPT class field; 1232 avoids IP fragmentation
	qclass           u16 = 1
}

// build_query encodes a standard recursive query with a random id and no OPT
// record: the smallest thing a resolver will answer.
//
// It returns an error rather than a best-effort message, because a name this
// module cannot encode is a caller bug that must not reach a socket as a
// silently malformed packet.
pub fn build_query(name string, qtype u16) ![]u8 {
	return build_query_opts(name, qtype, id: rand.u16())!
}

// build_query_opts is build_query with the header bits and EDNS0 under caller
// control. Fixing `id` is what makes a byte-for-byte test against a captured
// query possible.
pub fn build_query_opts(name string, qtype u16, opts QueryOpts) ![]u8 {
	qname := encode_name(name)!

	mut flags := u16(0)
	if opts.rd {
		flags |= 0x0100
	}
	if opts.ad {
		flags |= 0x0020
	}
	if opts.cd {
		flags |= 0x0010
	}

	with_opt := opts.edns || opts.dnssec_ok

	mut msg := []u8{cap: header_size + qname.len + 4 + 11}
	push_u16(mut msg, opts.id)
	push_u16(mut msg, flags)
	push_u16(mut msg, 1) // qdcount
	push_u16(mut msg, 0) // ancount
	push_u16(mut msg, 0) // nscount
	push_u16(mut msg, if with_opt { u16(1) } else { u16(0) })

	msg << qname
	push_u16(mut msg, qtype)
	push_u16(mut msg, opts.qclass)

	if with_opt {
		// RFC 6891 § 6.1.2: the OPT owner name is root, the class field carries
		// the requestor's UDP payload size, and the TTL field carries the
		// extended rcode, the version and the flags.
		msg << u8(0)
		push_u16(mut msg, qtype_opt)
		push_u16(mut msg, opts.udp_payload_size)
		push_u32(mut msg, if opts.dnssec_ok { u32(0x00008000) } else { u32(0) })
		push_u16(mut msg, 0) // rdlength: no options
	}

	return msg
}

// rcode reads the four-bit response code straight out of the header, for
// callers that need it before deciding whether a full parse is worth it.
//
// It reports `rcode_invalid` for a buffer too short to hold a header, rather
// than 0, because 0 is NOERROR and a truncated buffer is not a success.
pub fn rcode(buf []u8) u8 {
	if buf.len < header_size {
		return rcode_invalid
	}
	return buf[3] & 0x0f
}

// parse_response decodes a complete message. It is strict: a section shorter
// than its declared count, a name running past the end, or a compression
// pointer that does not point backwards are all errors.
//
// Being strict here is deliberate. A resolver that answers with a malformed
// message has told us something worth recording as a failure, and a parser that
// papers over it would turn that finding into a plausible-looking sample.
pub fn parse_response(buf []u8) !Response {
	hdr := parse_header(buf)!

	mut off := header_size
	mut questions := []Question{cap: int(hdr.qdcount)}
	for _ in 0 .. hdr.qdcount {
		name, next := decode_name(buf, off)!
		if next + 4 > buf.len {
			return error('question section truncated at offset ${next}')
		}
		questions << Question{
			name: name
			qtype: be16(buf, next)
			qclass: be16(buf, next + 2)
		}
		off = next + 4
	}

	answer, after_an := parse_rrs(buf, off, hdr.ancount)!
	authority, after_ns := parse_rrs(buf, after_an, hdr.nscount)!
	additional, _ := parse_rrs(buf, after_ns, hdr.arcount)!

	return Response{
		header: hdr
		question: questions
		answer: answer
		authority: authority
		additional: additional
	}
}

// a_addresses returns the IPv4 addresses of the answer section, in the order
// the server sent them.
//
// Order is preserved rather than sorted: a CDN puts the edge it wants used
// first, and the edge probe connects to what a client would have connected to.
pub fn (r Response) a_addresses() []string {
	mut out := []string{}
	for rr in r.answer {
		if rr.rtype != qtype_a || rr.rdata.len != 4 {
			continue
		}
		out << '${rr.rdata[0]}.${rr.rdata[1]}.${rr.rdata[2]}.${rr.rdata[3]}'
	}
	return out
}

// cname_targets returns the CNAME targets of the answer section, in order.
//
// It needs the buffer the response was parsed from, because a CNAME target is
// a name and names are compressible: the target is very often a pointer back
// to the question, and the rdata bytes alone cannot be read without it.
pub fn (r Response) cname_targets(buf []u8) ![]string {
	mut out := []string{}
	for rr in r.answer {
		if rr.rtype != qtype_cname {
			continue
		}
		name, _ := decode_name(buf, rr.rdata_off)!
		out << name
	}
	return out
}

// txt_strings returns the TXT records of the answer section, one string per
// record, in the order the server sent them.
//
// A TXT record's rdata is a sequence of character-strings, each a length octet
// followed by that many bytes, and a record carrying more than one of them
// means the parts are to be joined with nothing between: RFC 1035 § 3.3.14
// splits at 255 octets and says nothing about a separator. Cymru's origin
// answers arrive as one string, but joining rather than taking the first is
// what keeps a longer answer from being silently truncated.
pub fn (r Response) txt_strings() []string {
	mut out := []string{}
	for rr in r.answer {
		if rr.rtype != qtype_txt {
			continue
		}
		mut text := ''
		mut off := 0
		for off < rr.rdata.len {
			length := int(rr.rdata[off])
			off++
			if off + length > rr.rdata.len {
				break
			}
			text += rr.rdata[off..off + length].bytestr()
			off += length
		}
		out << text
	}
	return out
}

// parse_header decodes the fixed 12-octet header.
pub fn parse_header(buf []u8) !Header {
	if buf.len < header_size {
		return error('message is ${buf.len} octets, shorter than a ${header_size}-octet header')
	}
	flags := be16(buf, 2)
	return Header{
		id: be16(buf, 0)
		qr: flags & 0x8000 != 0
		opcode: u8((flags >> 11) & 0x0f)
		aa: flags & 0x0400 != 0
		tc: flags & 0x0200 != 0
		rd: flags & 0x0100 != 0
		ra: flags & 0x0080 != 0
		ad: flags & 0x0020 != 0
		cd: flags & 0x0010 != 0
		rcode: u8(flags & 0x000f)
		qdcount: be16(buf, 4)
		ancount: be16(buf, 6)
		nscount: be16(buf, 8)
		arcount: be16(buf, 10)
	}
}

// encode_name turns a presentation-format name into length-prefixed labels.
// A trailing dot is accepted and ignored; "." and "" both mean the root.
fn encode_name(name string) ![]u8 {
	if name == '' || name == '.' {
		return [u8(0)]
	}

	trimmed := name.trim_right('.')
	mut out := []u8{cap: trimmed.len + 2}
	for label in trimmed.split('.') {
		if label.len == 0 {
			return error('empty label in name "${name}"')
		}
		if label.len > max_label_len {
			return error('label "${label}" is ${label.len} octets, over the ${max_label_len} limit')
		}
		out << u8(label.len)
		out << label.bytes()
	}
	out << u8(0)

	if out.len > max_name_len {
		return error('name "${name}" encodes to ${out.len} octets, over the ${max_name_len} limit')
	}
	return out
}

// decode_name returns the name starting at `start` and the offset just past its
// on-the-wire encoding, which for a compressed name is past the pointer rather
// than past whatever it points at.
fn decode_name(buf []u8, start int) !(string, int) {
	mut labels := []string{}
	mut off := start
	mut after := -1
	mut jumps := 0
	mut total := 0
	// Every pointer target must fall below this, which starts past the end so
	// the first jump is unconstrained other than by pointing backwards.
	mut jump_ceiling := buf.len

	for {
		if off >= buf.len {
			return error('name at offset ${start} runs past the end of the message')
		}
		length := buf[off]

		if length == 0 {
			off++
			if after < 0 {
				after = off
			}
			break
		}

		if length & 0xc0 == 0xc0 {
			if off + 1 >= buf.len {
				return error('compression pointer at offset ${off} is truncated')
			}
			target := int(u16(length & 0x3f) << 8 | u16(buf[off + 1]))
			if after < 0 {
				after = off + 2
			}
			if target >= off {
				return error('compression pointer at offset ${off} points forward to ${target}')
			}
			if target >= jump_ceiling {
				return error('compression pointer at offset ${off} targets ${target}, not below the previous target ${jump_ceiling}')
			}
			jump_ceiling = target
			jumps++
			if jumps > max_pointer_jumps {
				return error('name at offset ${start} follows more than ${max_pointer_jumps} pointers')
			}
			off = target
			continue
		}

		if length > max_label_len {
			return error('label at offset ${off} declares ${length} octets, over the ${max_label_len} limit')
		}
		if off + 1 + int(length) > buf.len {
			return error('label at offset ${off} runs past the end of the message')
		}

		total += int(length) + 1
		if total > max_name_len {
			return error('name at offset ${start} exceeds ${max_name_len} octets')
		}

		labels << buf[off + 1..off + 1 + int(length)].bytestr()
		off += 1 + int(length)
	}

	if labels.len == 0 {
		return '.', after
	}
	return labels.join('.'), after
}

// parse_rrs decodes `count` resource records starting at `start`, returning
// them and the offset just past the last one.
fn parse_rrs(buf []u8, start int, count u16) !([]ResourceRecord, int) {
	mut out := []ResourceRecord{cap: int(count)}
	mut off := start

	for _ in 0 .. count {
		name, next := decode_name(buf, off)!
		if next + 10 > buf.len {
			return error('resource record header truncated at offset ${next}')
		}
		rdlength := int(be16(buf, next + 8))
		rdata_start := next + 10
		if rdata_start + rdlength > buf.len {
			return error('rdata at offset ${rdata_start} declares ${rdlength} octets, past the end of the message')
		}
		out << ResourceRecord{
			name: name
			rtype: be16(buf, next)
			rclass: be16(buf, next + 2)
			ttl: be32(buf, next + 4)
			rdata: buf[rdata_start..rdata_start + rdlength].clone()
			rdata_off: rdata_start
		}
		off = rdata_start + rdlength
	}

	return out, off
}

@[inline]
fn be16(buf []u8, off int) u16 {
	return u16(buf[off]) << 8 | u16(buf[off + 1])
}

@[inline]
fn be32(buf []u8, off int) u32 {
	return u32(buf[off]) << 24 | u32(buf[off + 1]) << 16 | u32(buf[off + 2]) << 8 | u32(buf[off + 3])
}

@[inline]
fn push_u16(mut buf []u8, v u16) {
	buf << u8(v >> 8)
	buf << u8(v)
}

@[inline]
fn push_u32(mut buf []u8, v u32) {
	buf << u8(v >> 24)
	buf << u8(v >> 16)
	buf << u8(v >> 8)
	buf << u8(v)
}
