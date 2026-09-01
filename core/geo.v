module core

import os
import time

// Where the run is, and on whose network.
//
// This is the only part of the tool that asks a question about the user rather
// than about a resolver, so it is worth being precise about what it does. It
// makes at most three DNS queries, before any measurement starts, and it makes
// them only because `asn` and `ifname` are what let a history file tell a run on
// fibre apart from a run on a phone. docs/OUTPUT.md § History says they are not
// optional metadata; without them the file silently mixes two networks.
//
// No HTTP, no account, no identifier of any kind sent anywhere. `--no-geo`
// skips the lookup entirely and the run reports `region: global` with an empty
// ASN, which is exactly what it did before this file existed.

// region_global is the fallback and also a real region: the unfiltered global
// domain set. docs/DATA.md § Domain sets.
pub const region_global = 'global'

// known_regions are the domain-set names of docs/DATA.md. They are lowercase
// because they name files.
pub const known_regions = ['global', 'sa', 'na', 'eu', 'apac', 'af', 'me']

// opendns_myip_resolver is resolver1.opendns.com, which answers `myip.opendns.com`
// with the address the query arrived from. Asking over DNS rather than over an
// HTTP "what is my IP" service keeps the tool to one protocol and one kind of
// traffic.
pub const opendns_myip_resolver = '208.67.222.222'

pub const myip_name = 'myip.opendns.com'

// cymru_origin_zone maps a reversed IPv4 address to the ASN announcing it, and
// cymru_asn_zone maps that ASN to its name. Both are plain TXT lookups in the
// public DNS, run by Team Cymru as a free service.
pub const cymru_origin_zone = 'origin.asn.cymru.com'

pub const cymru_asn_zone = 'asn.cymru.com'

// google_myaddr_resolver is Google Public DNS, asked for `google_myaddr_name`
// the same way `opendns_myip_resolver` is asked for `myip_name`: a second,
// independent answer to "what address did this query arrive from", used only
// to catch a transparent DNS hijack. docs/METHODOLOGY.md § Fairness rules.
pub const google_myaddr_resolver = '8.8.8.8'

pub const google_myaddr_name = 'o-o.myaddr.l.google.com'

// Origin is what the run could establish about the network it is on. Every
// field is empty or `global` when nothing could be established, which is not an
// error: docs/ARCHITECTURE.md § Failure policy says region detection falls back
// and continues silently.
pub struct Origin {
pub:
	asn     string
	asn_org string
	country string
	region  string = region_global
	// source is the step of the cascade that decided the region, in the
	// vocabulary of docs/OUTPUT.md: flag, config, rir, tz or default.
	source string = 'default'
	// dns_interception is set when step 3's two independent "what is my
	// address" queries disagree: docs/METHODOLOGY.md § Fairness rules calls
	// this a security finding, not a measurement caveat. False also covers
	// "not checked", the same convention core.NetInfo.vpn_detected() already
	// uses, since --no-geo or a failed lookup leave nothing to disagree with.
	dns_interception bool
}

// The country groupings behind the seven domain sets. Coarse on purpose: they
// pick which regional domain list a run uses, not where anyone lives, and a
// country in the wrong bucket costs a slightly less representative domain mix
// and nothing else.
const countries_sa = 'AR BO BR CL CO EC FK GF GY PE PY SR UY VE'

const countries_na = 'AG AI AW BB BL BM BQ BS BZ CA CR CU CW DM DO GD GL GP GT HN HT JM KN KY LC MF MQ MS MX NI PA PM PR SV SX TC TT US VC VG VI'

const countries_eu = 'AD AL AT AX BA BE BG BY CH CY CZ DE DK EE ES FI FO FR GB GG GI GR HR HU IE IM IS IT JE LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS RU SE SI SJ SK SM UA VA XK'

const countries_me = 'AE BH IL IQ IR JO KW LB OM PS QA SA SY TR YE'

const countries_af = 'AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG ER ET GA GH GM GN GQ GW KE KM LR LS LY MA MG ML MR MU MW MZ NA NE NG RE RW SC SD SH SL SN SO SS ST SZ TD TG TN TZ UG YT ZA ZM ZW'

const countries_apac = 'AF AM AS AU AZ BD BN BT CC CK CN CX FJ FM GE GU HK ID IN JP KG KH KI KP KR KZ LA LK MH MM MN MO MP MV MY NC NF NP NR NU NZ PF PG PH PK PN PW SB SG TH TJ TK TL TM TO TV TW UZ VN VU WF WS'

const country_regions = build_country_regions()

fn build_country_regions() map[string]string {
	mut out := map[string]string{}
	for region, codes in {
		'sa':   countries_sa
		'na':   countries_na
		'eu':   countries_eu
		'me':   countries_me
		'af':   countries_af
		'apac': countries_apac
	} {
		for code in codes.split(' ') {
			out[code] = region
		}
	}
	return out
}

// region_for_country buckets an ISO 3166-1 alpha-2 code. An unknown code is
// `global`, which is a usable answer rather than a failure: the global domain
// set is the one every run uses anyway.
pub fn region_for_country(code string) string {
	return country_regions[code.to_upper()] or { region_global }
}

// The timezone fallback, used only when the DNS lookup was skipped or failed.
//
// A zone name is not a location, and `America/` alone cannot tell Toronto from
// São Paulo, so the two continents that share it are separated by name. This is
// step 4 of the cascade in docs/ARCHITECTURE.md § Region detection and it is
// deliberately the last one before giving up.
const tz_south_america = 'Araguaina Argentina Asuncion Bahia Belem Boa_Vista Bogota Campo_Grande Caracas Cayenne Cuiaba Eirunepe Fortaleza Georgetown Guayaquil La_Paz Lima Maceio Manaus Montevideo Noronha Paramaribo Porto_Velho Punta_Arenas Recife Rio_Branco Santarem Santiago Sao_Paulo'

const tz_middle_east = 'Aden Amman Baghdad Bahrain Beirut Damascus Dubai Gaza Hebron Istanbul Jerusalem Kuwait Muscat Qatar Riyadh Tehran'

// region_from_tz reads the region out of a zoneinfo name.
pub fn region_from_tz(zone string) ?string {
	if zone == '' {
		return none
	}
	if !zone.contains('/') {
		return none
	}
	area := zone.all_before('/')
	rest := zone.all_after('/')
	place := rest.all_after_last('/')
	first := rest.all_before('/')

	return match area {
		'Africa' { 'af' }
		'Europe' { 'eu' }
		'Atlantic' { 'eu' }
		'Australia' { 'apac' }
		'Pacific' { 'apac' }
		'Indian' { 'apac' }
		'America' {
			if first in tz_south_america.split(' ') || place in tz_south_america.split(' ') {
				'sa'
			} else {
				'na'
			}
		}
		'Asia' {
			if place in tz_middle_east.split(' ') { 'me' } else { 'apac' }
		}
		else { none }
	}
}

// local_timezone is the zone name, from TZ or from what /etc/localtime points
// at. Reading the symlink rather than the file because the file is binary and
// the name is the whole point.
pub fn local_timezone() string {
	zone := os.getenv('TZ')
	if zone != '' {
		return zone.trim_left(':')
	}
	target := os.real_path('/etc/localtime')
	marker := '/zoneinfo/'
	if !target.contains(marker) {
		return ''
	}
	return target.all_after_last(marker)
}

// GeoSpec is what the caller supplies. `disabled` is `--no-geo`, and it is the
// whole of the opt-out: with it set nothing on this page sends a packet.
pub struct GeoSpec {

	// region is the --region flag, step 1 of the cascade and the only step that
	// overrides a measured answer.
pub:
	region   string
	disabled bool
	// resolver is the address the two TXT lookups go to, normally the machine's
	// own. Empty means there is nowhere to ask and the lookup is skipped.
	resolver string
	timeout  time.Duration = 2 * time.second
}

// detect_origin walks the cascade of docs/ARCHITECTURE.md § Region detection.
//
// Step 2, the persisted config file, is not implemented: there is no config
// file yet. Every other step is here, and each one falls through silently
// rather than failing the run, because a benchmark that refuses to measure
// because it could not name your ISP is a benchmark nobody can use.
pub fn detect_origin(spec GeoSpec) Origin {
	mut found := Origin{}

	if !spec.disabled && spec.resolver != '' {
		found = lookup_origin(spec) or { Origin{} }
	}

	if spec.region != '' {
		return Origin{
			...found
			region: spec.region
			source: 'flag'
		}
	}
	if found.source != 'default' {
		return found
	}

	if region := region_from_tz(local_timezone()) {
		return Origin{
			...found
			region: region
			source: 'tz'
		}
	}
	return found
}

// lookup_origin is step 3: the public address over DNS, then the ASN
// announcing it, then that ASN's name, then a second, independent address
// query to catch a transparent DNS hijack. Four queries, once per run.
fn lookup_origin(spec GeoSpec) !Origin {
	ip := public_ip(spec.timeout)!
	reversed := reverse_ipv4(ip)!

	origin := ask_txt(spec.resolver, '${reversed}.${cymru_origin_zone}', spec.timeout)!
	if origin.len == 0 {
		return error('no origin record for ${ip}')
	}
	asn, country := parse_origin_answer(origin[0])
	if asn == '' {
		return error('origin record for ${ip} carried no ASN')
	}

	// The name is a second lookup and a failure of it is not a failure of the
	// first: an unnamed ASN is still the fact that separates two links.
	mut org := ''
	if named := ask_txt(spec.resolver, 'AS${asn}.${cymru_asn_zone}', spec.timeout) {
		if named.len > 0 {
			org = parse_asn_answer(named[0])
		}
	}

	// A failed second query is not a failure of the first, and it is not
	// evidence of interception either: it is one fewer thing this run could
	// establish, the same as an unnamed ASN above.
	mut interception := false
	if google_ip := google_myaddr_ip(spec.timeout) {
		interception = interception_detected(ip, google_ip)
	}

	return Origin{
		asn: 'AS${asn}'
		asn_org: org
		country: country
		dns_interception: interception
		region: region_for_country(country)
		// The vocabulary of docs/OUTPUT.md has no value for this lookup and
		// gains none: `rir` is what the step means, an address resolved to the
		// registry data that describes it, and the answer even names the RIR
		// that holds the allocation.
		source: 'rir'
	}
}

// public_ip asks resolver1.opendns.com what address the query arrived from.
//
// This is the one query that does not go to the machine's own resolver, because
// the answer is the question: only the far end knows what address it saw.
pub fn public_ip(timeout time.Duration) !string {
	addresses := ask_a(opendns_myip_resolver, myip_name, timeout)!
	if addresses.len == 0 {
		return error('${myip_name} returned no address')
	}
	return addresses[0]
}

// google_myaddr_ip asks 8.8.8.8 what address the query arrived from, the same
// question public_ip puts to OpenDNS. A real answer carries the address as
// its own TXT string, and sometimes a second string
// "edns0-client-subnet <prefix>" when something on the path added an EDNS
// Client Subnet option to the query; that second string answers a different
// question and is skipped. Verified against a live query to 8.8.8.8, which
// returned exactly this shape: the plain address first, the annotation
// second.
pub fn google_myaddr_ip(timeout time.Duration) !string {
	answers := ask_txt(google_myaddr_resolver, google_myaddr_name, timeout)!
	return first_plain_txt(answers) or {
		error('${google_myaddr_name} answered with no plain address')
	}
}

// first_plain_txt returns the first answer that is not an EDNS Client Subnet
// annotation.
pub fn first_plain_txt(answers []string) ?string {
	for a in answers {
		if !a.starts_with('edns0-client-subnet') {
			return a
		}
	}
	return none
}

// interception_detected compares the two independent "what is my address"
// answers. Neither query goes through the machine's configured resolver, and
// both leave through the same gateway, so on a link with nothing intercepting
// DNS traffic they agree. A mismatch means one of the two paths was answered
// by something other than the resolver it was addressed to: docs/METHODOLOGY.md
// § Fairness rules calls this a security finding, not a measurement caveat.
//
// An empty address on either side means that side's query never got a usable
// answer, which is not evidence of anything and must not read as a mismatch.
pub fn interception_detected(opendns_ip string, google_ip string) bool {
	return opendns_ip != '' && google_ip != '' && opendns_ip != google_ip
}

// reverse_ipv4 turns 189.46.44.175 into 175.44.46.189, which is how the origin
// zone is keyed.
pub fn reverse_ipv4(ip string) !string {
	octets := ip.split('.')
	if octets.len != 4 {
		return error('"${ip}" is not an IPv4 address')
	}
	return '${octets[3]}.${octets[2]}.${octets[1]}.${octets[0]}'
}

// parse_origin_answer reads the ASN and the country out of an origin record.
//
//   "27699 | 189.46.0.0/15 | BR | lacnic | 2007-06-22"
//
// The first field carries every ASN announcing the prefix, space separated, and
// the first of them is taken. A prefix announced by more than one ASN is a
// multi-homed network, and either answer describes it.
pub fn parse_origin_answer(text string) (string, string) {
	fields := text.split('|').map(it.trim_space())
	if fields.len < 3 {
		return '', ''
	}
	asn := fields[0].split(' ').filter(it != '')
	if asn.len == 0 {
		return '', fields[2]
	}
	return asn[0], fields[2]
}

// parse_asn_answer reads the operator's name out of an ASN record.
//
//   "27699 | BR | lacnic | 2003-08-25 | AS27699 - TELEFONICA BRASIL S.A, BR"
//
// The last field repeats the ASN and the country around the name, and both are
// already known, so both are trimmed off rather than printed twice.
pub fn parse_asn_answer(text string) string {
	fields := text.split('|').map(it.trim_space())
	if fields.len < 5 {
		return ''
	}
	mut name := fields[4]
	if name.contains(' - ') {
		name = name.all_after(' - ')
	}
	if name.contains(',') {
		name = name.all_before_last(',')
	}
	return name.trim_space()
}

// ask_a and ask_txt put one question to one resolver and close the socket.
//
// They do not go through the Pacer and they are not part of the plan: they run
// once, before any provider is measured, and their timing is never recorded.
fn ask_a(resolver string, name string, timeout time.Duration) ![]string {
	response, _ := ask(resolver, name, qtype_a, timeout)!
	return response.a_addresses()
}

fn ask_txt(resolver string, name string, timeout time.Duration) ![]string {
	response, _ := ask(resolver, name, qtype_txt, timeout)!
	return response.txt_strings()
}

fn ask(resolver string, name string, qtype u16, timeout time.Duration) !(Response, []u8) {
	mut transport := &UdpTransport{}
	transport.open(Target{ ip: resolver, timeout: timeout })!
	defer {
		transport.close()
	}

	message := build_query(name, qtype)!
	reply, _ := transport.query(message)!
	if rcode(reply) != rcode_noerror {
		return error('${name} answered rcode ${rcode(reply)}')
	}
	return parse_response(reply)!, reply
}
