module main

import os
import rand
import time
import catalog
import core
import store

// The command-line frontend.
//
// It owns no measurement logic. It reads flags, assembles a plan, walks it,
// hands the samples to core/ and prints whatever store/ produces. A second
// frontend, the TUI, consumes the same core with no changes to it: that is what
// docs/ARCHITECTURE.md § Design constraints means by the core knowing nothing
// about frontends.
const tool_version = '0.1.0'

// The plan is walked in order rather than by one worker per provider.
//
// docs/ARCHITECTURE.md specifies a worker per provider, and that is the right
// shape once the encrypted transports arrive and a handshake is worth
// overlapping. It is not what this does yet, deliberately: the plan is already
// interleaved and shuffled, so walking it in order measures every provider
// under the same network conditions in turn, while concurrent workers would
// have them contending with each other for the link they are trying to measure.
// Sequential is slower and quieter; the speed matters less than the quiet.
struct Options {
	profile   string = 'balanced'
	only      []string
	rounds    int = 5
	probes    []string
	format    string = 'table'
	history   string
	force     bool
	seed      []u32
	timeout   time.Duration = 2 * time.second
	cold_zone string
}

fn main() {
	opts := parse_args(os.args[1..]) or {
		eprintln(err.msg())
		eprintln('')
		usage()
		exit(store.exit_usage)
	}

	result := run(opts) or {
		eprintln('dnsbench: ${err.msg()}')
		exit(store.exit_measurement_error)
	}

	match opts.format {
		'json' { print(result.to_json()) }
		'csv' { print(result.to_csv()) }
		'markdown' { print(result.to_markdown()) }
		else { print(result.to_table()) }
	}

	if opts.history != '' {
		store.append(opts.history, result) or {
			eprintln('dnsbench: could not append history to ${opts.history}: ${err.msg()}')
		}
	}

	exit(store.exit_code(result))
}

fn usage() {
	eprintln('usage: dnsbench [options]')
	eprintln('')
	eprintln('  --profile <name>   ${core.profiles.keys().join(', ')}  (default: balanced)')
	eprintln('  --only <keys>      comma-separated provider keys')
	eprintln('  --rounds <n>       measured rounds per provider (default: 5)')
	eprintln('  --probes <names>   warm, tcp, cold  (default: warm)')
	eprintln('  --format <name>    table, json, csv, markdown  (default: table)')
	eprintln('  --history <path>   append the run to a JSONL history file')
	eprintln('  --timeout <ms>     per-query timeout (default: 2000)')
	eprintln('  --cold-zone <zone> wildcard zone for the cold probe')
	eprintln('  --force            measure even with a tunnel interface up')
	eprintln('  --seed <n>         fix the shuffle, for a reproducible plan')
	eprintln('  -h, --help')
	eprintln('')
	eprintln('Exit: 0 ok, 1 measured with errors, 2 usage, 3 nothing reachable.')
}

// value_options are the flags that take an argument. --force and the help
// flags stand alone.
const value_options = ['--profile', '--only', '--rounds', '--probes', '--format', '--history',
	'--timeout', '--cold-zone', '--seed']

fn parse_args(args []string) !Options {
	mut o := Options{}
	mut i := 0

	for i < args.len {
		arg := args[i]
		if arg in ['-h', '--help'] {
			usage()
			exit(store.exit_usage)
		}
		if arg == '--force' {
			o = Options{ ...o, force: true }
			i++
			continue
		}
		// The name is checked before the value, so an option nobody recognises
		// says so instead of complaining that it is missing an argument.
		if arg !in value_options {
			return error('unknown option "${arg}"')
		}
		if i + 1 >= args.len {
			return error('${arg} needs a value')
		}
		value := args[i + 1]
		i += 2

		match arg {
			'--profile' {
				if value !in core.profiles {
					return error('unknown profile "${value}"; known: ${core.profiles.keys().join(', ')}')
				}
				o = Options{ ...o, profile: value }
			}
			'--only' {
				o = Options{ ...o, only: value.split(',').map(it.trim_space()).filter(it != '') }
			}
			'--rounds' {
				rounds := value.int()
				if rounds < 1 {
					return error('--rounds needs a positive integer, got "${value}"')
				}
				o = Options{ ...o, rounds: rounds }
			}
			'--probes' {
				names := value.split(',').map(it.trim_space()).filter(it != '')
				for name in names {
					if name !in ['warm', 'tcp', 'cold'] {
						return error('unknown probe "${name}"; known: warm, tcp, cold')
					}
				}
				o = Options{ ...o, probes: names }
			}
			'--format' {
				if value !in ['table', 'json', 'csv', 'markdown'] {
					return error('unknown format "${value}"')
				}
				o = Options{ ...o, format: value }
			}
			'--history' {
				o = Options{ ...o, history: value }
			}
			'--timeout' {
				ms := value.int()
				if ms < 1 {
					return error('--timeout needs a positive number of milliseconds')
				}
				o = Options{ ...o, timeout: ms * time.millisecond }
			}
			'--cold-zone' {
				o = Options{ ...o, cold_zone: value }
			}
			'--seed' {
				n := u32(value.u64())
				o = Options{ ...o, seed: [n, n ^ u32(0x9e3779b9)] }
			}
			else {
				return error('unknown option "${arg}"')
			}
		}
	}

	if o.probes.len == 0 {
		o = Options{ ...o, probes: ['warm'] }
	}
	return o
}

// A provider under measurement, with the samples it has produced so far.
struct Subject {
	key      string
	label    string
	ip       string
	is_cache bool
	declared []string
mut:
	samples map[string][]f64
	failed  map[string]int
	// Attempts the resolver answered with a non-NOERROR rcode, held apart from
	// `failed`: one is a resolver declining, the other is nothing coming back.
	refused map[string]int
}

fn run(opts Options) !store.RunResult {
	started := time.now()
	net := core.detect()

	mut warnings := []store.Warning{}

	if net.vpn_detected() {
		// docs/METHODOLOGY.md § Fail loudly on interference. Every number after
		// this point would describe the tunnel rather than the link, so the run
		// stops unless the user says otherwise.
		message := 'tunnel interfaces are up: ${net.tunnels.join(', ')}. You would be measuring the tunnel, not the link.'
		if !opts.force {
			return error('${message}\n       Pass --force to measure anyway.')
		}
		warnings << store.Warning{
			level: 'warn'
			key: 'network'
			message: message
		}
	}

	cat := catalog.embedded()!
	mut subjects := select_subjects(cat, opts, net, mut warnings)!
	if subjects.len == 0 {
		return error('no provider left to measure')
	}

	mut probes := opts.probes.clone()
	if 'cold' in probes && opts.cold_zone == '' {
		// docs/DATA.md § Cold-probe zone: without a zone there is nothing to
		// recurse to, and falling back to random labels under public domains
		// would generate NXDOMAIN traffic against third parties.
		probes = probes.filter(it != 'cold')
		warnings << store.Warning{
			level: 'warn'
			key: 'cold'
			message: 'cold probe skipped: no --cold-zone configured'
		}
		if probes.len == 0 {
			return error('every requested probe was skipped')
		}
	}

	mut keys := []string{cap: subjects.len}
	for s in subjects {
		keys << s.key
	}

	plan := core.build_plan(
		provider_keys: keys
		probes: probes
		domains: warm_domains
		rounds: opts.rounds
		seed: opts.seed
	)!

	execute(plan, mut subjects, opts)!

	duration := f64(time.since(started).microseconds()) / 1_000_000.0
	return assemble(subjects, probes, opts, net, cat, started, duration, warnings)
}

// warm_domains stands in for the pinned Tranco set of docs/DATA.md, which is
// generated offline and embedded at release time. This is not that set, and the
// id below says so rather than claiming a Tranco ID it does not have.
//
// Eight names, because a round is one pass over the set and five rounds must
// clear the thirty-sample floor a ranked result needs: 5 x 8 = 40, which is the
// same n the worked example in docs/TUI.md shows.
const warm_domains = [
	'google.com',
	'youtube.com',
	'wikipedia.org',
	'amazon.com',
	'github.com',
	'cloudflare.com',
	'microsoft.com',
	'reddit.com',
]

const domain_set_id = 'builtin:top8'

fn select_subjects(cat catalog.Catalog, opts Options, net core.NetInfo, mut warnings []store.Warning) ![]Subject {
	mut out := []Subject{}

	for p in cat.providers {
		if opts.only.len > 0 && p.key !in opts.only {
			continue
		}
		if p.needs_config {
			// Its endpoints still carry placeholders, so probing it would
			// measure a hostname that does not exist.
			warnings << store.Warning{
				level: 'info'
				key: p.key
				message: '${p.key} skipped: its endpoints need configuration'
			}
			continue
		}
		if p.udp4.len == 0 {
			// Encrypted-only entries are not failures, and must not read as
			// absence either. Mullvad publishes DoT and DoH and no usable
			// plaintext address, so there is nothing here to measure until the
			// encrypted transports land; a row that simply vanishes reads as a
			// tool that forgot the provider.
			warnings << store.Warning{
				level: 'info'
				key: p.key
				message: '${p.key} skipped: no plaintext endpoint, DoT and DoH only'
			}
			continue
		}
		out << Subject{
			key: p.key
			label: p.label
			ip: p.udp4[0]
			declared: p.declared()
		}
	}

	// The machine's own resolvers compete too, correctly labelled. A local
	// cache is measured and shown apart rather than left out.
	for r in net.resolvers {
		if opts.only.len > 0 && r.ip !in opts.only {
			continue
		}
		if out.any(it.ip == r.ip) {
			continue
		}
		out << Subject{
			key: 'system-${r.ip}'
			label: 'system ${r.ip}'
			ip: r.ip
			is_cache: r.is_cache
		}
	}

	if opts.only.len > 0 && out.len == 0 {
		// A key that matched and was then skipped is a different failure from a
		// key that matched nothing, and the reason is already in the warnings.
		if warnings.len > 0 {
			return error('--only selected nothing measurable: ${warnings.map(it.message).join('; ')}')
		}
		return error('--only matched no provider: ${opts.only.join(', ')}')
	}
	return out
}

// execute walks the plan and fills in the samples.
//
// A step that fails contributes to loss and nothing else; the run never stops
// for one bad provider, because the networks where that happens are exactly the
// ones worth measuring. docs/ARCHITECTURE.md § Failure policy.
fn execute(plan []core.Step, mut subjects []Subject, opts Options) ! {
	mut udp := map[string]&core.UdpTransport{}
	mut tcp := map[string]&core.TcpTransport{}
	mut pacer := core.new_pacer(core.rate_interval)
	start := time.new_stopwatch()

	defer {
		for _, mut t in udp {
			t.close()
		}
		for _, mut t in tcp {
			t.close()
		}
	}

	for step in plan {
		mut idx := -1
		for i, s in subjects {
			if s.key == step.provider_key {
				idx = i
				break
			}
		}
		if idx < 0 {
			continue
		}

		target := core.Target{
			ip: subjects[idx].ip
			timeout: opts.timeout
		}

		// Politeness first: never send before the provider's own budget allows.
		now := start.elapsed().nanoseconds()
		send_at := pacer.reserve(step.provider_key, now, core.jitter_factor())
		if send_at > now {
			time.sleep(send_at - now)
		}

		out := query_once(step, target, opts.cold_zone, mut udp, mut tcp) or {
			if !step.discard {
				subjects[idx].failed[step.probe]++
			}
			continue
		}

		// The warm-up query is sent like any other and its result thrown away:
		// it paid for cache fill, ARP and route setup that no later query pays.
		if step.discard {
			continue
		}
		if out.code != core.rcode_noerror {
			// An answer, and not a measurement. It is not a sample and it is
			// not a dropped packet either.
			subjects[idx].refused[step.probe]++
			continue
		}
		subjects[idx].samples[step.probe] << out.ms
	}
}

// Outcome is one completed exchange: a latency and the rcode that came with
// it. The rcode is returned rather than folded into an error because a resolver
// that answers REFUSED has answered, and the caller is the only place that
// knows the difference matters.
struct Outcome {
	ms   f64
	code int
}

fn query_once(step core.Step, target core.Target, cold_zone string, mut udp map[string]&core.UdpTransport, mut tcp map[string]&core.TcpTransport) !Outcome {
	msg := core.build_query(query_name(step, cold_zone), core.qtype_a)!

	if step.probe == 'tcp' {
		// A TCP connection is reopened per round rather than held for the whole
		// run: this measures the fallback path as a client would use it, and
		// docs/METHODOLOGY.md keeps the amortised-handshake variant for DoT.
		if step.provider_key !in tcp {
			mut t := &core.TcpTransport{}
			t.open(target)!
			tcp[step.provider_key] = t
		}
		mut t := tcp[step.provider_key] or { return error('no tcp transport') }
		reply, ms := t.query(msg)!
		return Outcome{
			ms: ms
			code: core.rcode(reply)
		}
	}

	if step.provider_key !in udp {
		mut t := &core.UdpTransport{}
		t.open(target)!
		udp[step.provider_key] = t
	}
	mut t := udp[step.provider_key] or { return error('no udp transport') }
	reply, ms := t.query(msg)!
	return Outcome{
		ms: ms
		code: core.rcode(reply)
	}
}

// query_name is the name actually asked.
//
// For every probe but `cold` it is the plan's domain. `cold` has to ask
// something no resolver on Earth has looked up, so the label is drawn fresh per
// query under the operator's wildcard zone. That is deliberately not
// reproducible from the plan's seed: a label the plan could reproduce would be
// in the resolver's cache the second time it was asked, and the probe would
// stop measuring recursion.
//
// The zone answers a wildcard with a 60-second TTL, so every resolver recurses
// to the same authoritative network with the same TTL, and no third party
// receives NXDOMAIN traffic on our behalf. docs/DATA.md § Cold-probe zone.
fn query_name(step core.Step, cold_zone string) string {
	if step.probe != 'cold' {
		return step.domain
	}
	return '${rand.string_from_set('abcdefghijklmnopqrstuvwxyz0123456789', 16)}.${cold_zone}'
}

// checked rejects an answer that is not a successful lookup.
//
// A resolver that refuses fast is not a fast resolver. Counting a SERVFAIL as a
// latency sample would let a provider that answers nothing useful outrank one
// that answers correctly.
fn assemble(subjects []Subject, probes []string, opts Options, net core.NetInfo, cat catalog.Catalog, started time.Time, duration f64, warnings []store.Warning) store.RunResult {
	weights := core.profiles[opts.profile] or { core.Weights{} }
	expected := core.expected_samples(opts.rounds, warm_domains.len)

	mut samples := []core.Samples{cap: subjects.len}
	for s in subjects {
		samples << core.Samples{
			base: core.Metrics{
				key: s.key
				is_cache: s.is_cache
				offers_ipv6: net.ipv6
				declared: s.declared
			}
			warm_ms: s.samples['warm'] or { []f64{} }
			cold_ms: s.samples['cold'] or { []f64{} }
			dot_warm_ms: []f64{}
			warm_expected: if 'warm' in probes { expected } else { 0 }
			cold_expected: if 'cold' in probes { expected } else { 0 }
			dot_warm_expected: 0
			warm_refused: s.refused['warm'] or { 0 }
			cold_refused: s.refused['cold'] or { 0 }
			dot_warm_refused: 0
		}
	}

	ranked := core.rank_providers(samples, none, weights, core.BootstrapSpec{ seed: opts.seed }) or {
		[]core.Ranked{}
	}
	bests := core.compute_bests(metrics_from(samples), none)

	mut results := []store.ProviderResult{cap: subjects.len}
	for r in ranked {
		mut idx := -1
		for i, s in subjects {
			if s.key == r.key {
				idx = i
				break
			}
		}
		if idx < 0 {
			continue
		}
		subject := subjects[idx]

		mut reports := []store.ProbeReport{cap: probes.len}
		for name in probes {
			reports << store.ProbeReport{
				name: name
				stats: core.compute_counted(subject.samples[name] or { []f64{} }, expected, subject.refused[name] or { 0 })
			}
		}

		mut metrics := core.Metrics{}
		for m in metrics_from(samples) {
			if m.key == r.key {
				metrics = m
				break
			}
		}

		results << store.ProviderResult{
			key: subject.key
			label: subject.label
			ranked: r
			subscores: core.subscores(metrics, bests)
			is_cache: subject.is_cache
			probes: reports
			capabilities: store.Capabilities{
				// dnssec_validating stays absent until the probe that
				// establishes it lands in M2. Absent is not false.
				transports: transports_used(probes)
				ipv6: net.ipv6
			}
			declared: subject.declared
		}
	}

	return store.RunResult{
		tool: store.Tool{
			version: tool_version
		}
		run: store.Run{
			started_at: started.format_rfc3339()
			duration_s: duration
			complete: true
			rounds: opts.rounds
			profile: opts.profile
			weights: weights
		}
		network: store.Network{
			ifname: net.ifname
			ipv6: net.ipv6
			region: 'global'
			vpn_detected: net.vpn_detected()
		}
		datasets: store.Datasets{
			catalog: store.CatalogInfo{
				version: cat.version
				providers: cat.providers.len
			}
			domains: store.DomainInfo{
				warm: domain_set_id
				cold_mode: if opts.cold_zone == '' { 'off' } else { 'own' }
			}
		}
		results: results
		warnings: warnings
	}
}

// transports_used maps the probes that ran to the transports they rode.
//
// The output contract names transports, not probes: `warm` and `cold` are two
// questions asked over the same UDP socket. Emitting probe names here made the
// schema reject the run, which is the schema doing its job.
fn transports_used(probes []string) []string {
	mut out := []string{}
	for probe in probes {
		name := match probe {
			'tcp' { 'tcp' }
			else { 'udp' }
		}
		if name !in out {
			out << name
		}
	}
	return out
}

fn metrics_from(samples []core.Samples) []core.Metrics {
	mut out := []core.Metrics{cap: samples.len}
	for s in samples {
		out << core.Metrics{
			key: s.base.key
			is_cache: s.base.is_cache
			warm: core.compute_counted(s.warm_ms, s.warm_expected, s.warm_refused)
			cold: core.compute_counted(s.cold_ms, s.cold_expected, s.cold_refused)
			dot_warm: core.compute_counted(s.dot_warm_ms, s.dot_warm_expected, s.dot_warm_refused)
			ecs_penalty_ms: s.base.ecs_penalty_ms
			dnssec_validating: s.base.dnssec_validating
			offers_dot: s.base.offers_dot
			offers_doh: s.base.offers_doh
			offers_ipv6: s.base.offers_ipv6
			declared: s.base.declared
		}
	}
	return out
}
