module core

import math

// Tiering exists to stop the tool presenting a 0.3-point difference as a
// winner, so the tests are about what it refuses to distinguish as much as
// about what it ranks.
const tier_seed = [u32(0xb007), u32(0x57ab)]

// The weights are exact decimals on paper and not in binary, so a perfect
// provider lands a few ulps either side of 100 rather than on it.
const tier_eps = 1e-9

fn at(got f64, want f64) bool {
	return math.abs(got - want) < tier_eps
}

const fast_bootstrap = BootstrapSpec{
	resamples: 400
	seed: tier_seed
}

// samples_around builds n latencies clustered around `centre`, deterministic so
// that a test asserts a ranking rather than a coin toss.
fn samples_around(centre f64, spread f64, n int) []f64 {
	mut out := []f64{cap: n}
	for i in 0 .. n {
		// A fixed sawtooth: mean is `centre`, spread is `spread`.
		offset := (f64(i % 5) - 2.0) / 2.0 * spread
		out << centre + offset
	}
	return out
}

fn provider(key string, centre f64, spread f64, n int) Samples {
	return Samples{
		base: Metrics{
			key: key
		}
		warm_ms: samples_around(centre, spread, n)
		cold_ms: samples_around(centre * 2, spread, n)
		dot_warm_ms: samples_around(centre * 1.2, spread, n)
		warm_expected: n
		cold_expected: n
		dot_warm_expected: n
	}
}

fn balanced() Weights {
	return profiles['balanced'] or { Weights{} }
}

// ── ranking ──────────────────────────────────────────────────────────────────
fn test_a_clearly_faster_provider_ranks_first() ! {
	// 15 ms against 120 ms with a tight spread is not a judgement call.
	all := [
		provider('slow', 120.0, 2.0, 40),
		provider('fast', 15.0, 2.0, 40),
	]
	ranked := rank_providers(all, none, balanced(), fast_bootstrap)!

	assert ranked.len == 2
	assert ranked[0].key == 'fast'
	assert ranked[1].key == 'slow'
	assert ranked[0].rank == 1
	assert ranked[0].tier == 1
	assert ranked[1].tier == 2
	assert ranked[0].score > ranked[1].score
}

fn test_two_indistinguishable_providers_share_a_rank_and_a_tier() ! {
	// The headline behaviour: a difference of a few tenths against a spread
	// several times larger is noise, and the table must not present it as a
	// winner. docs/METHODOLOGY.md § Tiers.
	all := [
		provider('a', 15.0, 12.0, 40),
		provider('b', 15.3, 12.0, 40),
	]
	ranked := rank_providers(all, none, balanced(), fast_bootstrap)!

	assert ranked[0].tier == ranked[1].tier
	assert ranked[0].rank == ranked[1].rank
	assert ranked[0].rank == 1
}

fn test_a_shared_rank_makes_the_next_tier_skip_a_number() ! {
	// Two providers tied at 1 are followed by 3, never by 2.
	all := [
		provider('a', 15.0, 12.0, 40),
		provider('b', 15.3, 12.0, 40),
		provider('far', 400.0, 2.0, 40),
	]
	ranked := rank_providers(all, none, balanced(), fast_bootstrap)!

	assert ranked[0].rank == 1
	assert ranked[1].rank == 1
	assert ranked[2].rank == 3
	assert ranked[2].tier == 2
}

fn test_every_provider_gets_an_interval_around_its_score() ! {
	all := [
		provider('a', 15.0, 4.0, 40),
		provider('b', 40.0, 4.0, 40),
	]
	ranked := rank_providers(all, none, balanced(), fast_bootstrap)!

	for r in ranked {
		low := r.ci_low or {
			assert false, '${r.key} has no lower bound'
			return
		}
		high := r.ci_high or {
			assert false, '${r.key} has no upper bound'
			return
		}
		assert low <= high
		assert low <= r.score
		assert r.score <= high
	}
}

fn test_a_tighter_sample_gives_a_narrower_interval() ! {
	// The interval has to react to the data, or it is decoration.
	tight := rank_providers([provider('t', 20.0, 0.5, 40), provider('other', 60.0, 2.0, 40)], none, balanced(), fast_bootstrap)!
	loose := rank_providers([provider('t', 20.0, 40.0, 40), provider('other', 60.0, 2.0, 40)], none, balanced(), fast_bootstrap)!

	tight_width := (tight[0].ci_high or { 0.0 }) - (tight[0].ci_low or { 0.0 })
	loose_width := (loose[0].ci_high or { 0.0 }) - (loose[0].ci_low or { 0.0 })

	assert loose_width > tight_width
}

// ── reproducibility ──────────────────────────────────────────────────────────
fn test_the_same_seed_gives_the_same_tiers() ! {
	// A ranking nobody can re-derive from the metadata that travels with it is
	// an anecdote. docs/ARCHITECTURE.md § Design constraints.
	all := [
		provider('a', 15.0, 6.0, 40),
		provider('b', 17.0, 6.0, 40),
		provider('c', 90.0, 6.0, 40),
	]
	first := rank_providers(all, none, balanced(), fast_bootstrap)!
	second := rank_providers(all, none, balanced(), fast_bootstrap)!

	assert first.len == second.len
	for i in 0 .. first.len {
		assert first[i].key == second[i].key
		assert first[i].rank == second[i].rank
		assert first[i].tier == second[i].tier
		assert first[i].ci_low or { -1.0 } == second[i].ci_low or { -2.0 }
		assert first[i].ci_high or { -1.0 } == second[i].ci_high or { -2.0 }
	}
}

fn test_the_bootstrap_can_run_twice_from_one_spec() ! {
	// rand.new_default frees the seed array it is given, so a spec reused across
	// two calls was a double free. It failed roughly one run in three, which is
	// the worst possible way for it to fail.
	all := [provider('a', 15.0, 4.0, 30), provider('b', 30.0, 4.0, 30)]

	rank_providers(all, none, balanced(), fast_bootstrap)!
	rank_providers(all, none, balanced(), fast_bootstrap)!
	rank_providers(all, none, balanced(), fast_bootstrap)!
	assert tier_seed.len == 2
}

// ── exclusions ───────────────────────────────────────────────────────────────
fn test_an_unreachable_provider_sorts_last_whatever_it_scored() ! {
	// A dead resolver with every declared tag would otherwise float up the
	// table on its privacy subscore alone.
	mut dead := Samples{
		base: Metrics{
			key: 'dead-but-virtuous'
			dnssec_validating: true
			offers_dot: true
			offers_doh: true
			offers_ipv6: true
			declared: ['nolog', 'nofilter', 'audited']
		}
		warm_expected: 40
	}
	alive := provider('alive', 200.0, 5.0, 40)

	ranked := rank_providers([dead, alive], none, balanced(), fast_bootstrap)!

	assert ranked[0].key == 'alive'
	assert ranked[1].key == 'dead-but-virtuous'
	assert ranked[1].excluded? == .unreachable
	assert ranked[1].tier == 0
}

fn test_a_cache_is_ranked_apart_and_takes_no_tier() ! {
	mut cache := provider('system-stub', 0.3, 0.05, 40)
	cache = Samples{
		base: Metrics{
			key: 'system-stub'
			is_cache: true
		}
		warm_ms: cache.warm_ms
		cold_ms: cache.cold_ms
		dot_warm_ms: cache.dot_warm_ms
		warm_expected: 40
		cold_expected: 40
		dot_warm_expected: 40
	}
	network := provider('cloudflare', 15.0, 3.0, 40)

	ranked := rank_providers([cache, network], none, balanced(), fast_bootstrap)!

	assert ranked[0].key == 'cloudflare'
	assert ranked[0].tier == 1
	assert ranked[1].key == 'system-stub'
	assert ranked[1].excluded? == .cache
	assert ranked[1].tier == 0
}

fn test_a_low_n_provider_takes_no_tier() ! {
	thin := provider('thin', 15.0, 3.0, 12)
	full := provider('full', 40.0, 3.0, 40)

	ranked := rank_providers([thin, full], none, balanced(), fast_bootstrap)!

	for r in ranked {
		if r.key == 'thin' {
			assert r.excluded? == .low_n
			assert r.tier == 0
		} else {
			assert r.excluded == none
			assert r.tier == 1
		}
	}
}

// ── guards ───────────────────────────────────────────────────────────────────
fn test_ranking_nothing_produces_nothing() ! {
	assert rank_providers([]Samples{}, none, balanced(), fast_bootstrap)!.len == 0
}

fn test_a_bootstrap_needs_resamples_and_a_real_confidence() {
	all := [provider('a', 15.0, 3.0, 30)]

	if _ := rank_providers(all, none, balanced(), BootstrapSpec{ resamples: 0 }) {
		assert false
	} else {
		assert err.msg().contains('at least one resample')
	}
	if _ := rank_providers(all, none, balanced(), BootstrapSpec{ confidence: 1.0 }) {
		assert false
	} else {
		assert err.msg().contains('strictly between 0 and 1')
	}
}

fn test_no_bootstrap_draw_can_score_above_one_hundred() ! {
	// The invariant that pins the method. Every ratio subscore is best/this with
	// the best taken from the same data, so it cannot exceed 100, and neither
	// can a weighted average of subscores that are each capped at 100.
	//
	// It holds only because the bests are recomputed inside each replicate.
	// Holding them at the observed values lets a replicate draw a provider
	// faster than its own observed best, which scores it above 100 and quietly
	// widens the leader's interval in the wrong direction.
	all := [
		provider('a', 15.0, 8.0, 40),
		provider('b', 18.0, 8.0, 40),
		provider('c', 60.0, 8.0, 40),
	]
	ranked := rank_providers(all, none, balanced(), fast_bootstrap)!

	for r in ranked {
		assert r.score <= 100.0 + tier_eps, '${r.key} scored ${r.score}'
		high := r.ci_high or { continue }
		assert high <= 100.0 + tier_eps, '${r.key} has an upper bound of ${high}'
	}
}

fn test_a_provider_that_is_its_own_reference_scores_exactly_one_hundred() ! {
	// The sharp version of the invariant above. One provider, best at
	// everything by definition, every subscore at its ceiling: the composite is
	// exactly 100 and every bootstrap draw is too, because in each replicate it
	// is still its own reference.
	//
	// Hold the bests at the observed values instead and a replicate that draws
	// this provider faster than it actually was scores it above 100. Averaged
	// across eight subscores that excess hides; here there is nothing to hide
	// behind, which is what makes this the test that pins the method.
	sole := Samples{
		base: Metrics{
			key: 'sole'
			ecs_penalty_ms: 0.0
			dnssec_validating: true
			offers_dot: true
			offers_doh: true
			offers_ipv6: true
			declared: ['nolog', 'nofilter', 'audited']
		}
		warm_ms: samples_around(15.0, 9.0, 40)
		cold_ms: samples_around(30.0, 9.0, 40)
		dot_warm_ms: samples_around(18.0, 9.0, 40)
		warm_expected: 40
		cold_expected: 40
		dot_warm_expected: 40
	}

	ranked := rank_providers([sole], 11.2, balanced(), fast_bootstrap)!

	assert ranked.len == 1
	assert at(ranked[0].score, 100.0), 'scored ${ranked[0].score}'
	assert at(ranked[0].ci_low?, 100.0)
	assert at(ranked[0].ci_high?, 100.0)
}
