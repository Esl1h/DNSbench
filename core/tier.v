module core

import rand

// Tiering: refusing to rank noise.
//
// Ranking provider #1 above #2 when the difference is 0.4 points and the run's
// own spread is several times that is fiction. docs/METHODOLOGY.md § Tiers puts
// a bootstrap confidence interval on each provider's composite score and groups
// the ones that overlap.
//
// The interval is on the score rather than on p50 because the score is what
// orders the table. A band drawn from p50, printed beside a column sorted by
// score, would describe the uncertainty of a different quantity from the one
// the reader is looking at.

// default_resamples is enough for a stable 95 % interval at this sample size
// while keeping a run's post-processing under a second.
pub const default_resamples = 1000

pub const default_confidence = 0.95

// Samples is one provider's raw measurements. The bootstrap needs the samples
// themselves, not the summary, because resampling a percentile is not the same
// as recomputing one from resampled data.
pub struct Samples {

	// base carries everything a replicate does not disturb: the declared tags,
	// the measured capabilities, the cache flag and the edge penalty.
pub:
	base Metrics
	// Raw latencies per probe, already excluding the discarded warm-up query.
	warm_ms     []f64
	cold_ms     []f64
	dot_warm_ms []f64
	// Attempt counts, so that loss survives resampling unchanged: a replicate
	// draws the same number of samples it observed.
	warm_expected     int
	cold_expected     int
	dot_warm_expected int
}

pub struct BootstrapSpec {
pub:
	resamples  int = default_resamples
	confidence f64 = default_confidence
	// seed makes the tiering reproducible, like the plan it belongs to.
	seed []u32
}

pub struct Ranked {
pub:
	key   string
	rank  int
	tier  int
	score f64
	// The bootstrap interval on the score. Absent when the provider had nothing
	// to resample.
	ci_low   ?f64
	ci_high  ?f64
	excluded ?Exclusion
}

// rank_providers scores everyone, puts an interval around each score, and
// groups the ones that are not distinguishable.
//
// Providers carrying an exclusion are scored but never ranked: they sort last,
// keep their reason, and take no tier. docs/SCORING.md § Exclusions.
pub fn rank_providers(all []Samples, best_rtt ?f64, w Weights, spec BootstrapSpec) ![]Ranked {
	if all.len == 0 {
		return []Ranked{}
	}
	if spec.resamples < 1 {
		return error('bootstrap needs at least one resample, got ${spec.resamples}')
	}
	if spec.confidence <= 0 || spec.confidence >= 1 {
		return error('confidence must be strictly between 0 and 1, got ${spec.confidence}')
	}

	observed := metrics_of(all)
	bests := compute_bests(observed, best_rtt)

	mut scores := []f64{cap: all.len}
	for m in observed {
		scores << composite(subscores(m, bests), w)
	}

	intervals := bootstrap_intervals(all, best_rtt, w, spec)!

	// Sort by score, best first. Excluded providers go last whatever they
	// scored: an unreachable resolver with a flattering capability score must
	// not appear above a working one.
	mut order := []int{cap: all.len}
	for i in 0 .. all.len {
		order << i
	}
	order.sort_with_compare(fn [scores, observed] (a &int, b &int) int {
		ea := exclusion_for(observed[*a]) != none
		eb := exclusion_for(observed[*b]) != none
		if ea != eb {
			return if ea { 1 } else { -1 }
		}
		if scores[*a] > scores[*b] {
			return -1
		}
		if scores[*a] < scores[*b] {
			return 1
		}
		return 0
	})

	mut out := []Ranked{cap: all.len}
	mut tier := 0
	mut leader := -1

	for position, idx in order {
		excluded := exclusion_for(observed[idx])
		low := intervals[idx].low
		high := intervals[idx].high

		if excluded != none {
			out << Ranked{
				key: all[idx].base.key
				rank: position + 1
				tier: 0
				score: scores[idx]
				ci_low: low
				ci_high: high
				excluded: excluded
			}
			continue
		}

		// A provider joins the current tier when its interval overlaps that of
		// the provider leading the tier. Comparing against the previous row
		// instead would let a chain of pairwise overlaps collapse the whole
		// table into one band.
		if leader < 0 || !overlaps(intervals[leader], intervals[idx]) {
			tier++
			leader = idx
		}

		out << Ranked{
			key: all[idx].base.key
			rank: rank_of(out, tier, position)
			tier: tier
			score: scores[idx]
			ci_low: low
			ci_high: high
		}
	}

	return out
}

struct Interval {
	low  ?f64
	high ?f64
}

// rank_of gives every member of a tier the rank of its first member, so a
// shared tier shares a rank number and the next tier skips ahead. Two providers
// tied at 1 are followed by 3, never by 2.
fn rank_of(so_far []Ranked, tier int, position int) int {
	for r in so_far {
		if r.tier == tier {
			return r.rank
		}
	}
	return position + 1
}

// overlaps is false when either interval is missing: a provider with nothing to
// resample cannot be shown to be indistinguishable from anyone.
fn overlaps(a Interval, b Interval) bool {
	a_low := a.low or { return false }
	a_high := a.high or { return false }
	b_low := b.low or { return false }
	b_high := b.high or { return false }
	return a_low <= b_high && b_low <= a_high
}

fn metrics_of(all []Samples) []Metrics {
	mut out := []Metrics{cap: all.len}
	for s in all {
		out << with_stats(s, compute(s.warm_ms, s.warm_expected), compute(s.cold_ms, s.cold_expected), compute(s.dot_warm_ms, s.dot_warm_expected))
	}
	return out
}

// with_stats rebuilds a provider's metrics around a fresh set of statistics,
// leaving everything a replicate does not disturb exactly as observed.
fn with_stats(s Samples, warm Stats, cold Stats, dot_warm Stats) Metrics {
	return Metrics{
		key: s.base.key
		is_cache: s.base.is_cache
		warm: warm
		cold: cold
		dot_warm: dot_warm
		ecs_penalty_ms: s.base.ecs_penalty_ms
		dnssec_validating: s.base.dnssec_validating
		offers_dot: s.base.offers_dot
		offers_doh: s.base.offers_doh
		offers_ipv6: s.base.offers_ipv6
		declared: s.base.declared
	}
}

// bootstrap_intervals resamples the whole run, repeatedly, and reports the
// confidence interval of each provider's composite score.
//
// The run's best figures are recomputed inside every replicate. Normalisation
// is relative to the run, so the reference point is itself uncertain, and
// holding it fixed would understate every interval on the page.
fn bootstrap_intervals(all []Samples, best_rtt ?f64, w Weights, spec BootstrapSpec) ![]Interval {
	// The clone is required: rand.new_default frees the array it is handed.
	mut rng := if spec.seed.len > 0 {
		rand.new_default(seed_: spec.seed.clone())
	} else {
		rand.new_default()
	}

	mut draws := [][]f64{len: all.len, init: []f64{cap: spec.resamples}}

	for _ in 0 .. spec.resamples {
		mut replicate := []Metrics{cap: all.len}
		for s in all {
			replicate << with_stats(s, compute(resample(mut rng, s.warm_ms)!, s.warm_expected), compute(resample(mut rng, s.cold_ms)!, s.cold_expected), compute(resample(mut rng, s.dot_warm_ms)!, s.dot_warm_expected))
		}

		bests := compute_bests(replicate, best_rtt)
		for i, m in replicate {
			draws[i] << composite(subscores(m, bests), w)
		}
	}

	tail := (1.0 - spec.confidence) / 2.0
	mut out := []Interval{cap: all.len}
	for i in 0 .. all.len {
		if all[i].warm_ms.len == 0 {
			out << Interval{}
			continue
		}
		mut sorted := draws[i].clone()
		sorted.sort()
		out << Interval{
			low: percentile(sorted, tail * 100.0)
			high: percentile(sorted, (1.0 - tail) * 100.0)
		}
	}
	return out
}

// resample draws `sample.len` values from `sample` with replacement.
fn resample(mut rng rand.PRNG, sample []f64) ![]f64 {
	if sample.len == 0 {
		return []f64{}
	}
	mut out := []f64{cap: sample.len}
	for _ in 0 .. sample.len {
		out << sample[rng.intn(sample.len)!]
	}
	return out
}
