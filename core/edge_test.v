module core

// Every expectation here is computed by hand and shown as the arithmetic that
// produced it, because the edge subscore carries a quarter of the balanced
// profile and a silent error in this file would be invisible in the table.
fn sample(host string, connect ?f64) EdgeSample {
	return EdgeSample{
		host: host
		answer: '192.0.2.1'
		connect_ms: connect
	}
}

fn test_the_baseline_is_the_best_any_provider_achieved_in_this_run() {
	// akamai: 10, 30, 95  -> floor 10, penalties 0, 20, 85
	// google: 12, 14, 20  -> floor 12, penalties 0,  2,  8
	// medians by nearest rank over two hosts: rank ceil(0.5 * 2) = 1, the lower.
	//   fast:   [0, 0]  -> 0
	//   middle: [20, 2] sorted [2, 20] -> 2
	//   slow:   [85, 8] sorted [8, 85] -> 8
	got := edge_penalties({
		'fast':   [sample('akamai', 10.0), sample('google', 12.0)]
		'middle': [sample('akamai', 30.0), sample('google', 14.0)]
		'slow':   [sample('akamai', 95.0), sample('google', 20.0)]
	})

	assert got['fast'].median_penalty_ms? == 0.0
	assert got['middle'].median_penalty_ms? == 2.0
	assert got['slow'].median_penalty_ms? == 8.0

	assert got['slow'].hosts[0].penalty_ms? == 85.0
	assert got['slow'].hosts[0].connect_ms? == 95.0
}

fn test_a_host_nobody_could_resolve_produces_no_penalty_anywhere() {
	// The floor for a host with no connect time at all does not exist, so the
	// penalty is absent rather than zero. Zero would be the best score on the
	// page, handed out for failing.
	got := edge_penalties({
		'a': [sample('akamai', 10.0), sample('dead', none)]
		'b': [sample('akamai', 25.0), sample('dead', none)]
	})

	assert got['a'].hosts[1].penalty_ms == none
	assert got['b'].hosts[1].penalty_ms == none
	// Only akamai contributed: [0] for a, [15] for b.
	assert got['a'].median_penalty_ms? == 0.0
	assert got['b'].median_penalty_ms? == 15.0
}

fn test_a_provider_that_resolves_fewer_hosts_is_not_favoured_by_the_short_set() {
	// `b` fails the host it would have lost badly, and must not come out ahead
	// by being measured on an easier subset. Its median is drawn only from the
	// hosts it managed, and the missing one is visible in the report.
	got := edge_penalties({
		'a': [sample('akamai', 10.0), sample('google', 12.0)]
		'b': [sample('akamai', 90.0), sample('google', none)]
	})

	assert got['b'].median_penalty_ms? == 80.0
	assert got['b'].hosts[1].connect_ms == none
	assert got['b'].hosts[1].penalty_ms == none
}

fn test_a_stale_host_contributes_to_nobody() {
	// akamai's chain no longer ends where the catalog says, for any provider.
	// It is measuring some other CDN, so it is reported and excluded, and the
	// medians come from google alone: 0 for a, 8 for b.
	mut a_akamai := EdgeSample{
		host: 'akamai'
		answer: '192.0.2.1'
		connect_ms: 10.0
		requires_suffix: true
		suffix_ok: false
	}
	mut b_akamai := EdgeSample{
		host: 'akamai'
		answer: '192.0.2.2'
		connect_ms: 90.0
		requires_suffix: true
		suffix_ok: false
	}
	got := edge_penalties({
		'a': [a_akamai, sample('google', 12.0)]
		'b': [b_akamai, sample('google', 20.0)]
	})

	assert got['a'].hosts[0].stale
	assert got['b'].hosts[0].stale
	assert got['a'].hosts[0].penalty_ms == none
	assert got['b'].hosts[0].penalty_ms == none
	assert got['a'].median_penalty_ms? == 0.0
	assert got['b'].median_penalty_ms? == 8.0
}

fn test_one_provider_keeping_the_chain_keeps_the_host_alive() {
	// Only `a` still sees the expected suffix. That is a fact about `b`, and it
	// is the signal the probe exists to catch, not evidence that the catalog
	// entry has rotted. The host stays in.
	kept := EdgeSample{
		host: 'akamai'
		answer: '192.0.2.1'
		connect_ms: 10.0
		requires_suffix: true
		suffix_ok: true
	}
	lost := EdgeSample{
		host: 'akamai'
		answer: '192.0.2.2'
		connect_ms: 90.0
		requires_suffix: true
		suffix_ok: false
	}
	got := edge_penalties({
		'a': [kept]
		'b': [lost]
	})

	assert !got['a'].hosts[0].stale
	assert !got['b'].hosts[0].stale
	assert got['a'].median_penalty_ms? == 0.0
	assert got['b'].median_penalty_ms? == 80.0
}

fn test_a_provider_that_resolved_nothing_has_no_median() {
	// Absent, not zero. Zero is the best possible edge result and would put a
	// provider that measured nothing at the top of the column.
	got := edge_penalties({
		'a': [sample('akamai', 10.0)]
		'b': [sample('akamai', none)]
	})

	assert got['b'].median_penalty_ms == none
	assert got['a'].median_penalty_ms? == 0.0
}

fn test_the_median_is_nearest_rank_like_every_other_percentile() {
	// Four hosts, penalties 0, 5, 9, 40 for `b`. Nearest rank at p50 over four
	// samples is ceil(0.5 * 4) = 2, so the median is 5 and not the 7 an
	// interpolating median would produce. Every figure the tool prints stays
	// traceable to a measurement that actually happened.
	got := edge_penalties({
		'a': [sample('h1', 10.0), sample('h2', 10.0), sample('h3', 10.0), sample('h4', 10.0)]
		'b': [sample('h1', 10.0), sample('h2', 15.0), sample('h3', 19.0), sample('h4', 50.0)]
	})

	assert got['b'].median_penalty_ms? == 5.0
}
