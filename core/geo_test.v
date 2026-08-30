module core

// The parsers are asserted against the exact strings the service returned,
// captured in testdata/txt_origin.response.bin and testdata/txt_asn.response.bin
// and reproduced here so a reader can see what is being parsed. No test on this
// page sends a packet: the cascade is exercised with the lookup switched off,
// which is what `--no-geo` does.
fn test_the_asn_and_the_country_come_out_of_an_origin_record() {
	asn, country := parse_origin_answer('27699 | 189.46.0.0/15 | BR | lacnic | 2007-06-22')
	assert asn == '27699'
	assert country == 'BR'
}

fn test_a_prefix_announced_by_several_asns_takes_the_first() {
	// A multi-homed network. Either answer describes it, and picking one keeps
	// the field a single ASN rather than a list nothing downstream can match on.
	asn, country := parse_origin_answer('64500 64501 | 203.0.113.0/24 | NL | ripencc | 2010-01-01')
	assert asn == '64500'
	assert country == 'NL'
}

fn test_a_record_that_is_not_an_origin_record_yields_nothing() {
	asn, country := parse_origin_answer('v=spf1 include:example.net ~all')
	assert asn == ''
	assert country == ''
}

fn test_the_operator_name_is_stripped_of_what_is_already_known() {
	// The last field repeats the ASN and the country around the name, and both
	// travel in their own fields, so printing them again would be noise.
	assert parse_asn_answer('27699 | BR | lacnic | 2003-08-25 | AS27699 - TELEFONICA BRASIL S.A, BR') == 'TELEFONICA BRASIL S.A'
	assert parse_asn_answer('13335 | US | arin | 2010-07-14 | CLOUDFLARENET, US') == 'CLOUDFLARENET'
	assert parse_asn_answer('short | record') == ''
}

fn test_the_origin_zone_is_keyed_by_the_reversed_address() ! {
	assert reverse_ipv4('189.46.44.175')! == '175.44.46.189'
	assert reverse_ipv4('1.2.3.4')! == '4.3.2.1'

	if _ := reverse_ipv4('2001:db8::1') {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('not an IPv4 address')
	}
}

fn test_a_country_lands_in_its_domain_set() {
	assert region_for_country('BR') == 'sa'
	assert region_for_country('br') == 'sa'
	assert region_for_country('US') == 'na'
	assert region_for_country('PT') == 'eu'
	assert region_for_country('JP') == 'apac'
	assert region_for_country('NG') == 'af'
	assert region_for_country('IL') == 'me'
}

fn test_an_unknown_country_is_global_rather_than_a_failure() {
	// The global domain set is the one every run uses anyway, so an unrecognised
	// code costs a slightly less representative domain mix and nothing else.
	assert region_for_country('ZZ') == region_global
	assert region_for_country('') == region_global
}

fn test_the_two_continents_that_share_a_timezone_area_are_separated_by_name() {
	// `America/` alone cannot tell Toronto from Sao Paulo, and this is the last
	// step before giving up, so it is worth getting right.
	assert region_from_tz('America/Sao_Paulo')? == 'sa'
	assert region_from_tz('America/Argentina/Buenos_Aires')? == 'sa'
	assert region_from_tz('America/Toronto')? == 'na'
	assert region_from_tz('America/New_York')? == 'na'
}

fn test_the_rest_of_the_timezone_map() {
	assert region_from_tz('Europe/Lisbon')? == 'eu'
	assert region_from_tz('Africa/Lagos')? == 'af'
	assert region_from_tz('Asia/Tokyo')? == 'apac'
	assert region_from_tz('Asia/Jerusalem')? == 'me'
	assert region_from_tz('Australia/Sydney')? == 'apac'

	// UTC, an empty variable and anything unrecognised fall through to the last
	// step of the cascade rather than guessing.
	assert region_from_tz('UTC') == none
	assert region_from_tz('') == none
	assert region_from_tz('Mars/Olympus_Mons') == none
}

fn test_no_geo_sends_nothing_and_still_answers() {
	// The opt-out is the whole opt-out: with it set, the cascade falls straight
	// through to the timezone and then to the default.
	found := detect_origin(disabled: true, resolver: '198.51.100.1')
	assert found.asn == ''
	assert found.asn_org == ''
	assert found.source in ['tz', 'default']
}

fn test_the_flag_overrides_the_region_and_says_so() {
	found := detect_origin(region: 'eu', disabled: true)
	assert found.region == 'eu'
	assert found.source == 'flag'
}

fn test_with_nowhere_to_ask_the_lookup_is_skipped_rather_than_guessed() {
	// No configured resolver means no lookup. Reaching for a public resolver
	// instead would be sending the user's address somewhere they did not ask
	// for it to go.
	found := detect_origin(resolver: '')
	assert found.asn == ''
	assert found.region in known_regions
}
