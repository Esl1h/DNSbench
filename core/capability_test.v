module core

fn test_a_validator_refuses_the_broken_signature_and_serves_it_unchecked() {
	// The pair that says yes: the resolver checked and refused, and handed the
	// same data over when told not to check.
	assert dnssec_verdict(rcode_servfail, rcode_noerror)? == true
}

fn test_answering_a_broken_signature_is_not_validating() {
	// Whatever the provider's page says. This is the measured half of the
	// measured-versus-declared split, and it is allowed to contradict a tag.
	assert dnssec_verdict(rcode_noerror, rcode_noerror)? == false
}

fn test_two_failures_are_unknown_rather_than_yes() {
	// Without the control, a zone that has simply broken or a path that eats the
	// response reads as every resolver validating, and 60 of the 100 capability
	// points get handed out for a fault. Absent is not false and it is not true.
	assert dnssec_verdict(rcode_servfail, rcode_servfail) == none
}

fn test_a_refusal_that_is_not_servfail_is_unknown() {
	// REFUSED is a resolver declining to serve this client at all. It says
	// nothing about validation, and reading it as a no would score a provider
	// on a question it never answered.
	assert dnssec_verdict(rcode_refused, rcode_noerror) == none
	assert dnssec_verdict(rcode_nxdomain, rcode_noerror) == none
}

fn test_nxdomain_is_a_block() {
	assert is_blocked(rcode_nxdomain, [])
	assert is_blocked(rcode_nxdomain, ['1.2.3.4'])
}

fn test_an_unroutable_stand_in_is_a_block() {
	assert is_blocked(rcode_noerror, ['0.0.0.0'])
	assert is_blocked(rcode_noerror, ['::'])
	assert is_blocked(rcode_noerror, ['1.2.3.4', '0.0.0.0'])
}

fn test_a_successful_empty_answer_is_a_block() {
	// The quiet one. A resolver that answers NOERROR with nothing in it has
	// refused without saying so, and reading only the rcode records that as a
	// normal resolution.
	assert is_blocked(rcode_noerror, [])
}

fn test_a_real_address_is_not_a_block() {
	assert !is_blocked(rcode_noerror, ['142.250.219.6'])
}

fn test_a_failure_is_not_filtering() {
	// A SERVFAIL is a broken path, not a policy. Counting it as filtering would
	// turn an outage into a feature, and would do it on the row of whichever
	// provider happened to be unreachable that minute.
	assert !is_blocked(rcode_servfail, [])
	assert !is_blocked(rcode_refused, [])
}

fn test_a_majority_decides_and_a_tie_does_not() {
	assert majority_verdict(2, 1)? == true
	assert majority_verdict(1, 2)? == false
	assert majority_verdict(3, 0)? == true

	// A tie is unknown, and so is a provider that decided nothing at all.
	// Guessing on a split would put 60 of the 100 capability points on which
	// node of an anycast fleet happened to answer.
	assert majority_verdict(1, 1) == none
	assert majority_verdict(0, 0) == none
}
