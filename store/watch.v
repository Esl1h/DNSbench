module store

// Comparing consecutive runs for `--watch`.
//
// docs/OUTPUT.md § Exit codes names the two cases a monitoring job cares
// about: "alert when the winning provider changes or when edge_penalty for
// [a] resolver crosses a threshold." This is what recognises both, working
// from two already-finished RunResults and nothing else, so it is exercised
// with plain values and no clock, no loop and no network.

// watch_alerts compares two consecutive runs and names what changed enough
// to be worth a monitoring job's attention.
//
// edge_threshold_ms is none when the caller did not ask for that check at
// all, not when a provider measured no edge probe: an absent edge penalty is
// compared against nothing, never treated as zero.
pub fn watch_alerts(previous RunResult, current RunResult, edge_threshold_ms ?f64) []string {
	mut alerts := []string{}

	prev_winner := winning_provider(previous)
	curr_winner := winning_provider(current)
	// Either side having no winner at all, everything excluded, is its own
	// fact and not a change worth alerting on relative to a run that could
	// not have compared to it anyway.
	if prev_winner != '' && curr_winner != '' && prev_winner != curr_winner {
		alerts << 'winning provider changed from ${prev_winner} to ${curr_winner}'
	}

	if threshold := edge_threshold_ms {
		for p in current.results {
			penalty := p.edge.median_penalty_ms or { continue }
			if penalty > threshold {
				alerts << '${p.key} edge penalty is ${penalty:.1f} ms, over the ${threshold:.1f} ms threshold'
			}
		}
	}

	return alerts
}

// winning_provider is the rank-1 entry, or empty when nothing in the run was
// ranked at all: every provider excluded, or an empty run.
fn winning_provider(r RunResult) string {
	for p in r.results {
		if p.ranked.excluded == none && p.ranked.rank == 1 {
			return p.key
		}
	}
	return ''
}
