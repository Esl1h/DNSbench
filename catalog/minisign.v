module catalog

import crypto.blake2b
import crypto.ed25519
import encoding.base64

// minisign verification.
//
// The DNSCrypt resolver list is published with a detached minisign signature and
// a public key its authors have had for years. That signature is the only thing
// standing between a fetched catalog and whatever a network happened to hand
// back, so verification is mandatory and there is no flag to skip it:
// docs/DATA.md § Layer 2.
//
// The format is small enough to read in full. A public key is
//
//     base64( "Ed" || key_id[8] || public_key[32] )
//
// and a signature file is four lines:
//
//     untrusted comment: <anything>
//     base64( algorithm[2] || key_id[8] || signature[64] )
//     trusted comment: <text the signer vouches for>
//     base64( global_signature[64] )
//
// The global signature covers the first signature concatenated with the trusted
// comment, which is what makes the comment trusted: without checking it, an
// attacker could keep a valid signature and rewrite the filename and timestamp
// beside it.

// The two algorithms minisign emits. `Ed` signs the file itself; `ED` signs its
// BLAKE2b-512 digest, which is what recent minisign produces by default.
pub const minisign_legacy = 'Ed'

pub const minisign_prehashed = 'ED'

const key_id_size = 8

pub struct MinisignKey {
pub:
	key_id []u8
	key    []u8
}

pub struct MinisignSignature {
pub:
	algorithm        string
	key_id           []u8
	signature        []u8
	trusted_comment  string
	global_signature []u8
}

// parse_minisign_key reads the single-line public key as it is published.
pub fn parse_minisign_key(encoded string) !MinisignKey {
	blob := base64.decode(encoded.trim_space())
	if blob.len != 2 + key_id_size + ed25519.public_key_size {
		return error('minisign public key is ${blob.len} octets, not ${2 + key_id_size + ed25519.public_key_size}')
	}
	algorithm := blob[0..2].bytestr()
	if algorithm != minisign_legacy {
		return error('minisign public key declares algorithm "${algorithm}", not ${minisign_legacy}')
	}
	return MinisignKey{
		key_id: blob[2..2 + key_id_size]
		key: blob[2 + key_id_size..]
	}
}

// parse_minisign_signature reads a detached .minisig file.
pub fn parse_minisign_signature(text string) !MinisignSignature {
	lines := text.split_into_lines().filter(it.trim_space() != '')
	if lines.len < 4 {
		return error('minisign signature has ${lines.len} lines, not the 4 the format defines')
	}

	blob := base64.decode(lines[1].trim_space())
	if blob.len != 2 + key_id_size + ed25519.signature_size {
		return error('minisign signature line is ${blob.len} octets, not ${2 + key_id_size + ed25519.signature_size}')
	}
	algorithm := blob[0..2].bytestr()
	if algorithm !in [minisign_legacy, minisign_prehashed] {
		return error('minisign signature declares algorithm "${algorithm}", which is neither ${minisign_legacy} nor ${minisign_prehashed}')
	}

	marker := 'trusted comment:'
	if !lines[2].starts_with(marker) {
		return error('minisign signature line 3 is not a trusted comment')
	}
	global := base64.decode(lines[3].trim_space())
	if global.len != ed25519.signature_size {
		return error('minisign global signature is ${global.len} octets, not ${ed25519.signature_size}')
	}

	return MinisignSignature{
		algorithm: algorithm
		key_id: blob[2..2 + key_id_size]
		signature: blob[2 + key_id_size..]
		trusted_comment: lines[2].all_after_first(marker).trim_left(' ')
		global_signature: global
	}
}

// verify_minisign checks the content against the signature and the key, and
// checks the trusted comment along with it.
//
// It returns an error rather than a bool, because every caller of this has one
// correct reaction to a failure and it is not to carry on with a value.
pub fn verify_minisign(content []u8, signature MinisignSignature, key MinisignKey) ! {
	if signature.key_id != key.key_id {
		return error('signature was made by key ${signature.key_id.hex()}, not by ${key.key_id.hex()}')
	}

	message := if signature.algorithm == minisign_prehashed {
		mut digest := blake2b.new512()!
		digest.write(content)!
		digest.checksum()
	} else {
		content
	}

	if !ed25519.verify(key.key, message, signature.signature)! {
		return error('signature does not match the content')
	}

	// The trusted comment carries the filename and timestamp a reader is shown.
	// Leaving it unchecked would let it be rewritten under a valid signature.
	mut vouched := signature.signature.clone()
	vouched << signature.trusted_comment.bytes()
	if !ed25519.verify(key.key, vouched, signature.global_signature)! {
		return error('trusted comment does not match its signature')
	}
}
