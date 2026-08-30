module main

import os
import time
import core
import store

// The drawing is verified by running it; what is asserted here is the layer
// underneath, which decides what the drawing says. Every rule below is one of
// docs/TUI.md, and none of them needs a terminal.
fn probe(name string, latencies []f64, expected int) store.ProbeReport {
	return store.ProbeReport{
		name: name
		stats: core.compute(latencies, expected)
	}
}

fn subject_row(key string, score f64, rank int, warm []f64) store.ProviderResult {
	return store.ProviderResult{
		key: key
		label: key
		ranked: core.Ranked{
			key: key
			rank: rank
			tier: rank
			score: score
		}
		probes: [probe('warm', warm, warm.len)]
	}
}

fn test_the_edge_column_never_drops() {
	// It is the reason the tool exists. A build that hid it on an 80-column
	// terminal would be hiding its own finding.
	for width in [40, 60, 70, 80, 90, 100, 120] {
		columns := visible_columns(width)
		assert columns.any(it.column == .edge), 'edge dropped at ${width}'
		assert columns.any(it.column == .rank)
		assert columns.any(it.column == .provider)
		assert columns.any(it.column == .score)
		assert columns.any(it.column == .p50)
	}
}

fn test_columns_are_given_up_from_the_right_in_the_published_order() {
	// FLAGS and DoT go first because the detail view carries both.
	wide := visible_columns(200).map(it.column)
	assert wide.len == column_specs.len

	assert Column.flags !in visible_columns(100).map(it.column)
	assert Column.dot !in visible_columns(80).map(it.column)
	assert Column.misrouted !in visible_columns(72).map(it.column)
	assert Column.jitter !in visible_columns(66).map(it.column)
	assert Column.p95 !in visible_columns(58).map(it.column)
}

fn test_the_narrowest_table_still_fits_a_small_terminal() {
	columns := visible_columns(40)
	assert table_width(columns) <= 60
}

fn test_an_absent_figure_prints_a_dash_and_never_a_zero() {
	// Zero is the best value in every latency column on the screen. Printing it
	// for something that was never measured would sort and colour as the best
	// result on the page. docs/METHODOLOGY.md § Nothing is not zero.
	empty := store.ProviderResult{
		key: 'x'
		label: 'x'
		ranked: core.Ranked{
			excluded: core.Exclusion.unreachable
		}
	}
	assert cell_text(empty, .p50, 'warm', '  .').trim_space() == '-'
	assert cell_text(empty, .p95, 'warm', '  .').trim_space() == '-'
	assert cell_text(empty, .jitter, 'warm', '  .').trim_space() == '-'
	assert cell_text(empty, .loss, 'warm', '  .').trim_space() == '-'
	assert cell_text(empty, .edge, 'warm', '  .').trim_space() == '-'
	assert cell_text(empty, .misrouted, 'warm', '  .').trim_space() == '-'
	assert cell_text(empty, .score, 'warm', '  .').trim_space() == '-'
}

fn test_the_edge_cell_carries_its_sign() {
	// +0.0 and a blank are different statements: one says this resolver reached
	// the best edge of the run, the other says nothing was measured.
	on_the_best := store.ProviderResult{
		edge: store.Edge{
			median_penalty_ms: 0.0
			measured: 9
		}
	}
	assert cell_text(on_the_best, .edge, 'warm', '  1').trim_space() == '+0.0'
	assert cell_text(on_the_best, .misrouted, 'warm', '  1').trim_space() == '0/9'

	adrift := store.ProviderResult{
		edge: store.Edge{
			median_penalty_ms: 97.2
			misrouted: 4
			measured: 9
		}
	}
	assert cell_text(adrift, .edge, 'warm', '  1').trim_space() == '+97.2'
	assert cell_text(adrift, .misrouted, 'warm', '  1').trim_space() == '4/9'
}

fn test_the_latency_columns_follow_the_probe_being_viewed() {
	p := store.ProviderResult{
		key: 'q'
		label: 'q'
		probes: [probe('warm', [10.0, 10.0], 2), probe('cold', [90.0, 90.0], 2)]
	}
	assert cell_text(p, .p50, 'warm', '  1').trim_space() == '10.0'
	assert cell_text(p, .p50, 'cold', '  1').trim_space() == '90.0'

	// And so does the sort, or sorting by p50 while looking at cold would order
	// the table by a column that is not on the screen.
	_, warm_key, _ := sort_key(p, .p50, 'warm')
	_, cold_key, _ := sort_key(p, .p50, 'cold')
	assert warm_key == 10.0
	assert cold_key == 90.0
}

fn test_measured_and_declared_badges_never_share_a_tone() {
	p := store.ProviderResult{
		capabilities: store.Capabilities{
			dnssec_validating: true
			filtering: {
				'ads': true
			}
		}
		declared: ['nolog']
	}
	flags := flags_for(p)
	assert flags.len == 3
	assert flags[0].text == '+DNSSEC'
	assert flags[0].tone == .good
	// Blocking is a preference, not a virtue, so the filtering badge is neutral
	// rather than good.
	assert flags[1].text == '+ads'
	assert flags[1].tone == .info
	// A claim by the provider is dim, always, and never coloured as if a probe
	// had established it.
	assert flags[2].text == '~nolog'
	assert flags[2].tone == .dim
}

fn test_a_measured_no_is_a_badge_and_not_an_absence() {
	p := store.ProviderResult{
		capabilities: store.Capabilities{
			dnssec_validating: false
		}
	}
	flags := flags_for(p)
	assert flags.len == 1
	assert flags[0].text == '-DNSSEC'
	assert flags[0].tone == .bad
}

fn test_an_unanswered_capability_shows_no_badge_at_all() {
	// Absent is not false. A provider whose fleet answered inconsistently
	// enough that the probe could not decide must not be printed as failing.
	assert flags_for(store.ProviderResult{}).len == 0
}

fn test_latency_is_coloured_against_the_run_and_not_a_fixed_threshold() {
	// 40 ms is excellent on a satellite link and poor on fibre, and the run
	// already knows which one it is on.
	assert latency_tone(10.0, 10.0) == .good
	assert latency_tone(12.5, 10.0) == .good
	assert latency_tone(12.6, 10.0) == .warn
	assert latency_tone(20.0, 10.0) == .warn
	assert latency_tone(20.1, 10.0) == .bad

	// Nothing measured earns nothing. A dash is not a bad result.
	assert latency_tone(none, 10.0) == .plain
	assert latency_tone(10.0, none) == .plain
}

fn test_the_published_thresholds_are_the_ones_applied() {
	assert threshold_tone(5.0, jitter_good_ms, jitter_warn_ms) == .good
	assert threshold_tone(5.1, jitter_good_ms, jitter_warn_ms) == .warn
	assert threshold_tone(15.1, jitter_good_ms, jitter_warn_ms) == .bad

	assert threshold_tone(5.0, edge_good_ms, edge_warn_ms) == .good
	assert threshold_tone(25.0, edge_good_ms, edge_warn_ms) == .warn
	// The one column that deserves alarm.
	assert threshold_tone(25.1, edge_good_ms, edge_warn_ms) == .bad
}

fn test_loss_is_green_only_at_zero() {
	assert loss_tone(core.compute([10.0], 1)) == .good
	assert loss_tone(core.compute([10.0, 10.0], 21)) == .bad
	assert loss_tone(core.compute([10.0], 0)) == .plain
}

fn test_the_score_gradient_stays_inside_the_runs_own_range() {
	bests := ViewBests{
		score_low: 20.0
		score_high: 90.0
	}
	assert score_gradient(subject_row('a', 90.0, 1, []), bests) == 1.0
	assert score_gradient(subject_row('b', 20.0, 2, []), bests) == 0.0
	assert score_gradient(subject_row('c', 55.0, 3, []), bests) == 0.5

	// A provider that is not ranked has no place on the gradient.
	excluded := store.ProviderResult{
		ranked: core.Ranked{
			excluded: core.Exclusion.low_n
		}
	}
	assert score_gradient(excluded, bests) == 0.0
	assert score_tone(excluded, bests) == .dim
}

fn test_a_cache_does_not_set_the_scale_the_others_are_coloured_against() {
	// A cache hit answers from memory. Colouring every network resolver against
	// 0.3 ms would paint the whole table red.
	mut cache := subject_row('stub', 0.0, 0, [0.3, 0.3])
	cache = store.ProviderResult{
		...cache
		is_cache: true
	}
	bests := view_bests([cache, subject_row('cloudflare', 90.0, 1, [11.0, 13.0])], 'warm')
	assert bests.p50? == 11.0
}

fn test_the_blocks_are_drawn_in_the_published_order() {
	// Ranked, then measured but not ranked, then the caches below the line.
	// docs/SCORING.md calls mixing a cache into the ranking the most important
	// exclusion there is, and the display keeps it out of the list entirely.
	mut cache := subject_row('stub', 0.0, 0, [0.3])
	cache = store.ProviderResult{
		...cache
		is_cache: true
	}
	mut thin := subject_row('opendns', 0.0, 0, [10.0])
	thin = store.ProviderResult{
		...thin
		ranked: core.Ranked{
			key: 'opendns'
			excluded: core.Exclusion.low_n
		}
	}

	rows := display_rows([cache, thin, subject_row('cloudflare', 90.0, 1, [11.0])], .rank, 'warm', false, [], '')
	assert rows.len == 3
	assert rows[0].section == .ranked
	assert rows[1].section == .not_ranked
	assert rows[2].section == .cache
}

fn test_a_reversed_sort_is_the_exact_mirror_of_the_forward_one() {
	results := [
		subject_row('a', 90.0, 1, [11.0]),
		subject_row('b', 70.0, 2, [22.0]),
		subject_row('c', 50.0, 3, [33.0]),
	]
	up := display_rows(results, .score, 'warm', false, [], '').map(it.index)
	down := display_rows(results, .score, 'warm', true, [], '').map(it.index)
	assert up == [2, 1, 0]
	assert down == [0, 1, 2]
}

fn test_a_provider_with_no_figure_keeps_its_place_at_the_end_either_way() {
	// Reversing the order of what was never measured says nothing, so the rows
	// with no figure in the sorted column stay last whichever way the sort runs.
	results := [
		subject_row('measured', 90.0, 1, [11.0]),
		subject_row('silent', 40.0, 2, []),
		subject_row('also-measured', 60.0, 3, [22.0]),
	]
	up := display_rows(results, .p50, 'warm', false, [], '').map(it.index)
	down := display_rows(results, .p50, 'warm', true, [], '').map(it.index)
	assert up.last() == 1
	assert down.last() == 1
}

fn test_a_filter_reads_only_the_half_of_the_output_it_names() {
	validating := store.ProviderResult{
		capabilities: store.Capabilities{
			dnssec_validating: true
		}
	}
	claims_only := store.ProviderResult{
		declared: ['nolog', 'nofilter']
	}

	assert matches_filters(validating, ['dnssec'])
	assert !matches_filters(claims_only, ['dnssec'])

	assert matches_filters(claims_only, ['nolog'])
	assert !matches_filters(validating, ['nolog'])

	// Filters are an AND, and a provider that answered neither question is
	// excluded rather than assumed.
	assert !matches_filters(validating, ['dnssec', 'nolog'])
	assert !matches_filters(store.ProviderResult{}, ['dnssec'])
}

fn test_filtering_out_the_filterers_needs_a_measured_no() {
	blocks := store.ProviderResult{
		capabilities: store.Capabilities{
			filtering: {
				'ads': true
			}
		}
	}
	resolves := store.ProviderResult{
		capabilities: store.Capabilities{
			filtering: {
				'ads': false
			}
		}
	}
	assert matches_filters(resolves, ['no-filtering'])
	assert !matches_filters(blocks, ['no-filtering'])
	// Never asked is not the same as answered no.
	assert !matches_filters(store.ProviderResult{}, ['no-filtering'])
}

fn test_search_matches_the_name_shown_and_the_key_passed_to_only() {
	p := store.ProviderResult{
		key: 'mullvad-base'
		label: 'Mullvad'
	}
	assert matches_search(p, '')
	assert matches_search(p, 'mull')
	assert matches_search(p, 'MULL')
	assert matches_search(p, 'base')
	assert !matches_search(p, 'quad')
}

fn test_every_filter_in_the_menu_says_which_half_it_reads() {
	// The menu is where the reader is told whether they are about to filter on
	// something a probe established or on something a provider claims.
	assert filters_available.len == 5
	for filter in filters_available {
		assert filter.name != ''
		assert filter.label != ''
	}
	measured := filters_available.filter(it.measured).map(it.name)
	declared := filters_available.filter(!it.measured).map(it.name)
	assert measured == ['dnssec', 'no-filtering', 'ipv6']
	assert declared == ['nolog', 'nofilter']
}

fn test_a_terminal_that_cannot_host_the_interface_says_so() {
	// term.ui panics rather than returning an error when there is no TTY, so
	// the check has to happen before it is given the chance. A `--tui` run that
	// is being piped into a file wants the plain table, not a stack trace.
	before := os.getenv('TERM')
	defer {
		os.setenv('TERM', before, true)
	}

	os.setenv('TERM', 'dumb', true)
	assert tui_unavailable()? == 'TERM is dumb'

	os.setenv('TERM', '', true)
	assert tui_unavailable()? == 'TERM is not set'

	os.setenv('TERM', 'xterm-256color', true)
	// Under `v test` stdin is not a terminal, which is the third reason and the
	// one that catches a piped run.
	assert tui_unavailable()? == 'not running under a TTY'
}

fn test_the_elapsed_clock_is_minutes_and_seconds() {
	assert elapsed_text(time.now().add(-47 * time.second)) == '00:47'
	assert elapsed_text(time.now().add(-125 * time.second)) == '02:05'
}

fn test_a_column_is_padded_to_its_declared_width() {
	// V's format verbs take a literal width and the column table does not, so
	// the header and the rows are padded by these two and by nothing else.
	assert pad_left('p50', 5) == '  p50'
	assert pad_right('warm', 8) == 'warm    '
	assert pad_left('overlong', 3) == 'overlong'
	assert clip('abcdef', 3) == 'abc'
}
