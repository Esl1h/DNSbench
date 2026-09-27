module main

import catalog
import core
import store

// Flag parsing is where a typo becomes a wrong measurement rather than an
// error, so the validation is asserted rather than trusted.
fn test_defaults_are_the_published_ones() ! {
	o := parse_args([])!

	assert o.profile == 'balanced'
	assert o.rounds == 5
	assert o.probes == ['warm']
	assert o.format == 'table'
	assert !o.force
	assert o.only.len == 0
}

fn test_a_full_command_line_parses() ! {
	o := parse_args(['--profile', 'privacy', '--only', 'quad9, cloudflare', '--rounds', '3',
		'--probes', 'warm,tcp', '--format', 'json', '--force'])!

	assert o.profile == 'privacy'
	assert o.only == ['quad9', 'cloudflare']
	assert o.rounds == 3
	assert o.probes == ['warm', 'tcp']
	assert o.format == 'json'
	assert o.force
}

fn test_the_interface_flags_stand_alone_and_the_palette_takes_a_name() ! {
	o := parse_args(['--tui', '--no-color', '--palette', 'colorblind', '--rounds', '2'])!

	assert o.tui
	assert o.no_color
	assert o.palette == 'colorblind'
	assert o.rounds == 2
}

fn test_an_unknown_palette_is_refused_by_name() {
	// Falling back to the default palette would hand a colourblind reader the
	// green and red table they asked not to have, and say nothing about it.
	if _ := parse_args(['--palette', 'neon']) {
		assert false
	} else {
		assert err.msg().contains('unknown palette')
		assert err.msg().contains('colorblind')
	}
}

fn test_an_unknown_profile_is_refused_by_name() {
	// Falling back to balanced would rank under weights the user did not ask
	// for and did not see.
	if _ := parse_args(['--profile', 'turbo']) {
		assert false
	} else {
		assert err.msg().contains('unknown profile')
		assert err.msg().contains('balanced')
	}
}

fn test_require_accepts_the_measured_filtering_token() ! {
	// "filtering" is not a catalog tag: it reads the filter probe's verdict
	// after the run, docs/METHODOLOGY.md § filter. It must not be rejected as
	// an unknown catalog tag.
	o := parse_args(['--require', 'nolog, filtering'])!
	assert o.require == ['nolog', 'filtering']
}

fn test_an_unknown_require_tag_is_refused() {
	if _ := parse_args(['--require', 'turbo']) {
		assert false
	} else {
		assert err.msg().contains('unknown tag')
		assert err.msg().contains('filtering')
	}
}

fn test_an_unknown_probe_or_format_is_refused() {
	if _ := parse_args(['--probes', 'dot']) {
		assert false
	} else {
		assert err.msg().contains('unknown probe')
	}
	if _ := parse_args(['--format', 'yaml']) {
		assert false
	} else {
		assert err.msg().contains('unknown format')
	}
}

fn test_a_non_positive_round_count_is_refused() {
	// .int() answers 0 for junk and a negative for "-5"; either would produce a
	// run that measures nothing while looking like it worked.
	for value in ['0', '-5', 'many'] {
		if _ := parse_args(['--rounds', value]) {
			assert false, '--rounds ${value} was accepted'
		} else {
			assert err.msg().contains('positive integer')
		}
	}
}

fn test_an_option_without_a_value_is_refused() {
	if _ := parse_args(['--profile']) {
		assert false
	} else {
		assert err.msg().contains('needs a value')
	}
}

fn test_an_unknown_option_is_refused_rather_than_ignored() {
	// Silently ignoring it would run under defaults the user believes they
	// overrode.
	if _ := parse_args(['--agressive']) {
		assert false
	} else {
		assert err.msg().contains('unknown option')
	}
}

fn test_the_help_lists_every_option_the_parser_accepts() {
	// --near was accepted, documented in the man page, and missing here: the
	// flag list is the one users are told to trust.
	text := usage_text()
	for option in value_options {
		assert text.contains('  ${option} <'), '${option} missing from --help'
	}
	for option in standalone_options {
		assert text.contains('  ${option} '), '${option} missing from --help'
	}
}

fn test_the_help_lists_every_exit_status() {
	text := usage_text()
	for code in [store.exit_ok, store.exit_measurement_error, store.exit_usage,
		store.exit_no_provider_reachable, store.exit_catalog_verification] {
		assert text.contains(' ${code} '), 'exit ${code} missing from --help'
	}
}

fn test_the_same_seed_value_gives_the_same_seed_pair() ! {
	a := parse_args(['--seed', '42'])!
	b := parse_args(['--seed', '42'])!
	c := parse_args(['--seed', '43'])!

	assert a.seed == b.seed
	assert a.seed != c.seed
	assert a.seed.len == 2
}

fn test_probes_map_to_the_transports_they_ride() {
	// The output contract names transports, not probes: warm and cold are two
	// questions asked over one UDP socket.
	assert transports_used(['warm']) == ['udp']
	assert transports_used(['warm', 'cold']) == ['udp']
	assert transports_used(['warm', 'tcp']) == ['udp', 'tcp']
	assert transports_used([]) == []string{}
}

fn test_the_warm_domain_set_clears_the_ranking_floor_at_the_default_rounds() ! {
	// A default run that cannot produce a ranked result is a default run that
	// wastes the user's time. This failed before a round became a full pass
	// over the set.
	samples := warm_domains('global')!.domains.len * 5
	assert samples >= 30, 'a default run yields ${samples} samples'
	assert store.exit_ok == 0
}

fn test_warm_domains_falls_back_to_global_alone_when_region_is_unrecognised() ! {
	global := warm_domains('global')!
	unknown := warm_domains('atlantis')!
	assert unknown.id == global.id
	assert unknown.domains == global.domains
}

fn test_warm_domains_merges_the_regional_set_and_carries_its_id() ! {
	// docs/DATA.md § Regional sets: always global + regional, never regional
	// alone, and every result carries the merge in the id.
	global := warm_domains('global')!
	set := warm_domains('sa')!
	assert set.id == '${global.id}+sa'
	for d in global.domains {
		assert d in set.domains
	}
	assert set.domains.len > global.domains.len
}

fn test_warm_domains_never_repeats_a_domain_present_in_both_sets() ! {
	// eu.txt's ccTLD filter and global.txt's unfiltered top 25 both name
	// mail.ru and dzen.ru: querying either twice in one round would weight it
	// double against every other domain in the set for no declared reason.
	set := warm_domains('eu')!
	mut seen := map[string]bool{}
	for d in set.domains {
		assert d !in seen, 'duplicate domain ${d}'
		seen[d] = true
	}
}

fn test_the_cold_probe_asks_a_fresh_name_every_time() {
	// A label the plan could reproduce would be in the resolver's cache the
	// second time it was asked, and the probe would stop measuring recursion
	// and start measuring a cache hit.
	step := core.Step{
		probe: 'cold'
		domain: 'google.com'
	}

	first := query_name(step, 'probe.dnsbench.esli.blog')
	second := query_name(step, 'probe.dnsbench.esli.blog')

	assert first != second
	assert first.ends_with('.probe.dnsbench.esli.blog')
	assert second.ends_with('.probe.dnsbench.esli.blog')
	// The plan's domain is not what gets asked: google.com is cached everywhere,
	// which is the opposite of what a cold probe needs.
	assert !first.contains('google.com')
}

fn test_every_other_probe_asks_the_planned_name() {
	// Only `cold` substitutes. warm and tcp ask the fixed set, repeatedly, which
	// is what makes them measure a cached lookup.
	for probe in ['warm', 'tcp'] {
		step := core.Step{
			probe: probe
			domain: 'wikipedia.org'
		}
		assert query_name(step, 'probe.dnsbench.esli.blog') == 'wikipedia.org'
	}
}

// A provider with no plaintext endpoint used to disappear from the table with
// no line saying why, while a provider needing configuration got a warning.
// Mullvad is the entry that found it: DoT and DoH only, nothing to measure over
// UDP until M2.
fn test_an_encrypted_only_provider_is_reported_not_dropped() ! {
	cat := catalog.embedded()!
	mut warnings := []store.Warning{}
	subjects := select_subjects(cat, Options{}, core.NetInfo{}, ['warm'], mut warnings)!

	assert subjects.filter(it.key == 'mullvad').len == 0
	skipped := warnings.filter(it.key == 'mullvad')
	assert skipped.len == 1
	assert skipped[0].message.contains('no plaintext endpoint')
}

// Asking for only that provider is still an error, because there is nothing to
// measure, but the error has to say which of the two failures happened: the key
// matched and was skipped, it did not fail to match.
fn test_only_an_encrypted_only_provider_explains_itself() {
	cat := catalog.embedded() or { panic(err) }
	mut warnings := []store.Warning{}
	if _ := select_subjects(cat, Options{
		only: ['mullvad']
	}, core.NetInfo{}, ['warm'], mut warnings) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('nothing measurable')
		assert err.msg().contains('no plaintext endpoint')
	}
}

fn test_the_edge_probe_rides_two_transports() {
	// The output contract names transports and not probes. `ecs` asks over UDP
	// and then connects over TCP, so a run that requested only the edge probe
	// still has to declare both.
	assert transports_used(['ecs']) == ['udp', 'tcp']
	assert transports_used(['warm', 'ecs']) == ['udp', 'tcp']
	assert transports_used(['warm']) == ['udp']
}

fn test_the_probes_that_cannot_rank_are_kept_out_of_the_plan() {
	// The edge and capability probes have no latency distribution: they ask a
	// fixed number of questions and read the answers' shape. Putting them in the
	// plan would multiply them by rounds and domains, and a run of only those
	// would emit a table of rows nothing could be ranked from.
	assert timed_probes(['warm', 'ecs'])! == ['warm']
	assert timed_probes(['ecs', 'tcp'])! == ['tcp']
	assert timed_probes(['warm', 'dnssec', 'filter'])! == ['warm']

	for alone in [['ecs'], ['dnssec'], ['filter'], ['dnssec', 'filter', 'ecs']] {
		if kept := timed_probes(alone) {
			assert false, 'expected an error for ${alone}, got ${kept}'
		} else {
			assert err.msg().contains('need a latency probe')
		}
	}
}

fn test_the_hyphenated_probe_spelling_is_accepted() ! {
	// The documents write dot-fresh and dot-warm; the output contract writes
	// dot_fresh and dot_warm. Both are accepted on the command line and only one
	// of them travels onward, so nothing downstream has to know about the other.
	o := parse_args(['--probes', 'dot-fresh,dot-warm'])!

	assert o.probes == ['dot_fresh', 'dot_warm']
}

fn test_dot_probes_ride_the_dot_transport() {
	assert transports_used(['dot_warm']) == ['dot']
	assert transports_used(['warm', 'dot_fresh']) == ['udp', 'dot']
}

fn test_an_encrypted_only_provider_is_measurable_once_dot_is_asked_for() ! {
	// Mullvad answers REFUSED on port 53 by design and serves DoT from the same
	// addresses. It is absent from a plaintext run, present in a DoT one, and
	// carries only the probes it can actually answer.
	cat := catalog.embedded()!

	mut plain_warnings := []store.Warning{}
	plain := select_subjects(cat, Options{
		only: ['mullvad']
	}, core.NetInfo{}, ['warm'], mut plain_warnings) or {
		assert err.msg().contains('no plaintext endpoint')
		[]Subject{}
	}
	assert plain.len == 0

	mut dot_warnings := []store.Warning{}
	over_tls := select_subjects(cat, Options{
		only: ['mullvad']
	}, core.NetInfo{}, ['warm', 'dot_warm'], mut dot_warnings)!

	assert over_tls.len == 1
	assert over_tls[0].dot_host == 'dns.mullvad.net'
	assert over_tls[0].dot_ip == '194.242.2.2'
	// Not warm: it has no plaintext endpoint to run it against.
	assert over_tls[0].probes == ['dot_warm']
}

fn test_a_provider_without_dot_keeps_only_the_plaintext_probes() ! {
	// DNS4EU publishes a DoT hostname, so this asserts against one that does
	// not: a provider is never charged a total loss on a transport it never
	// offered.
	cat := catalog.embedded()!
	mut warnings := []store.Warning{}
	subjects := select_subjects(cat, Options{}, core.NetInfo{}, ['warm', 'dot_warm'], mut warnings)!

	for s in subjects {
		if s.dot_ip == '' {
			assert 'dot_warm' !in s.probes
			assert 'warm' in s.probes
		}
	}
}

fn test_the_cold_probe_defaults_to_the_project_zone() ! {
	// docs/METHODOLOGY.md § cold: `own` against the project zone is the
	// default mode, not an opt-in.
	o := with_cold_zone(parse_args(['--probes', 'warm,cold'])!)
	assert o.cold_zone == default_cold_zone
}

fn test_a_given_cold_zone_is_kept() ! {
	o := with_cold_zone(parse_args(['--probes', 'cold', '--cold-zone', 'probe.example.org'])!)
	assert o.cold_zone == 'probe.example.org'
}

fn test_a_run_without_the_cold_probe_gets_no_zone() ! {
	// cold_mode is stamped from the zone, and history refuses to mix modes: a
	// warm-only run must stay `off` to remain comparable with earlier ones.
	o := with_cold_zone(parse_args(['--probes', 'warm,ecs'])!)
	assert o.cold_zone == ''
}

fn test_progress_counts_queries_and_carries_the_pace_forward() {
	assert progress_line(1500, 6000, 150.0) == 'dnsbench: 1500/6000 queries (25%), 2m30s elapsed, about 7m30s left'
}

fn test_progress_gives_no_estimate_before_there_is_a_pace() {
	// Under a second of history, or nothing done yet, any estimate is noise.
	assert progress_line(0, 6000, 0.0) == 'dnsbench: 0/6000 queries (0%), 0s elapsed'
	assert progress_line(40, 6000, 0.4) == 'dnsbench: 40/6000 queries (0%), 0s elapsed'
}

fn test_short_durations_read_as_minutes_and_seconds() {
	assert short_duration(9.4) == '9s'
	assert short_duration(59.6) == '1m00s'
	assert short_duration(605.0) == '10m05s'
}

fn test_quick_measures_the_lookup_and_the_edge() ! {
	o := parse_args(['--quick'])!
	assert o.quick
	assert o.probes == ['warm', 'ecs']
}

fn test_quick_refuses_to_be_half_overridden() {
	for extra in [['--rounds', '3'], ['--probes', 'warm']] {
		mut args := ['--quick']
		args << extra
		if _ := parse_args(args) {
			assert false, '--quick accepted ${extra}'
		} else {
			assert err.msg().contains('--quick')
		}
	}
}

fn test_quick_rounds_are_the_fewest_that_still_rank() {
	// docs/METHODOLOGY.md § Sample size: 30 samples for a ranked result. One
	// round of global plus a regional set is 50; the global set alone needs two.
	assert quick_rounds(50) == 1
	assert quick_rounds(25) == 2
	assert quick_rounds(30) == 1
	assert quick_rounds(29) == 2
	for n in [1, 7, 25, 29, 30, 31, 50, 100] {
		assert quick_rounds(n) * n >= core.min_ranked_samples, '${n} domains'
		assert (quick_rounds(n) - 1) * n < core.min_ranked_samples, '${n} domains: not the fewest'
	}
}
