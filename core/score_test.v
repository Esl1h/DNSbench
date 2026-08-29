module core

import json2
import math
import os

// The worked example in docs/SCORING.md is a test. The numbers live in
// testdata/scoring_worked_example.json so that the document and the code read
// from one source: if they ever disagree, one of them is a bug and this says
// which.
const score_eps = 1e-9

fn near(got f64, want f64) bool {
	return math.abs(got - want) < score_eps
}

// to one decimal, which is the precision every output format prints
fn shown(v f64) f64 {
	return math.round(v * 10.0) / 10.0
}

struct WorkedBests {
	p50      f64
	cold     f64
	p95      f64
	jitter   f64
	rtt      f64
	dot_warm f64
}

struct WorkedProvider {
	key               string
	warm_n            int
	warm_p50          f64
	warm_p95          f64
	warm_jitter       f64
	warm_loss         f64
	cold_p50          f64
	dot_warm_p50      f64
	ecs_penalty_ms    f64
	dnssec_validating bool
	offers_dot        bool
	offers_doh        bool
	offers_ipv6       bool
	declared          []string
}

struct WorkedExpected {
	latency     f64
	recursion   f64
	stability   f64
	reliability f64
	edge        f64
	encrypted   f64
	capability  f64
	privacy     f64
	score       f64
}

struct WorkedExample {
	profile  string
	bests    WorkedBests
	provider WorkedProvider
	expected WorkedExpected
}

fn load_worked_example() !WorkedExample {
	text := os.read_file(os.join_path(@VMODROOT, 'testdata', 'scoring_worked_example.json'))!
	return json2.decode[WorkedExample](text)!
}

fn test_the_worked_example_from_the_documentation() ! {
	w := load_worked_example()!

	// A test declared `?` that propagates a none exits early and is reported as
	// a pass. So the fixture is checked before anything derived from it: if the
	// decode silently produced zeros, every subscore below would be absent and
	// the test would say nothing while looking green.
	assert w.bests.p50 == 14.2
	assert w.provider.warm_p50 == 15.0
	assert w.provider.declared == ['nolog', 'nofilter']
	assert w.expected.score == 87.3

	b := Bests{
		p50: w.bests.p50
		cold: w.bests.cold
		p95: w.bests.p95
		jitter: w.bests.jitter
		rtt: w.bests.rtt
		dot_warm: w.bests.dot_warm
	}
	m := Metrics{
		key: w.provider.key
		warm: Stats{
			n: w.provider.warm_n
			expected: w.provider.warm_n
			p50: w.provider.warm_p50
			p95: w.provider.warm_p95
			jitter: w.provider.warm_jitter
			loss: w.provider.warm_loss
		}
		cold: Stats{
			n: w.provider.warm_n
			expected: w.provider.warm_n
			p50: w.provider.cold_p50
		}
		dot_warm: Stats{
			n: w.provider.warm_n
			expected: w.provider.warm_n
			p50: w.provider.dot_warm_p50
		}
		ecs_penalty_ms: w.provider.ecs_penalty_ms
		dnssec_validating: w.provider.dnssec_validating
		offers_dot: w.provider.offers_dot
		offers_doh: w.provider.offers_doh
		offers_ipv6: w.provider.offers_ipv6
		declared: w.provider.declared
	}

	s := subscores(m, b)

	// Each subscore as the document prints it, to one decimal.
	assert shown(s.latency?) == w.expected.latency
	assert shown(s.recursion?) == w.expected.recursion
	assert shown(s.stability?) == w.expected.stability
	assert shown(s.reliability) == w.expected.reliability
	assert shown(s.edge?) == w.expected.edge
	assert shown(s.encrypted?) == w.expected.encrypted
	assert shown(s.capability) == w.expected.capability
	assert shown(s.privacy) == w.expected.privacy

	weights := profiles[w.profile] or {
		assert false, 'unknown profile ${w.profile}'
		return
	}
	assert shown(composite(s, weights)) == w.expected.score
}

fn test_the_worked_example_is_the_balanced_profile_at_full_weight() ! {
	// A guard on the fixture itself: if someone edits the profile name or the
	// weights drift, the 87.3 above would still be checked against the wrong
	// arithmetic.
	w := load_worked_example()!

	assert w.profile == 'balanced'
	assert near(profiles['balanced'] or { Weights{} }.sum(), 1.0)
}

// ── profiles ─────────────────────────────────────────────────────────────────
fn test_every_published_profile_sums_to_one() {
	// docs/SCORING.md states the constraint as its first line. A profile that
	// does not sum to 1 produces a composite on a different scale from every
	// other profile, and the score is meant to be comparable across them.
	for name, w in profiles {
		assert near(w.sum(), 1.0), '${name} sums to ${w.sum()}'
	}
}

fn test_the_published_profiles_are_all_present() {
	for name in ['balanced', 'speed', 'privacy', 'streaming', 'gaming'] {
		assert name in profiles
	}
	assert profiles.len == 5
}

fn test_edge_is_the_largest_weight_in_balanced() {
	// The reasoning in docs/SCORING.md: edge is the largest single weight
	// because it is the largest real-world effect and the one no other tool
	// measures. If a later edit quietly demotes it, the project's premise is
	// gone and nothing else would notice.
	b := profiles['balanced'] or { Weights{} }

	assert b.edge == 0.25
	assert b.edge > b.latency
	assert b.edge > b.stability
}

fn test_speed_and_gaming_score_no_declared_claims() {
	// Only the privacy profile propagates unverified claims in any quantity.
	for name in ['speed', 'gaming'] {
		w := profiles[name] or { Weights{} }
		assert w.privacy == 0.0
	}
}

fn test_normalised_scales_a_custom_profile_to_one() {
	// docs/SCORING.md: missing keys default to 0, and the tool normalises the
	// sum, so a typo shows up as a visibly wrong header rather than a silently
	// wrong ranking.
	custom := Weights{
		latency: 0.30
		edge: 0.40
		stability: 0.20
		reliability: 0.10
	}
	assert near(custom.sum(), 1.0)

	lopsided := Weights{
		latency: 3.0
		edge: 1.0
	}
	n := lopsided.normalised()

	assert near(n.sum(), 1.0)
	assert near(n.latency, 0.75)
	assert near(n.edge, 0.25)
}

fn test_normalising_an_all_zero_profile_does_not_divide_by_zero() {
	empty := Weights{}

	assert empty.normalised().sum() == 0.0
}

// ── individual subscores ─────────────────────────────────────────────────────
fn test_capability_counts_only_what_was_reached() ? {
	// docs/SCORING.md: transports the network cannot reach do not count.
	// Scoring a provider for DoT on a link where 853 is blocked would be
	// scoring a brochure.
	full := Metrics{
		dnssec_validating: true
		offers_dot: true
		offers_doh: true
		offers_ipv6: true
	}
	blocked := Metrics{
		dnssec_validating: true
		offers_doh: true
	}

	assert subscores(full, Bests{}).capability == 100.0
	assert subscores(blocked, Bests{}).capability == 70.0
	assert subscores(Metrics{}, Bests{}).capability == 0.0
}

fn test_privacy_reads_declared_tags_and_nothing_else() {
	// The measured fields are all set here and must contribute nothing: this is
	// CLAUDE.md § 5 as an assertion.
	measured_only := Metrics{
		dnssec_validating: true
		offers_dot: true
		offers_doh: true
		offers_ipv6: true
		declared: []
	}
	assert subscores(measured_only, Bests{}).privacy == 0.0

	claimed := Metrics{
		declared: ['nolog', 'nofilter', 'audited']
	}
	assert subscores(claimed, Bests{}).privacy == 100.0

	// A measured tag appearing in `declared` would be a bug in the catalog
	// vocabulary, and it still buys nothing here.
	assert subscores(Metrics{ declared: ['dnssec', 'ecs'] }, Bests{}).privacy == 0.0
}

fn test_edge_makes_a_bad_cdn_mapping_impossible_to_miss() ? {
	// docs/SCORING.md: with best_rtt 11.2 and a 90 ms penalty the subscore is
	// about 11. That severity is the intent.
	perfect := Metrics{
		ecs_penalty_ms: 0.0
	}
	adrift := Metrics{
		ecs_penalty_ms: 90.0
	}
	b := Bests{
		rtt: 11.2
	}

	assert subscores(perfect, b).edge? == 100.0
	assert shown(subscores(adrift, b).edge?) == 11.1
}

fn test_a_subscore_with_no_measurement_is_absent_not_zero() {
	// An absent subscore contributes zero to the composite and renders as n/a.
	// Zero would read as a measured failure rather than as a gap.
	m := Metrics{
		warm: compute([]f64{}, 40)
	}
	s := subscores(m, Bests{ p50: 14.2 })

	if v := s.latency {
		assert false, 'expected none, got ${v}'
	}
	if v := s.edge {
		assert false, 'expected none, got ${v}'
	}
	assert s.reliability == 0.0
}

// ── the cache exclusion ──────────────────────────────────────────────────────
fn test_a_cache_does_not_set_the_warm_best() ? {
	// docs/SCORING.md calls this the single most important exclusion. A 0.3 ms
	// cache hit as the denominator would drag every network resolver's latency
	// subscore towards zero and make the column meaningless.
	cache := Metrics{
		key: 'system-stub'
		is_cache: true
		warm: Stats{
			n: 40
			expected: 40
			p50: 0.3
		}
		cold: Stats{
			n: 40
			expected: 40
			p50: 31.0
		}
	}
	network := Metrics{
		key: 'cloudflare'
		warm: Stats{
			n: 40
			expected: 40
			p50: 14.2
		}
		cold: Stats{
			n: 40
			expected: 40
			p50: 28.0
		}
	}

	b := compute_bests([cache, network], none)

	assert b.p50? == 14.2
	// It is still in the cold best, where it forwards and the comparison holds.
	assert b.cold? == 28.0
}

fn test_a_cache_takes_no_latency_or_stability_subscore() {
	cache := Metrics{
		is_cache: true
		warm: Stats{
			n: 40
			expected: 40
			p50: 0.3
			p95: 0.6
			jitter: 0.1
		}
		cold: Stats{
			n: 40
			expected: 40
			p50: 31.0
		}
	}
	s := subscores(cache, Bests{
		p50: 14.2
		p95: 21.7
		jitter: 2.4
		cold: 28.0
	})

	if v := s.latency {
		assert false, 'a cache took a latency subscore of ${v}'
	}
	if v := s.stability {
		assert false, 'a cache took a stability subscore of ${v}'
	}
	// Recursion still applies: as a forwarder it competes on equal terms.
	assert s.recursion != none
}

// ── exclusions ───────────────────────────────────────────────────────────────
fn test_exclusion_reasons() {
	ranked := Metrics{
		warm: Stats{
			n: 40
			expected: 40
			p50: 14.2
		}
	}
	assert exclusion_for(ranked) == none

	cache := Metrics{
		is_cache: true
		warm: Stats{
			n: 40
			expected: 40
			p50: 0.3
		}
	}
	assert exclusion_for(cache)? == .cache

	dead := Metrics{
		warm: compute([]f64{}, 40)
	}
	assert exclusion_for(dead)? == .unreachable

	thin := Metrics{
		warm: Stats{
			n: 12
			expected: 40
			p50: 14.2
		}
	}
	assert exclusion_for(thin)? == .low_n

	// Answered every query, resolved none of them. Reporting this as
	// unreachable blames the network for a decision the operator made.
	refusing := Metrics{
		warm: compute_counted([]f64{}, 40, 40)
	}
	assert exclusion_for(refusing)? == .refused
}

fn test_exclusion_strings_match_the_output_contract() {
	// docs/OUTPUT.md: `excluded` is null, or one of "cache", "low_n",
	// "unreachable", "refused". These strings are the contract, not a display
	// choice.
	assert Exclusion.cache.str() == 'cache'
	assert Exclusion.low_n.str() == 'low_n'
	assert Exclusion.unreachable.str() == 'unreachable'
	assert Exclusion.refused.str() == 'refused'
}
