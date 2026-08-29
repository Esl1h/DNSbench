module core

// The two capability probes. Neither produces a latency distribution: each asks
// one question and reads the answer's shape, so what lives here is the reading,
// and the asking lives with the other probes in the command layer.

// dnssec_verdict decides whether a resolver validates, from two answers to the
// same name.
//
// The first query is ordinary and the second sets the CD bit, which tells a
// validating resolver to hand back the data without checking it. Against a
// deliberately broken signature that pair separates the three states cleanly:
//
//   plain SERVFAIL, cd NOERROR  the resolver checked and refused. It validates.
//   plain NOERROR               it did not check, whatever it says it does.
//   both SERVFAIL               something else is wrong, upstream or on the
//                               path, and the answer is unknown rather than no.
//
// The control matters. Without it a zone that has simply broken, or a network
// that eats the response, reads as every resolver validating, and a capability
// worth 60 of the 100 capability points would be handed out for a fault.
pub fn dnssec_verdict(plain u8, with_cd u8) ?bool {
	if plain == rcode_noerror {
		return false
	}
	if plain != rcode_servfail {
		// Some other refusal, and not the shape of a validation failure.
		return none
	}
	if with_cd != rcode_noerror {
		return none
	}
	return true
}

// blocked_addresses are the answers a filtering resolver substitutes for a name
// it will not resolve. docs/METHODOLOGY.md § filter.
pub const blocked_addresses = ['0.0.0.0', '::']

// is_blocked reads whether an answer is a block rather than a resolution.
//
// A block is NXDOMAIN, an unroutable address standing in for the real one, or
// NOERROR with nothing in it. The last is the quiet one: a resolver that
// answers successfully with an empty answer section has refused without saying
// so, and reading only the rcode would record that as a normal resolution.
pub fn is_blocked(code u8, addresses []string) bool {
	if code == rcode_nxdomain {
		return true
	}
	if code != rcode_noerror {
		// A SERVFAIL is a failure, not a policy. Counting it as filtering would
		// turn a broken path into a feature.
		return false
	}
	if addresses.len == 0 {
		return true
	}
	for address in addresses {
		if address in blocked_addresses {
			return true
		}
	}
	return false
}

// majority_verdict resolves several readings of the same capability into one.
//
// It exists because at least one large anycast fleet does not answer
// consistently. Asked ten times in a row whether it validates, AdGuard answered
// SERVFAIL nine times and NOERROR once, and the control query answered SERVFAIL
// five times out of ten. A single-shot probe against that is a coin flip that
// reports a different capability each run.
//
// A tie, or nothing decided at all, is unknown. Guessing on a split would put a
// capability worth 60 points on the outcome of which node answered.
pub fn majority_verdict(yes int, no int) ?bool {
	if yes == no {
		return none
	}
	return yes > no
}
