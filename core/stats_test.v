module core

import math

// Every expectation in this file was computed by hand and is shown as the
// arithmetic that produced it. None was obtained by running the implementation
// and recording what it printed: a test that agrees with the code by
// construction agrees with its bugs too.
//
// Tests that read a latency field declare `?` and unwrap with `?`, so a field
// that went absent when it should not have fails the test rather than being
// quietly defaulted.
const eps = 1e-9

fn approx(got f64, want f64) bool {
	return math.abs(got - want) < eps
}

// ── percentile ───────────────────────────────────────────────────────────────
fn test_percentile_nearest_rank() ? {
	// n = 10, so rank = ceil(p / 100 * 10), 1-based, clamped to [1, 10]:
	//   p50  -> ceil(5.0)  = 5   -> sample[4]  = 50
	//   p95  -> ceil(9.5)  = 10  -> sample[9]  = 100
	//   p100 -> ceil(10.0) = 10  -> sample[9]  = 100
	//   p0   -> ceil(0.0)  = 0, clamped up to 1 -> sample[0] = 10
	sample := [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0]

	assert percentile(sample, 50)? == 50.0
	assert percentile(sample, 95)? == 100.0
	assert percentile(sample, 100)? == 100.0
	assert percentile(sample, 0)? == 10.0
}

fn test_percentile_returns_a_measured_value_not_an_interpolation() ? {
	// With interpolation p50 here would be 2.5, a latency no query produced.
	// Nearest-rank gives rank ceil(0.5 * 4) = 2, the lower of the two central
	// samples. Documented in docs/METHODOLOGY.md § Percentile method.
	assert percentile([1.0, 2.0, 3.0, 4.0], 50)? == 2.0
}

fn test_percentile_of_an_empty_sample_is_absent_not_zero() {
	// Zero is a latency, and the best one available. Absence is the honest
	// answer to "what was the median of nothing".
	if v := percentile([]f64{}, 50) {
		assert false, 'expected none, got ${v}'
	}
	if v := percentile([]f64{}, 95) {
		assert false, 'expected none, got ${v}'
	}
}

// ── compute ──────────────────────────────────────────────────────────────────
fn test_compute_symmetric_sample() ? {
	// [10, 12, 14, 16, 18], n = 5, all five attempts succeeded.
	//   mean   = 70 / 5 = 14
	//   devs   = -4, -2, 0, 2, 4  ->  squares 16, 4, 0, 4, 16, sum 40
	//   jitter = sqrt(40 / 4) = sqrt(10) = 3.16227766016838
	//   p50    = rank ceil(0.50 * 5) = 3 -> 14
	//   p95    = rank ceil(0.95 * 5) = 5 -> 18
	s := compute([10.0, 12.0, 14.0, 16.0, 18.0], 5)

	assert s.n == 5
	assert s.expected == 5
	assert s.p50? == 14.0
	assert s.p95? == 18.0
	assert s.max? == 18.0
	assert s.mean? == 14.0
	assert approx(s.jitter?, 3.1622776601683795)
	assert s.loss == 0.0
}

fn test_compute_sorts_and_leaves_the_caller_sample_alone() ? {
	shuffled := [16.0, 10.0, 18.0, 14.0, 12.0]
	s := compute(shuffled, 5)

	assert s.p50? == 14.0
	assert s.p95? == 18.0
	assert s.max? == 18.0
	// The caller still owns its ordering: compute sorts a clone.
	assert shuffled[0] == 16.0
}

fn test_compute_keeps_outliers() ? {
	// docs/METHODOLOGY.md § Outliers: no trimming, no winsorising. A 400 ms
	// spike is the user's experience, and p50 already keeps it out of the
	// headline without deleting it.
	//   [10, 10, 10, 10, 400]
	//   mean   = 440 / 5 = 88
	//   devs   = -78 x4, +312  ->  6084 x4 + 97344 = 121680
	//   jitter = sqrt(121680 / 4) = sqrt(30420) = 174.413302244984
	//   p50    = rank 3 -> 10        p95 = rank 5 -> 400
	s := compute([10.0, 10.0, 10.0, 10.0, 400.0], 5)

	assert s.p50? == 10.0
	assert s.p95? == 400.0
	assert s.max? == 400.0
	assert s.mean? == 88.0
	assert approx(s.jitter?, 174.41330224498358)
}

// ── loss ─────────────────────────────────────────────────────────────────────
fn test_loss_is_a_percentage_of_attempts() {
	// The field observation in docs/METHODOLOGY.md § Report n: 27 of 35
	// handshakes completed. 8 / 35 = 0.22857142857142857 -> 22.857142857142858 %
	successes := []f64{len: 27, init: 20.0 + f64(index)}
	s := compute(successes, 35)

	assert s.n == 27
	assert s.expected == 35
	assert approx(s.loss, 22.857142857142858)
}

fn test_timeout_never_becomes_a_latency_value() ? {
	// Three queries answered at 10 ms, seven timed out. The timeout duration is
	// nowhere in the input, so no arrangement of this function can report it as
	// a latency. That is the point of taking successes and attempts separately.
	//   loss = 100 * 7 / 10 = 70
	s := compute([10.0, 10.0, 10.0], 10)

	assert s.n == 3
	assert s.p50? == 10.0
	assert s.p95? == 10.0
	assert s.max? == 10.0
	assert s.loss == 70.0
}

// ── absent, not zero ─────────────────────────────────────────────────────────
fn test_compute_with_no_successful_samples_reports_no_latency_at_all() {
	// A provider that answered nothing stays in the output with loss 100 rather
	// than vanishing, per docs/ARCHITECTURE.md § Failure policy. What it must
	// not do is report zeros: a zero p50 beside 100 % loss reads as the fastest
	// resolver on the page, and docs/SCORING.md computes the latency subscore
	// as best_p50 / this_p50, which would divide by it.
	s := compute([]f64{}, 30)

	assert s.n == 0
	assert s.expected == 30
	assert s.loss == 100.0

	if v := s.p50 {
		assert false, 'expected none, got ${v}'
	}
	if v := s.p95 {
		assert false, 'expected none, got ${v}'
	}
	if v := s.max {
		assert false, 'expected none, got ${v}'
	}
	if v := s.mean {
		assert false, 'expected none, got ${v}'
	}
	if v := s.jitter {
		assert false, 'expected none, got ${v}'
	}
}

fn test_compute_with_nothing_attempted() {
	// Nothing attempted is not total loss; it is no measurement.
	s := compute([]f64{}, 0)

	assert s.n == 0
	assert s.loss == 0.0
}

fn test_compute_single_sample_has_no_spread_to_report() ? {
	// The sample standard deviation is undefined for one observation, so it is
	// absent. Zero would assert perfect stability on the strength of a single
	// measurement, which is the opposite of what one measurement supports.
	s := compute([42.0], 1)

	assert s.n == 1
	assert s.p50? == 42.0
	assert s.p95? == 42.0
	assert s.max? == 42.0
	assert s.mean? == 42.0
	assert s.loss == 0.0

	if v := s.jitter {
		assert false, 'expected none, got ${v}'
	}
}

fn test_expected_below_n_cannot_produce_negative_loss() {
	// A miscounted attempt total is a caller bug. Clamping keeps it from
	// flattering the provider with a negative loss rate.
	s := compute([10.0, 20.0], 1)

	assert s.n == 2
	assert s.loss == 0.0
}
