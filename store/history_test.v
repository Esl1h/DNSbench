module store

import time

fn sample_line(provider string, asn string, probe string, p50 f64, score f64, ts string) Line {
	return Line{
		ts: ts
		asn: asn
		ifname: 'wlan0'
		provider: provider
		probe: probe
		p50: p50
		score: score
		cold_mode: 'off'
		domains: 'tranco:K2XVW'
	}
}

fn test_filter_by_asn_and_provider() {
	lines := [
		sample_line('quad9', 'AS1', 'warm', 10.0, 90.0, '2026-08-01T00:00:00Z'),
		sample_line('quad9', 'AS2', 'warm', 20.0, 80.0, '2026-08-01T00:00:00Z'),
		sample_line('cloudflare', 'AS1', 'warm', 5.0, 95.0, '2026-08-01T00:00:00Z'),
	]

	assert filter_lines(lines, HistoryFilter{ asn: 'AS1' }).len == 2
	assert filter_lines(lines, HistoryFilter{ provider: 'quad9' }).len == 2
	assert filter_lines(lines, HistoryFilter{ asn: 'AS1', provider: 'cloudflare' }).len == 1
	assert filter_lines(lines, HistoryFilter{}).len == 3
}

// RFC 3339 UTC timestamps sort lexicographically, which is the whole reason
// since_rfc3339 is a plain string comparison rather than a parsed one.
fn test_filter_by_time_window_is_a_string_comparison() {
	lines := [
		sample_line('quad9', 'AS1', 'warm', 10.0, 90.0, '2026-07-01T00:00:00Z'),
		sample_line('quad9', 'AS1', 'warm', 12.0, 88.0, '2026-08-15T00:00:00Z'),
	]

	kept := filter_lines(lines, HistoryFilter{ since_rfc3339: '2026-08-01T00:00:00Z' })
	assert kept.len == 1
	assert kept[0].ts == '2026-08-15T00:00:00Z'
}

fn test_aggregate_groups_by_network_and_provider_never_mixing_asns() {
	lines := [
		sample_line('quad9', 'AS1', 'warm', 10.0, 90.0, '2026-08-01T00:00:00Z'),
		sample_line('quad9', 'AS1', 'warm', 20.0, 80.0, '2026-08-02T00:00:00Z'),
		sample_line('quad9', 'AS2', 'warm', 999.0, 1.0, '2026-08-01T00:00:00Z'),
	]

	groups := aggregate(lines)

	assert groups.len == 2
	as1 := groups.filter(it.group_key.starts_with('AS1|'))[0]
	assert as1.runs == 2
	assert as1.p50_mean? == 15.0
	assert as1.p50_min? == 10.0
	assert as1.p50_max? == 20.0
	// The later timestamp's score is the one that survives, not the first
	// line seen in the bucket.
	assert as1.latest_score? == 80.0
}

fn test_aggregate_on_no_lines_is_empty_not_an_error() {
	assert aggregate([]Line{}).len == 0
}

fn test_sparkline_scales_between_its_own_low_and_high() {
	plot := sparkline([10.0, 20.0, 30.0])
	assert plot == '▁▄█'
}

fn test_sparkline_of_a_flat_series_is_the_middle_block_not_an_extreme() {
	assert sparkline([15.0, 15.0, 15.0]) == '▅▅▅'
}

fn test_sparkline_of_nothing_is_empty() {
	assert sparkline([]f64{}) == ''
}

fn test_parse_duration_reads_the_documented_units() ! {
	// i64(...) first in every expected value: V 0.5.2 cbf4e85 truncates
	// `int * int * time.Duration` to 32 bits before widening the product,
	// the same overflow parse_duration's own fix works around.
	assert parse_duration('30d')! == i64(30) * 24 * time.hour
	assert parse_duration('12h')! == i64(12) * time.hour
	assert parse_duration('2w')! == i64(2) * 7 * 24 * time.hour
	assert parse_duration('5m')! == i64(5) * time.minute
	assert parse_duration('30s')! == i64(30) * time.second
}

fn test_parse_duration_rejects_nonsense() {
	for bad in ['', '5', '5x', '-3d', '0d'] {
		if _ := parse_duration(bad) {
			assert false, '"${bad}" should have been refused'
		}
	}
}
