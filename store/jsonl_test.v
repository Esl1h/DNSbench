module store

import os

fn test_read_history_of_a_file_that_was_never_written_is_empty_not_an_error() {
	lines, errors := read_history('/nonexistent/dnsbench/runs.jsonl')
	assert lines.len == 0
	assert errors.len == 0
}

fn test_read_history_round_trips_what_encode_wrote() ! {
	dir := os.join_path(os.temp_dir(), 'dnsbench_jsonl_test')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'runs.jsonl')

	line := Line{
		ts: '2026-08-28T09:14:02Z'
		asn: 'AS27699'
		ifname: 'wlan0'
		provider: 'quad9-ecs'
		probe: 'warm'
		n: 40
		p50: 16.9
		loss: 0.0
		score: 58.7
	}
	os.write_file(path, line.encode() + '\n')!

	lines, errors := read_history(path)
	assert errors.len == 0
	assert lines.len == 1
	assert lines[0].provider == 'quad9-ecs'
	assert lines[0].p50? == 16.9
	assert lines[0].score? == 58.7
}

// One bad line partway through a file that was otherwise appended to
// correctly is a fact about that line, not a reason to discard the file.
fn test_read_history_skips_a_bad_line_and_says_which() ! {
	dir := os.join_path(os.temp_dir(), 'dnsbench_jsonl_test_bad')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'runs.jsonl')

	good := Line{
		ts: '2026-08-28T09:14:02Z'
		asn: 'AS1'
		provider: 'quad9'
		probe: 'warm'
	}
	os.write_file(path, good.encode() + '\nnot json\n')!

	lines, errors := read_history(path)
	assert lines.len == 1
	assert errors.len == 1
	assert errors[0].contains('line 2')
}

fn test_comparable_refuses_to_mix_networks() {
	a := Line{ asn: 'AS1', ifname: 'wlan0', cold_mode: 'off', domains: 'tranco:K2XVW', probe: 'warm' }
	b := Line{ asn: 'AS2', ifname: 'wlan0', cold_mode: 'off', domains: 'tranco:K2XVW', probe: 'warm' }
	assert !comparable(a, b)
	assert comparable(a, a)
}
