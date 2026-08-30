module catalog

import os
import crypto.ed25519
import crypto.blake2b
import encoding.base64

// The parser is asserted against the signature DNSCrypt actually publishes,
// captured in testdata/public-resolvers.md.minisig. The verification is
// asserted against a key generated here, because what has to be proven is that
// this code drives ed25519 correctly, and a fixture cannot show that a wrong
// signature is refused.
fn published_signature() !string {
	return os.read_file(os.join_path(@VMODROOT, 'testdata', 'public-resolvers.md.minisig'))!
}

fn test_the_published_key_parses() ! {
	key := parse_minisign_key(dnscrypt_minisign_key)!
	assert key.key_id.len == 8
	assert key.key.len == ed25519.public_key_size
	assert key.key_id.hex() == '1fe8b442180f62e7'
}

fn test_the_published_signature_parses() ! {
	signature := parse_minisign_signature(published_signature()!)!

	// `Ed` is the legacy algorithm and signs the file itself; `ED` signs its
	// BLAKE2b digest. Reading the wrong one would hash a file that was not
	// meant to be hashed and fail every valid signature.
	assert signature.algorithm == minisign_legacy
	assert signature.signature.len == ed25519.signature_size
	assert signature.global_signature.len == ed25519.signature_size

	// The signature and the key have to name the same key, and this pair does.
	key := parse_minisign_key(dnscrypt_minisign_key)!
	assert signature.key_id == key.key_id

	assert signature.trusted_comment.contains('file:public-resolvers.md')
}

fn test_a_key_of_the_wrong_size_is_refused() {
	if _ := parse_minisign_key(base64.url_encode('too short'.bytes())) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('octets')
	}
}

fn test_a_signature_that_is_not_four_lines_is_refused() {
	if _ := parse_minisign_signature('untrusted comment: nothing follows') {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('not the 4 the format defines')
	}
}

fn test_a_signature_without_a_trusted_comment_is_refused() ! {
	lines := published_signature()!.split_into_lines()
	mangled := [lines[0], lines[1], 'untrusted comment: not the trusted one', lines[3]].join('\n')
	if _ := parse_minisign_signature(mangled) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('trusted comment')
	}
}

// A signer, so that the verification can be exercised in both directions.
fn sign(content []u8, algorithm string, comment string) !(MinisignKey, MinisignSignature) {
	public, private := ed25519.generate_key()!
	key_id := [u8(1), 2, 3, 4, 5, 6, 7, 8]

	message := if algorithm == minisign_prehashed {
		mut digest := blake2b.new512()!
		digest.write(content)!
		digest.checksum()
	} else {
		content
	}
	signature := ed25519.sign(private, message)!

	mut vouched := signature.clone()
	vouched << comment.bytes()
	global := ed25519.sign(private, vouched)!

	return MinisignKey{
		key_id: key_id
		key: public
	}, MinisignSignature{
		algorithm: algorithm
		key_id: key_id
		signature: signature
		trusted_comment: comment
		global_signature: global
	}
}

fn test_both_algorithms_verify() ! {
	content := 'the catalog, as published'.bytes()
	for algorithm in [minisign_legacy, minisign_prehashed] {
		key, signature := sign(content, algorithm, 'timestamp:1 file:x')!
		verify_minisign(content, signature, key)!
	}
}

fn test_one_changed_octet_fails() ! {
	content := 'the catalog, as published'.bytes()
	key, signature := sign(content, minisign_legacy, 'timestamp:1 file:x')!

	mut tampered := content.clone()
	tampered[3] = tampered[3] ^ 0x01
	if _ := verify_minisign(tampered, signature, key) {
		assert false, 'a changed octet verified'
	} else {
		assert err.msg().contains('does not match the content')
	}
}

fn test_a_rewritten_trusted_comment_fails() ! {
	// Without the second check the comment could be rewritten under a valid
	// file signature, and the comment is what a reader is shown: the filename
	// and the timestamp.
	content := 'the catalog, as published'.bytes()
	key, signature := sign(content, minisign_legacy, 'timestamp:1 file:x')!

	lying := MinisignSignature{
		...signature
		trusted_comment: 'timestamp:99 file:something-else'
	}
	if _ := verify_minisign(content, lying, key) {
		assert false, 'a rewritten trusted comment verified'
	} else {
		assert err.msg().contains('trusted comment')
	}
}

fn test_a_signature_from_another_key_fails_before_any_maths() ! {
	content := 'the catalog, as published'.bytes()
	key, signature := sign(content, minisign_legacy, 'timestamp:1 file:x')!

	stranger := MinisignKey{
		key_id: [u8(9), 9, 9, 9, 9, 9, 9, 9]
		key: key.key
	}
	if _ := verify_minisign(content, signature, stranger) {
		assert false, 'a signature from another key verified'
	} else {
		assert err.msg().contains('was made by key')
	}
}
