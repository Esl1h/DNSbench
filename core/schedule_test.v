module core

import time

// The fairness rules in docs/METHODOLOGY.md are the reason this module exists,
// so they are asserted directly rather than inferred from a run. No socket and
// no real clock appear here.
const plan_seed = [u32(0x5eed), u32(0xd0d0)]

fn sample_spec() PlanSpec {
	return PlanSpec{
		provider_keys: ['cloudflare', 'google', 'quad9', 'adguard']
		probes: ['warm', 'cold']
		domains: ['google.com', 'youtube.com', 'wikipedia.org']
		rounds: 5
		seed: plan_seed
	}
}

// ── the plan ─────────────────────────────────────────────────────────────────
fn test_every_pair_is_queried_once_per_round_plus_one_warm_up() ! {
	spec := sample_spec()
	steps := build_plan(spec)!

	assert steps.len == (spec.rounds + 1) * spec.provider_keys.len * spec.probes.len * spec.domains.len
	assert steps.len == 144

	mut counted := map[string]int{}
	for s in steps {
		counted['${s.provider_key}/${s.probe}']++
	}
	assert counted.len == 8
	for pair, count in counted {
		// One query per domain per round: a round is a pass over the set.
		assert count == (spec.rounds + 1) * spec.domains.len, '${pair} appears ${count} times'
	}
}

fn test_the_warm_up_pass_is_discarded_and_comes_first() ! {
	// docs/METHODOLOGY.md § Discard the first sample: it carries handshake, ARP,
	// route setup and cache-fill costs that no later query pays.
	spec := sample_spec()
	steps := build_plan(spec)!

	mut discarded := map[string]int{}
	mut seen_counted := map[string]bool{}
	for s in steps {
		pair := '${s.provider_key}/${s.probe}'
		if s.discard {
			assert !seen_counted[pair], '${pair} was counted before its warm-up'
			assert s.round == 0
			discarded[pair]++
		} else {
			assert s.round >= 1
			seen_counted[pair] = true
		}
	}

	assert discarded.len == 8
	for pair, count in discarded {
		// A whole pass is discarded, not a single query: every name in the set
		// has to be warmed, not just the first one asked.
		assert count == spec.domains.len, '${pair} has ${count} warm-up queries'
	}
}

fn test_rounds_interleave_rather_than_batching_by_provider() ! {
	// The rule this exists for: provider A measured to completion, then B, then
	// C, makes A pay for cold caches and an unwarmed path while C benefits from
	// a network that has been in use for two minutes.
	//
	// Interleaving means every provider is queried once before any is queried a
	// second time, within each round.
	spec := sample_spec()
	steps := build_plan(spec)!

	for round in 0 .. spec.rounds + 1 {
		in_round := steps.filter(it.round == round)
		mut seen := []string{}
		for s in in_round {
			if s.provider_key !in seen {
				seen << s.provider_key
			}
		}
		assert seen.len == spec.provider_keys.len

		// Each provider's steps are contiguous within a round (its probes run
		// together), and no provider reappears after another has started.
		mut order := []string{}
		for s in in_round {
			if order.len == 0 || order.last() != s.provider_key {
				order << s.provider_key
			}
		}
		assert order.len == spec.provider_keys.len, 'a provider was revisited in round ${round}'
	}
}

fn test_the_provider_order_is_reshuffled_every_round() ! {
	// Shuffling once and reusing the order would leave whoever drew first place
	// first for the whole run, which is the batching problem in miniature.
	spec := sample_spec()
	steps := build_plan(spec)!

	mut orders := []string{}
	for round in 0 .. spec.rounds + 1 {
		mut order := []string{}
		for s in steps.filter(it.round == round) {
			if order.len == 0 || order.last() != s.provider_key {
				order << s.provider_key
			}
		}
		orders << order.join(',')
	}

	// With four providers and six rounds, all six orders being identical would
	// mean the shuffle never ran.
	mut distinct := []string{}
	for o in orders {
		if o !in distinct {
			distinct << o
		}
	}
	assert distinct.len > 1, 'every round used the same order: ${orders[0]}'
}

fn test_the_same_seed_produces_the_same_plan() ! {
	// A result nobody can re-derive from the metadata that travels with it is
	// an anecdote. docs/ARCHITECTURE.md § Design constraints.
	a := build_plan(sample_spec())!
	b := build_plan(sample_spec())!

	assert a.len == b.len
	for i in 0 .. a.len {
		assert a[i] == b[i], 'step ${i} differs between two runs of the same seed'
	}
}

fn test_a_different_seed_produces_a_different_plan() ! {
	a := build_plan(sample_spec())!

	mut other := sample_spec()
	other = PlanSpec{
		provider_keys: other.provider_keys
		probes: other.probes
		domains: other.domains
		rounds: other.rounds
		seed: [u32(1), u32(2)]
	}
	b := build_plan(other)!

	mut same := true
	for i in 0 .. a.len {
		if a[i] != b[i] {
			same = false
			break
		}
	}
	assert !same
}

fn test_every_round_covers_the_whole_domain_set() ! {
	// docs/METHODOLOGY.md § warm: a fixed set, queried repeatedly. Asking one
	// name per round would leave the rest of the set cold and would put a
	// five-round run at five samples, well under the thirty a ranked result
	// needs.
	spec := sample_spec()
	steps := build_plan(spec)!

	for round in 0 .. spec.rounds + 1 {
		for key in spec.provider_keys {
			for probe in spec.probes {
				mut asked := []string{}
				for s in steps {
					if s.round == round && s.provider_key == key && s.probe == probe {
						asked << s.domain
					}
				}
				assert asked.len == spec.domains.len
				for domain in spec.domains {
					assert domain in asked, '${key}/${probe} never asked ${domain} in round ${round}'
				}
			}
		}
	}
}

fn test_a_plan_with_nothing_to_measure_is_an_error() {
	base := sample_spec()

	if _ := build_plan(PlanSpec{ probes: base.probes, domains: base.domains }) {
		assert false
	} else {
		assert err.msg().contains('no providers')
	}
	if _ := build_plan(PlanSpec{ provider_keys: base.provider_keys, domains: base.domains }) {
		assert false
	} else {
		assert err.msg().contains('no probes')
	}
	if _ := build_plan(PlanSpec{ provider_keys: base.provider_keys, probes: base.probes }) {
		assert false
	} else {
		assert err.msg().contains('no domains')
	}
}

fn test_a_plan_needs_at_least_one_counted_round() {
	base := sample_spec()

	if _ := build_plan(PlanSpec{
		provider_keys: base.provider_keys
		probes: base.probes
		domains: base.domains
		rounds: 0
	}) {
		assert false
	} else {
		assert err.msg().contains('at least one round')
	}
}

fn test_expected_samples_counts_one_per_domain_per_counted_round() {
	// The discarded pass must not appear in `expected`, or every provider would
	// carry a permanent loss that no packet ever caused. And a count of rounds
	// alone would leave a default run below the thirty-sample floor with every
	// row marked low-n, which is what it did before this was fixed.
	assert expected_samples(5, 8) == 40
	assert expected_samples(5, 3) == 15
	assert expected_samples(1, 1) == 1
}

// ── pacing ───────────────────────────────────────────────────────────────────
fn test_the_rate_limit_is_ten_queries_per_second_per_provider() {
	assert max_queries_per_second == 10
	assert i64(rate_interval) == i64(100 * time.millisecond)
}

fn test_a_provider_is_never_queried_faster_than_the_limit() {
	// Driven by a synthetic clock, so this asserts the rate exactly rather than
	// measuring a real run and hoping.
	mut p := new_pacer(rate_interval)
	mut now := i64(0)
	mut sends := []i64{}

	for _ in 0 .. 50 {
		at := p.reserve('cloudflare', now, jitter_low)
		sends << at
		// The caller waits until it is allowed to send, then loops immediately.
		now = at
	}

	for i in 1 .. sends.len {
		gap := sends[i] - sends[i - 1]
		// jitter_low is the tightest spacing the pacer will ever permit.
		assert gap >= i64(f64(rate_interval) * jitter_low), 'gap ${gap} at index ${i}'
	}

	elapsed_s := f64(sends.last() - sends.first()) / f64(time.second)
	rate := f64(sends.len - 1) / elapsed_s
	assert rate <= f64(max_queries_per_second) / jitter_low + 0.001, 'rate was ${rate}/s'
}

fn test_providers_are_paced_independently() {
	// The limit is per provider. Sixteen providers at 10 qps each is the run the
	// tool is designed for; throttling them against one another would make it
	// sixteen times longer for no gain in politeness to any single operator.
	mut p := new_pacer(rate_interval)

	first := p.reserve('cloudflare', 0, 1.0)
	second := p.reserve('google', 0, 1.0)

	assert first == 0
	assert second == 0
}

fn test_a_caller_that_is_already_late_waits_for_nothing() {
	mut p := new_pacer(rate_interval)

	p.reserve('cloudflare', 0, 1.0)
	// Two full seconds later, the reservation is long past.
	at := p.reserve('cloudflare', i64(2 * time.second), 1.0)

	assert at == i64(2 * time.second)
}

fn test_jitter_is_clamped_to_the_published_span() {
	// A caller passing an absurd factor cannot make the tool impolite, nor
	// stall it.
	mut p := new_pacer(rate_interval)

	p.reserve('a', 0, 100.0)
	late := p.reserve('a', 0, 1.0)
	assert late == i64(f64(rate_interval) * jitter_high)

	mut q := new_pacer(rate_interval)
	q.reserve('b', 0, -5.0)
	early := q.reserve('b', 0, 1.0)
	assert early == i64(f64(rate_interval) * jitter_low)
}

fn test_jitter_factor_stays_within_the_span() {
	for _ in 0 .. 200 {
		f := jitter_factor()
		assert f >= jitter_low
		assert f <= jitter_high
	}
}
