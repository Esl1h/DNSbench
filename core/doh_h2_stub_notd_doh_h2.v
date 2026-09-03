module core

// The default build: no libcurl, no HTTP/2, the "single static binary, no
// runtime dependencies" guarantee README.md states first unbroken. This is
// what `open()` in core/doh_h2_d_doh_h2.v's public API resolves to unless
// the binary was built with `-d doh_h2`, in which case that file's own
// content replaces this one, per V's `_d_<flag>.v` / `_notd_<flag>.v`
// filename convention: exactly one of the two is ever compiled in.
//
// The guard clauses below match the real implementation's on purpose, so
// core/doh_h2_test.v exercises the same behaviour and the same error text
// regardless of which build produced the binary under test.
pub const doh2_http_version = '2'

pub struct DohH2Transport {
mut:
	open_ bool
pub:
	hostname  string
	path      string
	ca_bundle string
}

// name is the label this transport carries into the output, the same one
// core/doh_h2_d_doh_h2.v's real implementation uses.
pub fn (t DohH2Transport) name() string {
	return 'doh'
}

// reusable matches the real implementation's answer; it is never asked in
// this build, since open() always fails first.
pub fn (t DohH2Transport) reusable() bool {
	return true
}

// open runs the same guard clauses the real implementation does, then
// refuses: this binary was not built with -d doh_h2.
pub fn (mut t DohH2Transport) open(target Target) ! {
	if t.path == '' {
		return error('doh_h2 transport needs a request path')
	}
	if t.hostname == '' {
		return error('doh_h2 transport needs a verification hostname')
	}
	if t.ca_bundle == '' {
		return error('doh_h2 transport needs a CA bundle; V loads no system trust store')
	}
	return error('doh_h2 transport unavailable: this binary was built without HTTP/2 support (build with -d doh_h2)')
}

// query is unreachable in this build: open() always fails first, so nothing
// ever marks this transport open enough to call query() on. Kept only to
// satisfy the same public shape the real implementation has.
pub fn (mut t DohH2Transport) query(msg []u8) !([]u8, f64) {
	if !t.open_ {
		return error('doh_h2 transport used before open()')
	}
	return error('doh_h2 transport unavailable: this binary was built without HTTP/2 support (build with -d doh_h2)')
}

// close does nothing: open() never leaves anything behind to release.
pub fn (mut t DohH2Transport) close() {
}
