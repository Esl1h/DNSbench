module store

import core
import json2

// The output contract, as published in docs/OUTPUT.md and enforced by
// schema/result.schema.json.
//
// The JSON is assembled from json2.Any maps rather than encoded from structs,
// because an absent option encodes as a missing key and the contract calls for
// an explicit null. See docs/V-NOTES.md.
//
// Table and markdown carry no stability guarantee and are free to change.
// `--json` is the one that must keep working, so it is the one the schema
// covers and the golden files pin.
pub const schema_version = 1

pub struct Tool {
pub:
	name    string = 'dnsbench'
	version string
	commit  string
}

pub struct Run {
pub:
	started_at string // RFC 3339, with offset
	duration_s f64
	// complete is false when the run was interrupted. Partial results are
	// emitted either way: docs/ARCHITECTURE.md § Failure policy.
	complete bool
	// rounds counts the measured rounds and excludes the discarded warm-up.
	rounds  int
	profile string
	weights core.Weights
}

pub struct Network {
pub:
	asn     string
	asn_org string
	ifname  string
	ipv6    bool
	region  string
	// one of flag, config, rir, tz, default
	region_source    string = 'default'
	vpn_detected     bool
	dns_interception bool
}

pub struct CatalogInfo {
pub:
	source    string = 'embedded'
	version   int
	providers int
}

pub struct DomainInfo {
pub:
	warm      string
	regional  string
	cold_mode string = 'own'
}

pub struct CdnHostInfo {
pub:
	total int
	stale int
}

pub struct Datasets {
pub:
	catalog   CatalogInfo
	domains   DomainInfo
	cdn_hosts CdnHostInfo
}

pub struct ProbeReport {

	// warm, cold, tcp, dot_fresh, dot_warm, doh, ...
pub:
	name  string
	stats core.Stats
	// http_version is DoH only, and exists because an h1.1 measurement is not
	// comparable to a browser's real h2 behaviour.
	http_version string
}

pub struct EdgeHost {
pub:
	host       string
	answer     ?string
	connect_ms ?f64
	penalty_ms ?f64
	stale      bool
}

pub struct Edge {
pub:
	median_penalty_ms ?f64
	// misrouted, out of measured, is how many hosts came back far enough adrift
	// to have been sent to the wrong region. It informs and does not rank.
	misrouted int
	measured  int
	hosts     []EdgeHost
}

pub struct Capabilities {

	// Absent when no probe established it, which is not the same as false.
pub:
	dnssec_validating ?bool
	filtering         map[string]bool
	transports        []string
	ipv6              bool
}

pub struct ProviderResult {
pub:
	key       string
	label     string
	ranked    core.Ranked
	subscores core.Subscores
	is_cache  bool
	probes    []ProbeReport
	edge      Edge
	// capabilities is measured. declared is what the provider says. Consumers
	// must not merge them, and neither does this.
	capabilities Capabilities
	declared     []string
	warnings     []Warning
}

pub struct Warning {

	// info, warn or error
pub:
	level   string = 'warn'
	key     string
	message string
}

pub struct RunResult {
pub:
	tool     Tool
	run      Run
	network  Network
	datasets Datasets
	results  []ProviderResult
	warnings []Warning
}

// ── JSON ─────────────────────────────────────────────────────────────────────

// to_json emits the machine-readable form. Anything consuming it must keep
// working across minor versions: docs/OUTPUT.md § Stability policy.
pub fn (r RunResult) to_json() string {
	mut doc := map[string]json2.Any{}
	doc['schema_version'] = schema_version
	doc['tool'] = json2.Any({
		'name':    json2.Any(r.tool.name)
		'version': json2.Any(r.tool.version)
		'commit':  json2.Any(r.tool.commit)
	})
	doc['run'] = json2.Any({
		'started_at': json2.Any(r.run.started_at)
		'duration_s': json2.Any(r.run.duration_s)
		'complete':   json2.Any(r.run.complete)
		'rounds':     json2.Any(r.run.rounds)
		'profile':    json2.Any(r.run.profile)
		'weights':    weights_json(r.run.weights)
	})
	doc['network'] = json2.Any({
		'asn':              json2.Any(r.network.asn)
		'asn_org':          json2.Any(r.network.asn_org)
		'interface':        json2.Any(r.network.ifname)
		'ipv6':             json2.Any(r.network.ipv6)
		'region':           json2.Any(r.network.region)
		'region_source':    json2.Any(r.network.region_source)
		'vpn_detected':     json2.Any(r.network.vpn_detected)
		'dns_interception': json2.Any(r.network.dns_interception)
	})
	doc['datasets'] = json2.Any({
		'catalog':   json2.Any({
			'source':    json2.Any(r.datasets.catalog.source)
			'version':   json2.Any(r.datasets.catalog.version)
			'providers': json2.Any(r.datasets.catalog.providers)
		})
		'domains':   json2.Any({
			'warm':      json2.Any(r.datasets.domains.warm)
			'regional':  json2.Any(r.datasets.domains.regional)
			'cold_mode': json2.Any(r.datasets.domains.cold_mode)
		})
		'cdn_hosts': json2.Any({
			'total': json2.Any(r.datasets.cdn_hosts.total)
			'stale': json2.Any(r.datasets.cdn_hosts.stale)
		})
	})

	mut results := []json2.Any{cap: r.results.len}
	for p in r.results {
		results << provider_json(p)
	}
	doc['results'] = json2.Any(results)

	mut warnings := []json2.Any{cap: r.warnings.len}
	for w in r.warnings {
		warnings << warning_json(w)
	}
	doc['warnings'] = json2.Any(warnings)

	return json2.encode(json2.Any(doc), prettify: true)
}

fn weights_json(w core.Weights) json2.Any {
	return json2.Any({
		'latency':     json2.Any(w.latency)
		'recursion':   json2.Any(w.recursion)
		'stability':   json2.Any(w.stability)
		'reliability': json2.Any(w.reliability)
		'edge':        json2.Any(w.edge)
		'encrypted':   json2.Any(w.encrypted)
		'capability':  json2.Any(w.capability)
		'privacy':     json2.Any(w.privacy)
	})
}

fn provider_json(p ProviderResult) json2.Any {
	mut m := map[string]json2.Any{}
	m['key'] = p.key
	m['label'] = p.label
	m['is_cache'] = p.is_cache

	// An excluded provider is ranked nowhere and says why, rather than being
	// silently absent from the array.
	if excluded := p.ranked.excluded {
		m['excluded'] = excluded.str()
		m['rank'] = json2.Any(json2.null)
		m['tier'] = json2.Any(json2.null)
		m['score'] = json2.Any(json2.null)
	} else {
		m['excluded'] = json2.Any(json2.null)
		m['rank'] = p.ranked.rank
		m['tier'] = p.ranked.tier
		m['score'] = round1(p.ranked.score)
	}

	// The interval that decided the tier travels with the tier. Without it a
	// reader can see that two providers share a band but not why, and
	// docs/ARCHITECTURE.md asks for results that can be re-derived from the
	// output alone.
	if low := p.ranked.ci_low {
		if high := p.ranked.ci_high {
			m['score_ci'] = json2.Any([json2.Any(round1(low)), json2.Any(round1(high))])
		} else {
			m['score_ci'] = json2.Any(json2.null)
		}
	} else {
		m['score_ci'] = json2.Any(json2.null)
	}

	mut subs := map[string]json2.Any{}
	put_opt(mut subs, 'latency', p.subscores.latency)
	put_opt(mut subs, 'recursion', p.subscores.recursion)
	put_opt(mut subs, 'stability', p.subscores.stability)
	subs['reliability'] = round1(p.subscores.reliability)
	put_opt(mut subs, 'edge', p.subscores.edge)
	put_opt(mut subs, 'encrypted', p.subscores.encrypted)
	subs['capability'] = round1(p.subscores.capability)
	subs['privacy'] = round1(p.subscores.privacy)
	m['subscores'] = json2.Any(subs)

	mut probes := map[string]json2.Any{}
	for probe in p.probes {
		probes[probe.name] = probe_json(probe)
	}
	m['probes'] = json2.Any(probes)

	mut hosts := []json2.Any{cap: p.edge.hosts.len}
	for h in p.edge.hosts {
		mut hm := map[string]json2.Any{}
		hm['host'] = h.host
		hm['answer'] = if v := h.answer { json2.Any(v) } else { json2.Any(json2.null) }
		hm['connect_ms'] = opt_any(h.connect_ms)
		hm['penalty_ms'] = opt_any(h.penalty_ms)
		hm['stale'] = h.stale
		hosts << json2.Any(hm)
	}
	m['edge'] = json2.Any({
		'median_penalty_ms': opt_any(p.edge.median_penalty_ms)
		'misrouted':         json2.Any(p.edge.misrouted)
		'measured':          json2.Any(p.edge.measured)
		'hosts':             json2.Any(hosts)
	})

	mut filtering := map[string]json2.Any{}
	for name, blocked in p.capabilities.filtering {
		filtering[name] = blocked
	}
	mut transports := []json2.Any{cap: p.capabilities.transports.len}
	for t in p.capabilities.transports {
		transports << json2.Any(t)
	}
	m['capabilities'] = json2.Any({
		'dnssec_validating': if v := p.capabilities.dnssec_validating {
			json2.Any(v)
		} else {
			json2.Any(json2.null)
		}
		'filtering':         json2.Any(filtering)
		'transports':        json2.Any(transports)
		'ipv6':              json2.Any(p.capabilities.ipv6)
	})

	mut declared := []json2.Any{cap: p.declared.len}
	for d in p.declared {
		declared << json2.Any(d)
	}
	m['declared'] = json2.Any(declared)

	mut warnings := []json2.Any{cap: p.warnings.len}
	for w in p.warnings {
		warnings << warning_json(w)
	}
	m['warnings'] = json2.Any(warnings)

	return json2.Any(m)
}

fn probe_json(p ProbeReport) json2.Any {
	mut m := map[string]json2.Any{}
	m['n'] = p.stats.n
	m['expected'] = p.stats.expected
	m['refused'] = p.stats.refused
	// Null, never 0: a probe with no sample has no median, and 0 is the best
	// latency on the page. docs/METHODOLOGY.md § Nothing is not zero.
	m['p50'] = opt_any(p.stats.p50)
	m['p95'] = opt_any(p.stats.p95)
	m['max'] = opt_any(p.stats.max)
	m['mean'] = opt_any(p.stats.mean)
	m['jitter'] = opt_any(p.stats.jitter)
	m['loss'] = round1(p.stats.loss)
	if p.http_version != '' {
		m['http_version'] = p.http_version
	}
	return json2.Any(m)
}

fn warning_json(w Warning) json2.Any {
	return json2.Any({
		'level':   json2.Any(w.level)
		'key':     if w.key == '' { json2.Any(json2.null) } else { json2.Any(w.key) }
		'message': json2.Any(w.message)
	})
}

fn put_opt(mut m map[string]json2.Any, key string, v ?f64) {
	m[key] = opt_any(v)
}

fn opt_any(v ?f64) json2.Any {
	value := v or { return json2.Any(json2.null) }
	return json2.Any(round1(value))
}

// round1 keeps the JSON to the precision the tool actually claims. Emitting
// full binary expansions would suggest a resolution the measurement does not
// have.
fn round1(v f64) f64 {
	return f64(int(v * 10.0 + if v < 0 { -0.5 } else { 0.5 })) / 10.0
}

// ── CSV ──────────────────────────────────────────────────────────────────────

// to_csv is one row per (provider, probe), for spreadsheets and for people who
// will not install jq. An absent figure is an empty field, which is what a
// spreadsheet reads as no data rather than as zero.
pub fn (r RunResult) to_csv() string {
	mut out := [
		'provider,probe,n,expected,refused,p50,p95,max,jitter,loss,edge_penalty,edge_misrouted,score',
	]
	for p in r.results {
		score := if p.ranked.excluded != none { '' } else { fmt1(p.ranked.score) }
		penalty := csv_opt(p.edge.median_penalty_ms)
		for probe in p.probes {
			out << '${p.key},${probe.name},${probe.stats.n},${probe.stats.expected},' + '${probe.stats.refused},${csv_opt(probe.stats.p50)},${csv_opt(probe.stats.p95)},${csv_opt(probe.stats.max)},' + '${csv_opt(probe.stats.jitter)},${fmt1(probe.stats.loss)},${penalty},${p.edge.misrouted},${score}'
		}
	}
	return out.join('\n') + '\n'
}

fn csv_opt(v ?f64) string {
	value := v or { return '' }
	return fmt1(value)
}

fn fmt1(v f64) string {
	return '${v:.1f}'
}

// ── exit codes ───────────────────────────────────────────────────────────────

// The exit codes from docs/OUTPUT.md. They are part of the contract, because a
// cron job or a CI step decides what to do from them.
pub const exit_ok = 0

pub const exit_measurement_error = 1

pub const exit_usage = 2

pub const exit_no_provider_reachable = 3

pub const exit_catalog_verification = 4

// exit_code derives the process status from the run itself.
//
// The distinction that matters is between a run that measured badly and a run
// that could not measure at all. A monitoring job seeing 1 has numbers to look
// at; seeing 3 it has a connectivity problem and the numbers are beside the
// point.
pub fn exit_code(r RunResult) int {
	if r.results.len == 0 {
		return exit_no_provider_reachable
	}

	mut reachable := 0
	for p in r.results {
		if p.ranked.excluded or { core.Exclusion.cache } != .unreachable {
			reachable++
		}
	}
	if reachable == 0 {
		return exit_no_provider_reachable
	}

	// An interrupted run emits what it has and says so, and the caller is told
	// the results are partial rather than being left to infer it.
	if !r.run.complete {
		return exit_measurement_error
	}
	for p in r.results {
		// Refused joins unreachable here: the provider answered, so the run is
		// not a total loss, but nothing was measured for it and a caller that
		// checks only the exit code has to learn that.
		reason := p.ranked.excluded or { continue }
		if reason == .unreachable || reason == .refused {
			return exit_measurement_error
		}
	}
	return exit_ok
}

// ── table ────────────────────────────────────────────────────────────────────

// to_table renders the ranked table for a terminal.
//
// This format carries no stability guarantee: do not parse it, use --json.
// Colour is absent by design here; the TUI owns the colour semantics in
// docs/TUI.md, and a piped CLI run should be plain text whatever NO_COLOR says.
//
// Caches sit below the line in their own section with no score. A 0.3 ms cache
// hit is not competing with a 15 ms network round trip; it is a different
// measurement wearing the same units, and putting them in one list is the error
// docs/SCORING.md calls the most important exclusion there is.
pub fn (r RunResult) to_table() string {
	mut out := []string{}

	asn := if r.network.asn == '' { 'ASN unknown' } else { '${r.network.asn} ${r.network.asn_org}' }
	out << 'dnsbench ${r.tool.version}   ${asn}   ${r.network.ifname}   IPv6: ${yes_no(r.network.ipv6)}   region: ${r.network.region}'
	out << 'catalog v${r.datasets.catalog.version} (${r.datasets.catalog.source}, ${r.datasets.catalog.providers})   domains ${r.datasets.domains.warm}   cold: ${r.datasets.domains.cold_mode}   profile: ${r.run.profile}'
	out << 'rounds ${r.run.rounds}   ${r.run.duration_s:.1f}s elapsed' + if r.run.complete {
		''
	} else {
		'   INTERRUPTED, results are partial'
	}
	out << ''
	out << '  #  PROVIDER              SCORE    p50    p95    JIT   LOSS   EDGE   MIS  FLAGS'
	out << '  ' + '-'.repeat(76)

	mut last_tier := 0
	for p in r.results {
		if p.ranked.excluded != none {
			continue
		}
		// A dim rule between tiers, so a shared band is visible without colour.
		if last_tier != 0 && p.ranked.tier != last_tier {
			out << '  ' + '-'.repeat(76)
		}
		last_tier = p.ranked.tier
		out << row_for(p, '${p.ranked.rank:3d}')
	}

	if last_tier == 0 {
		out << '     no provider produced a ranked result'
	}

	mut excluded := r.results.filter(it.ranked.excluded != none)
	if excluded.len > 0 {
		out << ''
		out << '  -- not ranked ' + '-'.repeat(62)
		for p in excluded {
			reason := p.ranked.excluded or { core.Exclusion.cache }
			out << row_for(p, '  .') + '  (${reason.str()})'
		}
	}

	if r.warnings.len > 0 {
		out << ''
		for w in r.warnings {
			out << ' ! ${w.message}'
		}
	}
	if r.results.any(it.declared.len > 0) {
		out << ' ~ declared by provider, not measured'
	}

	return out.join('\n') + '\n'
}

fn row_for(p ProviderResult, rank string) string {
	warm := probe_named(p, 'warm')
	score := if p.ranked.excluded != none { '    -' } else { '${p.ranked.score:5.1f}' }

	mut flags := []string{}
	if v := p.capabilities.dnssec_validating {
		flags << if v { '+DNSSEC' } else { '-DNSSEC' }
	}
	for d in p.declared {
		flags << '~${d}'
	}

	return '${rank}  ${p.label:-20s}  ${score}  ' + '${cell(warm.p50)}  ${cell(warm.p95)}  ' + '${cell(warm.jitter)}  ${warm.loss:5.1f}%  ' + '${cell(p.edge.median_penalty_ms)}  ${misrouted_cell(p.edge):4s}  ${flags.join(' ')}'
}

fn probe_named(p ProviderResult, name string) core.Stats {
	for probe in p.probes {
		if probe.name == name {
			return probe.stats
		}
	}
	return core.Stats{}
}

// misrouted_cell prints the count as a fraction of what was measured, because
// 3 on its own is unreadable without knowing whether the set held four hosts or
// forty. A run with no edge probe shows nothing rather than 0/0.
fn misrouted_cell(e Edge) string {
	if e.measured == 0 {
		return '-'
	}
	return '${e.misrouted}/${e.measured}'
}

// cell prints a dash where there is no figure. A zero would be the best value
// in the column.
fn cell(v ?f64) string {
	value := v or { return '    -' }
	return '${value:5.1f}'
}

fn yes_no(b bool) string {
	return if b { 'yes' } else { 'no' }
}

// ── markdown ─────────────────────────────────────────────────────────────────

// to_markdown emits the ranked table for pasting into an issue or a post, with
// the run metadata alongside so the result stays self-describing once it leaves
// this terminal.
pub fn (r RunResult) to_markdown() string {
	mut out := []string{}

	out << '<!--'
	out << 'dnsbench ${r.tool.version} ${r.tool.commit}'
	out << 'network ${r.network.asn} ${r.network.asn_org} ${r.network.ifname} ipv6=${r.network.ipv6} region=${r.network.region}'
	out << 'catalog v${r.datasets.catalog.version} domains=${r.datasets.domains.warm} cold=${r.datasets.domains.cold_mode}'
	out << 'profile ${r.run.profile} rounds=${r.run.rounds} complete=${r.run.complete} started=${r.run.started_at}'
	out << '-->'
	out << ''
	out << '| # | Provider | Score | p50 | p95 | Jitter | Loss | Edge | Misrouted | Flags |'
	out << '|---|---|---:|---:|---:|---:|---:|---:|---:|---|'

	for p in r.results {
		warm := probe_named(p, 'warm')
		rank := if excluded := p.ranked.excluded { excluded.str() } else { '${p.ranked.rank}' }
		score := if p.ranked.excluded != none { '-' } else { '${p.ranked.score:.1f}' }

		mut flags := []string{}
		if v := p.capabilities.dnssec_validating {
			flags << if v { 'DNSSEC' } else { 'no DNSSEC' }
		}
		for d in p.declared {
			flags << '~${d}'
		}

		out << '| ${rank} | ${p.label} | ${score} | ${md_cell(warm.p50)} | ${md_cell(warm.p95)} |' + ' ${md_cell(warm.jitter)} | ${warm.loss:.1f}% | ${md_cell(p.edge.median_penalty_ms)} | ${misrouted_cell(p.edge)} |' + ' ${flags.join(', ')} |'
	}

	out << ''
	out << '`~` is declared by the provider and not measured by the tool.'
	return out.join('\n') + '\n'
}

fn md_cell(v ?f64) string {
	value := v or { return 'n/a' }
	return '${value:.1f}'
}
