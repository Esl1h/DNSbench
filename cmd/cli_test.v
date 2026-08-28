module main

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

fn test_the_warm_domain_set_clears_the_ranking_floor_at_the_default_rounds() {
	// A default run that cannot produce a ranked result is a default run that
	// wastes the user's time. This failed before a round became a full pass
	// over the set.
	samples := warm_domains.len * 5
	assert samples >= 30, 'a default run yields ${samples} samples'
	assert store.exit_ok == 0
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
