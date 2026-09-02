module catalog

fn test_parse_domain_set_reads_the_id_and_the_domains() ! {
	text := '# tranco:K2XVW  retrieved 2026-08-15  top 25, no filter
google.com
youtube.com
'
	set := parse_domain_set(text)!
	assert set.id == 'tranco:K2XVW'
	assert set.domains == ['google.com', 'youtube.com']
}

fn test_parse_domain_set_skips_blank_lines() ! {
	text := '# tranco:K2XVW  retrieved 2026-08-15  top 25, no filter

google.com

youtube.com
'
	set := parse_domain_set(text)!
	assert set.domains == ['google.com', 'youtube.com']
}

fn test_parse_domain_set_refuses_a_missing_id() {
	if _ := parse_domain_set('google.com\n') {
		assert false
	} else {
		assert err.msg().contains('tranco:')
	}
}

fn test_parse_domain_set_refuses_an_empty_list() {
	if _ := parse_domain_set('# tranco:K2XVW\n') {
		assert false
	} else {
		assert err.msg().contains('empty')
	}
}

// The embedded set is the one that ships. A failure here is a build-time
// mistake that reached run time, the same reasoning embedded.v gives for
// the provider catalog.
fn test_the_embedded_global_set_is_the_pinned_unfiltered_top_25() ! {
	set := global_domains()!
	assert set.id.starts_with('tranco:')
	assert set.domains.len == 25
	assert 'google.com' in set.domains
}

fn test_every_known_region_has_an_embedded_regional_set() ! {
	for region in ['sa', 'na', 'eu', 'me', 'af', 'apac'] {
		set := regional_domains(region)!
		assert set.id.starts_with('tranco:'), region
		assert set.domains.len == 25, region
	}
}

fn test_regional_domains_refuses_global_and_unknown_codes() {
	// docs/DATA.md § Regional sets: a regional run is always global + regional,
	// never regional alone, so "global" is the caller's job, not this
	// function's, and an unrecognised code must not come back as an empty set.
	if _ := regional_domains('global') {
		assert false
	} else {
		assert err.msg().contains('global')
	}
	if _ := regional_domains('mars') {
		assert false
	} else {
		assert err.msg().contains('mars')
	}
}
