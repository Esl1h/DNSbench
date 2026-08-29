module core

// The composite score, exactly as published in docs/SCORING.md.
//
// Two rules shape everything here.
//
// Normalisation is relative to the run, never to an absolute threshold. A 30 ms
// p50 is excellent on mobile and mediocre on fibre, so the run's own best
// defines the top. Ratios rather than min-max: bounded, monotonic, and they
// degrade gracefully when one provider is catastrophically bad instead of
// compressing every good one into a narrow band.
//
// Measured and declared never mix. `capability` comes from probes, `privacy`
// comes from what a provider says about itself, and they are separate
// subscores with separate weights so that a claim can never be laundered into
// a measurement. See CLAUDE.md § 5.

// min_ranked_samples is the floor for a ranked result, from
// docs/METHODOLOGY.md § Sample size. Below it the row is marked `low_n` and
// takes no tier.
pub const min_ranked_samples = 30

// Why a provider is not ranked. Absent means it is.
pub enum Exclusion {
	// A local cache answers from memory, which is not comparable with a network
	// round trip. docs/SCORING.md calls this the most important exclusion there
	// is, and it is the error GRC's v1 made and its v2 fixed.
	cache
	// Fewer than min_ranked_samples on a scored probe.
	low_n
	// Nothing answered at all.
	unreachable
	// Every attempt was answered, and every answer carried a non-NOERROR
	// rcode. The resolver is reachable and is declining to resolve, which is
	// a different fact from silence and belongs to a different owner.
	refused
	// Measured, and only on probes that do not rank. An encrypted-only provider
	// asked for over DoH alone has answered every question put to it; it just
	// was not asked one the score is built from.
	unscored
}

// str is the wire form from docs/OUTPUT.md. These strings are the contract a
// consumer matches on, not a display choice.
pub fn (e Exclusion) str() string {
	return match e {
		.cache { 'cache' }
		.low_n { 'low_n' }
		.unreachable { 'unreachable' }
		.refused { 'refused' }
		.unscored { 'unscored' }
	}
}

// Metrics is everything scoring needs about one provider. It is assembled by
// the caller from probe results rather than reaching into them here, so that
// this file has no opinion about how a measurement was obtained.
pub struct Metrics {
pub:
	key      string
	is_cache bool
	// attempted is every query the run put to this provider, on any probe,
	// scored or not. It exists so that "was not asked a scored question" can be
	// told apart from "was asked and did not answer".
	attempted int
	warm      Stats
	cold      Stats
	dot_warm  Stats
	// ecs_penalty_ms is the median penalty in milliseconds above the run's best
	// for each CDN host. Absent when the edge probe did not run.
	ecs_penalty_ms ?f64
	// Measured capabilities, established by probes during this run.
	dnssec_validating bool
	offers_dot        bool
	offers_doh        bool
	offers_ipv6       bool
	// Declared tags, straight from the catalog. Never probed, never mixed with
	// the fields above.
	declared []string
}

// Bests are the run's own reference points. Every ratio subscore is measured
// against these and against nothing else.
pub struct Bests {
pub:
	p50      ?f64
	cold     ?f64
	p95      ?f64
	jitter   ?f64
	rtt      ?f64 // shortest CDN connect time achieved by any provider this run
	dot_warm ?f64
}

// Subscores are each 0 to 100, higher better. An absent one means the provider
// had no measurement to derive it from; it contributes zero to the composite
// and renders as n/a rather than as a zero the reader would mistake for a
// measured result.
pub struct Subscores {
pub:
	latency     ?f64
	recursion   ?f64
	stability   ?f64
	reliability f64
	edge        ?f64
	encrypted   ?f64
	capability  f64
	privacy     f64
}

pub struct Weights {
pub:
	latency     f64
	recursion   f64
	stability   f64
	reliability f64
	edge        f64
	encrypted   f64
	capability  f64
	privacy     f64
}

// profiles are the published weightings from docs/SCORING.md. They are printed
// in the header of every output format: nothing about the ranking is hidden in
// the binary.
pub const profiles = {
	'balanced':  Weights{
		latency: 0.20
		recursion: 0.10
		stability: 0.15
		reliability: 0.15
		edge: 0.25
		encrypted: 0.05
		capability: 0.05
		privacy: 0.05
	}
	'speed':     Weights{
		latency: 0.35
		recursion: 0.15
		stability: 0.15
		reliability: 0.10
		edge: 0.20
		encrypted: 0.05
	}
	'privacy':   Weights{
		latency: 0.10
		recursion: 0.05
		stability: 0.05
		reliability: 0.10
		edge: 0.10
		encrypted: 0.15
		capability: 0.15
		privacy: 0.30
	}
	'streaming': Weights{
		latency: 0.10
		recursion: 0.05
		stability: 0.15
		reliability: 0.20
		edge: 0.40
		encrypted: 0.05
		capability: 0.05
	}
	'gaming':    Weights{
		latency: 0.25
		recursion: 0.10
		stability: 0.35
		reliability: 0.20
		edge: 0.05
		encrypted: 0.05
	}
}

// sum is what normalised divides by, and what the header prints so a custom
// profile that does not add up is visible rather than silently rescaled.
pub fn (w Weights) sum() f64 {
	return w.latency + w.recursion + w.stability + w.reliability + w.edge + w.encrypted + w.capability + w.privacy
}

// normalised scales the weights to sum to 1.0.
//
// A custom profile in the user's config is free to not add up, and the effective
// weights are printed, so a typo produces a visibly wrong header rather than a
// silently wrong ranking. A profile summing to zero is returned unchanged: there
// is nothing to scale, and the caller will see every weight at zero in the
// header.
pub fn (w Weights) normalised() Weights {
	total := w.sum()
	if total <= 0 {
		return w
	}
	return Weights{
		latency: w.latency / total
		recursion: w.recursion / total
		stability: w.stability / total
		reliability: w.reliability / total
		edge: w.edge / total
		encrypted: w.encrypted / total
		capability: w.capability / total
		privacy: w.privacy / total
	}
}

// compute_bests finds the run's reference points.
//
// Caches are left out of the warm-derived bests. A 0.3 ms cache hit as the
// denominator would drag every network resolver's latency subscore towards
// zero and make the whole column meaningless. They stay in the cold best,
// where they act as pure forwarders and the comparison is valid.
pub fn compute_bests(all []Metrics, best_rtt ?f64) Bests {
	mut p50 := ?f64(none)
	mut cold := ?f64(none)
	mut p95 := ?f64(none)
	mut jitter := ?f64(none)
	mut dot_warm := ?f64(none)

	for m in all {
		if !m.is_cache {
			p50 = lower(p50, m.warm.p50)
			p95 = lower(p95, m.warm.p95)
			jitter = lower(jitter, m.warm.jitter)
			dot_warm = lower(dot_warm, m.dot_warm.p50)
		}
		cold = lower(cold, m.cold.p50)
	}

	return Bests{
		p50: p50
		cold: cold
		p95: p95
		jitter: jitter
		rtt: best_rtt
		dot_warm: dot_warm
	}
}

// subscores turns one provider's metrics into the eight published components.
pub fn subscores(m Metrics, b Bests) Subscores {
	return Subscores{
		latency: if m.is_cache { none } else { ratio(b.p50, m.warm.p50) }
		recursion: ratio(b.cold, m.cold.p50)
		stability: if m.is_cache { none } else { stability_of(m, b) }
		reliability: 100.0 - m.warm.loss
		edge: edge_of(b.rtt, m.ecs_penalty_ms)
		encrypted: ratio(b.dot_warm, m.dot_warm.p50)
		capability: capability_of(m)
		privacy: privacy_of(m)
	}
}

// composite weights the subscores. An absent subscore contributes nothing,
// which is docs/SCORING.md § Exclusions: a provider missing a scored probe
// takes zero for that component.
pub fn composite(s Subscores, w Weights) f64 {
	n := w.normalised()
	return n.latency * (s.latency or { 0.0 }) + n.recursion * (s.recursion or { 0.0 }) + n.stability * (s.stability or { 0.0 }) + n.reliability * s.reliability + n.edge * (s.edge or { 0.0 }) + n.encrypted * (s.encrypted or { 0.0 }) + n.capability * s.capability + n.privacy * s.privacy
}

// exclusion_for decides whether a provider is ranked at all, and why not.
//
// The order matters: a local cache is excluded as a cache even when it also has
// too few samples, because that is the more informative reason to show.
pub fn exclusion_for(m Metrics) ?Exclusion {
	if m.is_cache {
		return .cache
	}

	// The scored probe is `warm` where there is one, and `dot_warm` where there
	// is not. An encrypted-only provider never attempted a plaintext query, and
	// reading its empty warm figures as silence would report a resolver that
	// answered every question as unreachable.
	scored := if m.warm.expected > 0 { m.warm } else { m.dot_warm }

	if scored.expected == 0 {
		// Something was asked and answered, just not on a probe that ranks.
		// Calling that unreachable would be the third time this tool reported a
		// resolver that answered as silent.
		if m.attempted > 0 {
			return .unscored
		}
		return .unreachable
	}
	if scored.n == 0 {
		// Refused before unreachable: a resolver that answered every query is
		// not silent, whatever else it is.
		if scored.refused > 0 {
			return .refused
		}
		return .unreachable
	}
	if scored.n < min_ranked_samples {
		return .low_n
	}
	return none
}

// ── the individual subscores ─────────────────────────────────────────────────

// ratio is the 100 x best / this normalisation used by latency, recursion and
// encrypted. Absent when either figure is missing, and when `this` is zero,
// which is not a latency any network round trip produces.
fn ratio(best ?f64, this ?f64) ?f64 {
	b := best or { return none }
	t := this or { return none }
	if t <= 0 {
		return none
	}
	return 100.0 * b / t
}

// stability_of weights the tail more heavily than the spread: a p95 the user
// notices beats a standard deviation they do not.
fn stability_of(m Metrics, b Bests) ?f64 {
	tail := ratio(b.p95, m.warm.p95) or { return none }
	spread := ratio(b.jitter, m.warm.jitter) or { return none }
	return 0.6 * tail + 0.4 * spread
}

// edge_of converts a penalty in milliseconds into a 0-100 subscore.
//
// With best_rtt 11.2 ms a provider with no penalty scores 100 and one 90 ms
// adrift scores about 11. That severity is intended: bad CDN mapping should be
// visible from across the room, because it costs more than the lookup ever
// saves.
fn edge_of(best_rtt ?f64, penalty ?f64) ?f64 {
	rtt := best_rtt or { return none }
	p := penalty or { return none }
	if rtt + p <= 0 {
		return none
	}
	return 100.0 * rtt / (rtt + p)
}

// capability_of scores what the probes established, never what was offered.
//
// A transport this network cannot reach does not count. Scoring a provider for
// DoT on a link where 853 is blocked would be scoring a brochure.
fn capability_of(m Metrics) f64 {
	mut points := 0.0
	if m.dnssec_validating {
		points += 60.0
	}
	if m.offers_dot {
		points += 20.0
	}
	if m.offers_doh {
		points += 10.0
	}
	if m.offers_ipv6 {
		points += 10.0
	}
	return points
}

// privacy_of scores claims, and only claims.
//
// This is the one place the tool propagates something it cannot verify, which
// is why it is a separate subscore with its own weight, rendered in its own
// style, under its own disclaimer. The tags come from the catalog's declared
// partition; a measured tag reaching here would be a bug in the vocabulary,
// not in this function.
fn privacy_of(m Metrics) f64 {
	mut points := 0.0
	if 'nolog' in m.declared {
		points += 40.0
	}
	if 'nofilter' in m.declared {
		points += 30.0
	}
	if 'audited' in m.declared {
		points += 30.0
	}
	return points
}

// lower keeps the smaller of two possibly-absent figures.
fn lower(current ?f64, candidate ?f64) ?f64 {
	c := candidate or { return current }
	existing := current or { return c }
	return if c < existing { c } else { existing }
}
