module core

import rand
import time

// The measurement plan and its pacing.
//
// This file decides what is asked, of whom, in what order and how fast. It
// issues nothing: no socket appears here, so the fairness rules in
// docs/METHODOLOGY.md can be asserted without a network.
//
// Three of those rules live here, and each exists because a naive
// implementation gets it wrong.
//
//   Interleave, never batch. Testing provider A to completion, then B, then C
//   makes A pay for cold upstream caches and an unwarmed local path while C
//   benefits from a network that has been in use for two minutes.
//
//   Shuffle the order every round, so that no provider is permanently first.
//
//   Discard the first sample per (provider, probe). It carries handshake, ARP,
//   route setup and cache-fill costs that no later query pays.

// max_queries_per_second is the per-provider ceiling from
// docs/METHODOLOGY.md § Rate limit. These are free public services, several run
// by non-profits, and a benchmark that hammers them gets its users rate-limited.
pub const max_queries_per_second = 10

pub const rate_interval = time.second / max_queries_per_second

// jitter_span is the multiplier range applied to the interval, so a provider
// sees an irregular stream rather than a metronome.
pub const jitter_low = 0.8

pub const jitter_high = 1.2

// Step is one query the plan calls for.
pub struct Step {
pub:
	round        int
	provider_key string
	probe        string
	domain       string
	// discard marks the warm-up query for a (provider, probe) pair. It is sent
	// like any other and its result is thrown away.
	discard bool
}

pub struct PlanSpec {
pub:
	provider_keys []string
	probes        []string
	// domains are the fixed set each round queries in full. docs/METHODOLOGY.md
	// § warm: "fixed domain set, queried repeatedly". A round is one pass over
	// the set, not one query, which is why round 0 discards a whole pass: every
	// name has to be warmed, not just the first.
	domains []string
	rounds  int = 5
	// seed makes a plan reproducible. Two runs with the same seed produce the
	// same order, which is what lets a result be re-derived from the metadata
	// that travels with it.
	seed []u32
}

// build_plan lays out the whole run before any of it happens.
//
// Round 0 is the discard round: one query per (provider, probe) whose result is
// thrown away. The rounds that count are numbered from 1, and `rounds` in the
// output is that count, not counting the warm-up.
pub fn build_plan(spec PlanSpec) ![]Step {
	if spec.provider_keys.len == 0 {
		return error('plan has no providers')
	}
	if spec.probes.len == 0 {
		return error('plan has no probes')
	}
	if spec.domains.len == 0 {
		return error('plan has no domains')
	}
	if spec.rounds < 1 {
		return error('plan needs at least one round, got ${spec.rounds}')
	}

	// The clone is not defensive style, it is required: rand.new_default frees
	// the seed array it is handed. Passing a caller-owned array, or the same
	// one twice, is a double free that surfaces intermittently and far from
	// here. See docs/V-NOTES.md.
	mut rng := if spec.seed.len > 0 {
		rand.new_default(seed_: spec.seed.clone())
	} else {
		rand.new_default()
	}

	mut steps := []Step{cap: (spec.rounds + 1) * spec.provider_keys.len * spec.probes.len}

	for round in 0 .. spec.rounds + 1 {
		// A fresh shuffle per round. Shuffling once and reusing the order would
		// leave whoever drew first place first for the entire run.
		order := rng.shuffle_clone(spec.provider_keys)!

		for key in order {
			for probe in spec.probes {
				for domain in spec.domains {
					steps << Step{
						round: round
						provider_key: key
						probe: probe
						domain: domain
						discard: round == 0
					}
				}
			}
		}
	}

	return steps
}

// Pacer enforces the per-provider rate limit.
//
// It holds no clock of its own: the caller passes the current time in. That is
// what lets the rate limit be tested exactly, with a synthetic clock and no
// sleeping, rather than approximately by measuring a real run.
pub struct Pacer {
mut:
	interval i64 // nanoseconds
	next     map[string]i64
}

// new_pacer starts a pacer with no history, so the first query to any provider
// goes out immediately.
pub fn new_pacer(interval time.Duration) Pacer {
	return Pacer{
		interval: i64(interval)
	}
}

// reserve returns the nanosecond timestamp at which a query to `key` may be
// sent, given the current time, and records it. A caller that is already past
// that moment gets `now_ns` back and waits for nothing.
//
// `jitter` multiplies the interval and is clamped to [jitter_low, jitter_high].
// Passing it in rather than drawing it here keeps the whole thing deterministic
// under test.
pub fn (mut p Pacer) reserve(key string, now_ns i64, jitter f64) i64 {
	mut factor := jitter
	if factor < jitter_low {
		factor = jitter_low
	}
	if factor > jitter_high {
		factor = jitter_high
	}

	earliest := p.next[key] or { now_ns }
	send_at := if earliest > now_ns { earliest } else { now_ns }
	p.next[key] = send_at + i64(f64(p.interval) * factor)
	return send_at
}

// jitter_factor draws a multiplier in [jitter_low, jitter_high].
pub fn jitter_factor() f64 {
	return rand.f64_in_range(jitter_low, jitter_high) or { 1.0 }
}

// expected_samples is how many results a (provider, probe) pair should yield:
// one per domain per counted round, with the discarded warm-up pass excluded.
//
// Getting this wrong is not cosmetic. It is the denominator of `loss`, so a
// count that includes the warm-up gives every provider a permanent loss no
// packet ever caused, and a count of rounds alone puts every row below the
// thirty-sample floor and leaves the whole table unranked.
pub fn expected_samples(rounds int, domains int) int {
	return rounds * domains
}
