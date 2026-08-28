module core

import math

// Stats summarises one (provider, probe) pair.
//
// Every latency field is derived from successful samples only. A query that
// exceeded its timeout contributes to `loss` and can never contribute a
// latency value, because its true value is unbounded and recording the
// timeout instead would understate it. See docs/METHODOLOGY.md § Outliers.
//
// No trimming and no winsorising: a 400 ms spike is the user's experience,
// not noise to be deleted.
//
// Every latency field is optional, and absent means the sample was not there to
// derive it from. Zero would be a claim, and the most flattering one available:
// a dead resolver would render as the fastest row in the table, and the latency
// subscore in docs/SCORING.md divides by p50.
//
//   n == 0   nothing answered, so no latency figure exists
//   n == 1   p50, p95, max and mean exist; the sample standard deviation does not
//   n >= 2   all of them
//
// `n`, `expected` and `loss` are always known and are never optional.
pub struct Stats {
pub:
	n        int // successful samples
	expected int // samples attempted
	p50      ?f64 // ms, nearest-rank
	p95      ?f64 // ms, nearest-rank
	max      ?f64 // ms, largest successful sample
	mean     ?f64 // ms; reaches JSON only, never a human-facing headline
	jitter   ?f64 // ms, sample standard deviation, n-1 denominator
	loss     f64 // percent in [0, 100], matching schema/result.schema.json
}

// percentile returns the nearest-rank percentile of an ascending-sorted sample,
// in whatever unit the sample carries.
//
// The rank is ceil(p / 100 * n), 1-based, clamped to [1, n]. There is no
// interpolation, so the value returned is always one that some query actually
// produced: every percentile the tool prints stays traceable to a real
// measurement, and the unit tests stay hand-computable.
//
// An empty sample has no percentile, so none is returned rather than zero.
//
// The caller is responsible for sorting. Passing an unsorted slice returns a
// meaningless number rather than an error, so this is `pub` for testing and
// for callers that already hold sorted data.
pub fn percentile(sorted_ms []f64, p f64) ?f64 {
	if sorted_ms.len == 0 {
		return none
	}
	mut rank := int(math.ceil(p / 100.0 * f64(sorted_ms.len)))
	if rank < 1 {
		rank = 1
	}
	if rank > sorted_ms.len {
		rank = sorted_ms.len
	}
	return sorted_ms[rank - 1]
}

// compute summarises the successful latency samples of one (provider, probe)
// pair. `expected` is how many queries were attempted, including the ones that
// timed out or failed.
//
// Taking successes and the attempt count as separate arguments is what makes
// the timeout rule structural rather than a matter of care at every call site:
// there is no way to hand this function a timeout as if it were a latency.
//
// The first sample per (provider, probe) is discarded by the scheduler, not
// here, and must be excluded from `expected` as well.
pub fn compute(latencies_ms []f64, expected int) Stats {
	n := latencies_ms.len

	// An `expected` below `n` is a caller error; clamping to zero keeps a bad
	// count from producing a negative loss that would flatter the provider.
	mut loss := 0.0
	if expected > n {
		loss = 100.0 * f64(expected - n) / f64(expected)
	}

	if n == 0 {
		return Stats{
			n: 0
			expected: expected
			loss: loss
		}
	}

	mut sorted := latencies_ms.clone()
	sorted.sort()

	mut sum := 0.0
	for v in sorted {
		sum += v
	}
	mean := sum / f64(n)

	// Sample standard deviation, which is undefined for a single observation and
	// is therefore absent rather than zero. Zero would assert perfect stability
	// on the strength of one measurement.
	mut jitter := ?f64(none)
	if n > 1 {
		mut sq := 0.0
		for v in sorted {
			d := v - mean
			sq += d * d
		}
		jitter = math.sqrt(sq / f64(n - 1))
	}

	return Stats{
		n: n
		expected: expected
		p50: percentile(sorted, 50)
		p95: percentile(sorted, 95)
		max: sorted[n - 1]
		mean: mean
		jitter: jitter
		loss: loss
	}
}
