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
	ca_bundle string
}

fn main() {
	// A DoT server is free to close an idle connection, and dot_warm holds one
	// open across the whole interleaved plan. Writing to a socket the peer has
	// closed then raises SIGPIPE, whose default action is to kill the process
	// mid-run with no output at all. The write returns an error instead, which
	// the transport already knows how to report.
	os.signal_ignore(.pipe)

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
	eprintln('  --probes <names>   warm, tcp, cold, ecs, dot-fresh, dot-warm  (default: warm)')
	eprintln('  --format <name>    table, json, csv, markdown  (default: table)')
	eprintln('  --history <path>   append the run to a JSONL history file')
	eprintln('  --timeout <ms>     per-query timeout (default: 2000)')
	eprintln('  --cold-zone <zone> wildcard zone for the cold probe')
	eprintln('  --ca-bundle <path> CA bundle for DoT, overriding the system cascade')
	eprintln('  --force            measure even with a tunnel interface up')
	eprintln('  --seed <n>         fix the shuffle, for a reproducible plan')
	eprintln('  -h, --help')
	eprintln('')
	eprintln('Exit: 0 ok, 1 measured with errors, 2 usage, 3 nothing reachable.')
}

// value_options are the flags that take an argument. --force and the help
// flags stand alone.
const value_options = ['--profile', '--only', '--rounds', '--probes', '--format', '--history',
	'--timeout', '--cold-zone', '--ca-bundle', '--seed']

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
				// The documents write dot-fresh and dot-warm; the output contract
				// writes dot_fresh and dot_warm. Both spellings are accepted and
				// the underscore is the one that travels onward, so there is a
				// single internal name.
				names := value.split(',').map(it.trim_space().replace('-', '_')).filter(it != '')
				for name in names {
					if name !in known_probes {
						return error('unknown probe "${name}"; known: ${known_probes.join(', ')}')
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
			'--ca-bundle' {
				o = Options{ ...o, ca_bundle: value }
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
	key   string
	label string
	ip    string
	// dot_ip and dot_host are the address to dial and the name the certificate
	// is verified against. Empty when the entry offers no DoT.
	dot_ip   string
	dot_host string
	// probes is what this subject can actually run. It is not always the run's
	// probe list: an encrypted-only provider has no plaintext probe.
	probes   []string
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

	// The trust anchor is resolved once, before anything is measured, so a
	// missing bundle is a startup error rather than sixteen identical handshake
	// failures. docs/ARCHITECTURE.md § TLS trust anchor.
	mut ca_bundle := ''
	if probes.any(it in dot_probes) {
		ca_bundle = core.find_ca_bundle(opts.ca_bundle)!
	}

	mut subjects := select_subjects(cat, opts, net, probes, mut warnings)!
	if subjects.len == 0 {
		return error('no provider left to measure')
	}

	// The edge probe is not a latency probe and does not belong in the plan: it
	// asks each CDN host once per provider and times a TCP connect, where the
	// plan is rounds over a domain set. It also cannot rank on its own, because
	// a provider is excluded on `warm` before any subscore is read.
	run_edge := 'ecs' in probes
	timed := timed_probes(probes)!
	if run_edge && cat.cdn_hosts.len == 0 {
		return error('the catalog carries no cdn_host entries for the edge probe')
	}

	mut keys := []string{cap: subjects.len}
	mut probes_for := map[string][]string{}
	for s in subjects {
		keys << s.key
		own := s.probes.filter(it != 'ecs')
		if own != timed {
			probes_for[s.key] = own
		}
	}
	if keys.filter(probes_for[it] or { timed }.len > 0).len == 0 {
		return error('no provider can run any of the requested probes')
	}

	plan := core.build_plan(
		provider_keys: keys
		probes: timed
		probes_for: probes_for
		domains: warm_domains
		rounds: opts.rounds
		seed: opts.seed
	)!

	execute(plan, mut subjects, opts, ca_bundle)!

	mut edge := map[string]core.EdgePenalty{}
	mut best_rtt := ?f64(none)
	if run_edge {
		samples := measure_edge(subjects, cat.cdn_hosts, opts)
		edge = core.edge_penalties(samples)
		// The scale the edge subscore is drawn against. Without it the penalties
		// are computed and then have nothing to be scored relative to, and the
		// column comes out null on every row.
		best_rtt = core.best_edge_rtt(samples)
	}

	duration := f64(time.since(started).microseconds()) / 1_000_000.0
	return assemble(subjects, edge, best_rtt, opts, net, cat, started, duration, warnings)
}

// timed_probes is the probe list the plan walks: everything but the edge probe.
//
// The edge probe cannot stand alone. A provider is excluded on `warm` before
// any subscore is read, so an edge-only run would emit a table of unreachable
// rows each carrying an edge penalty nobody would ever see.
fn timed_probes(probes []string) ![]string {
	out := probes.filter(it != 'ecs')
	if out.len == 0 {
		return error('--probes ecs needs a latency probe to rank against; add warm')
	}
	return out
}

// measure_edge resolves every CDN host through every provider and times a TCP
// connection to the address that came back.
//
// One pass, not rounds: the question is which edge a resolver chose, and asking
// it forty times measures the same choice forty times. The hosts are walked in
// the outer loop so that all providers are asked about a host at close to the
// same moment, which bounds how far an anycast target can drift underneath the
// comparison.
fn measure_edge(subjects []Subject, hosts []catalog.CdnHost, opts Options) map[string][]core.EdgeSample {
	mut out := map[string][]core.EdgeSample{}
	mut udp := map[string]&core.UdpTransport{}
	defer {
		for _, mut t in udp {
			t.close()
		}
	}

	for host in hosts {
		for s in subjects {
			out[s.key] << edge_sample(s, host, opts, mut udp)
		}
	}
	return out
}

// edge_sample is one provider's answer for one CDN host, and the connect that
// followed it.
fn edge_sample(s Subject, host catalog.CdnHost, opts Options, mut udp map[string]&core.UdpTransport) core.EdgeSample {
	requires := host.expect_cname_suffix != ''
	blank := core.EdgeSample{
		host: host.host
		requires_suffix: requires
	}

	if s.key !in udp {
		mut t := &core.UdpTransport{}
		t.open(core.Target{ ip: s.ip, timeout: opts.timeout }) or { return blank }
		udp[s.key] = t
	}
	mut t := udp[s.key] or { return blank }

	msg := core.build_query(host.host, core.qtype_a) or { return blank }
	reply, _ := t.query(msg) or { return blank }
	resp := core.parse_response(reply) or { return blank }

	chain := resp.cname_targets(reply) or { []string{} }
	suffix_ok := requires && chain.any(it.ends_with(host.expect_cname_suffix))

	addresses := resp.a_addresses()
	if addresses.len == 0 {
		// A provider that resolves fewer hosts is flagged, never favoured: the
		// host stays in its report with no answer and no penalty.
		return core.EdgeSample{
			host: host.host
			requires_suffix: requires
			suffix_ok: suffix_ok
		}
	}

	// The first address, because that is the one a client would have used.
	answer := addresses[0]
	connect_time := core.connect_ms('${answer}:443', core.edge_connect_timeout) or {
		return core.EdgeSample{
			host: host.host
			answer: answer
			requires_suffix: requires
			suffix_ok: suffix_ok
		}
	}
	return core.EdgeSample{
		host: host.host
		answer: answer
		connect_ms: connect_time
		requires_suffix: requires
		suffix_ok: suffix_ok
	}
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

// known_probes is the vocabulary of --probes, in the output contract's
// spelling. docs/METHODOLOGY.md § Probes.
const known_probes = ['warm', 'tcp', 'cold', 'ecs', 'dot_fresh', 'dot_warm']

// dot_probes are the ones that need a TLS connection and a trust anchor.
const dot_probes = ['dot_fresh', 'dot_warm']

// dot_port and dot_timeout are RFC 7858's port and the encrypted-probe budget
// of docs/METHODOLOGY.md § Timeouts, which is longer than the plaintext one
// because a handshake is two more round trips.
const dot_port = 853

const dot_timeout = 5 * time.second

const domain_set_id = 'builtin:top8'

fn select_subjects(cat catalog.Catalog, opts Options, net core.NetInfo, probes []string, mut warnings []store.Warning) ![]Subject {
	mut out := []Subject{}

	wants_dot := probes.any(it in dot_probes)
	plaintext := probes.filter(it !in dot_probes)

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
		dot_ip := p.dot_address()
		if p.udp4.len == 0 {
			// Encrypted-only entries are not failures and must not read as
			// absence either. Mullvad answers REFUSED on port 53 by design and
			// serves DoT from the same addresses, so it is measurable here
			// exactly when a DoT probe was asked for.
			if !wants_dot || dot_ip == '' {
				warnings << store.Warning{
					level: 'info'
					key: p.key
					message: '${p.key} skipped: no plaintext endpoint, add --probes dot-warm to measure it'
				}
				continue
			}
			out << Subject{
				key: p.key
				label: p.label
				ip: dot_ip
				dot_ip: dot_ip
				dot_host: p.dot
				probes: probes.filter(it in dot_probes)
				declared: p.declared()
			}
			continue
		}
		out << Subject{
			key: p.key
			label: p.label
			ip: p.udp4[0]
			dot_ip: dot_ip
			dot_host: p.dot
			// A provider with no DoT endpoint keeps the plaintext probes and
			// loses the encrypted ones, rather than scoring a total loss on a
			// transport it never offered.
			probes: if dot_ip == '' { plaintext } else { probes }
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
			// The machine's own resolvers are addresses, not catalog entries:
			// nothing says what hostname their certificate would carry, so
			// there is no DoT probe to run against them.
			probes: plaintext
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
fn execute(plan []core.Step, mut subjects []Subject, opts Options, ca_bundle string) ! {
	mut udp := map[string]&core.UdpTransport{}
	mut tcp := map[string]&core.TcpTransport{}
	// One TLS connection per provider, held for the run. That is the whole
	// point of dot_warm: the handshake is paid once, as every real client pays
	// it. dot_fresh opens its own and closes it again per query.
	mut dot := map[string]&core.DotTransport{}
	mut pacer := core.new_pacer(core.rate_interval)
	start := time.new_stopwatch()

	defer {
		for _, mut t in udp {
			t.close()
		}
		for _, mut t in tcp {
			t.close()
		}
		for _, mut t in dot {
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

		out := query_once(step, target, subjects[idx], opts, ca_bundle, mut udp, mut tcp, mut dot) or {
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

fn query_once(step core.Step, target core.Target, subject Subject, opts Options, ca_bundle string, mut udp map[string]&core.UdpTransport, mut tcp map[string]&core.TcpTransport, mut dot map[string]&core.DotTransport) !Outcome {
	msg := core.build_query(query_name(step, opts.cold_zone), core.qtype_a)!

	if step.probe in dot_probes {
		return dot_query(step, subject, ca_bundle, msg, mut dot)
	}

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

// dot_query runs one query over TLS, in whichever of the two shapes was asked
// for.
//
// dot_fresh times the whole thing: connect, handshake, query. That is not an
// implementation detail leaking into the number, it is the number. A benchmark
// that opens a connection per query is measuring handshakes, and this variant
// exists to show by how much.
//
// dot_warm times only the query, on a connection opened once and held, which is
// what Android Private DNS, systemd-resolved, unbound and dnscrypt-proxy all
// do. Only dot_warm feeds the score.
fn dot_query(step core.Step, subject Subject, ca_bundle string, msg []u8, mut dot map[string]&core.DotTransport) !Outcome {
	if subject.dot_ip == '' || subject.dot_host == '' {
		return error('no DoT endpoint for ${subject.key}')
	}
	target := core.Target{
		ip: subject.dot_ip
		port: dot_port
		timeout: dot_timeout
	}

	if step.probe == 'dot_fresh' {
		mut t := &core.DotTransport{
			hostname: subject.dot_host
			ca_bundle: ca_bundle
		}
		defer {
			t.close()
		}
		sw := time.new_stopwatch()
		t.open(target)!
		reply, _ := t.query(msg)!
		return Outcome{
			ms: f64(sw.elapsed().microseconds()) / 1000.0
			code: core.rcode(reply)
		}
	}

	if step.provider_key !in dot {
		mut t := &core.DotTransport{
			hostname: subject.dot_host
			ca_bundle: ca_bundle
		}
		t.open(target)!
		dot[step.provider_key] = t
	}
	mut t := dot[step.provider_key] or { return error('no dot transport') }
	if reply, ms := t.query(msg) {
		return Outcome{
			ms: ms
			code: core.rcode(reply)
		}
	}

	// The peer closed an idle connection, which a DoT server is free to do and
	// which this plan invites by holding one open across every other provider's
	// turn. Reconnect and ask again rather than recording a loss: the drop is an
	// artefact of how the tool schedules, not a fact about the resolver. The
	// retry is still a warm sample, because open() pays the handshake and
	// query() times only the query.
	t.close()
	dot.delete(step.provider_key)

	mut fresh := &core.DotTransport{
		hostname: subject.dot_host
		ca_bundle: ca_bundle
	}
	fresh.open(target)!
	dot[step.provider_key] = fresh

	reply, ms := fresh.query(msg)!
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

fn assemble(subjects []Subject, edge map[string]core.EdgePenalty, best_rtt ?f64, opts Options, net core.NetInfo, cat catalog.Catalog, started time.Time, duration f64, warnings []store.Warning) store.RunResult {
	weights := core.profiles[opts.profile] or { core.Weights{} }
	expected := core.expected_samples(opts.rounds, warm_domains.len)

	mut samples := []core.Samples{cap: subjects.len}
	for s in subjects {
		samples << core.Samples{
			base: core.Metrics{
				key: s.key
				is_cache: s.is_cache
				ecs_penalty_ms: median_penalty(edge, s.key)
				offers_dot: s.dot_ip != ''
				offers_ipv6: net.ipv6
				declared: s.declared
			}
			warm_ms: s.samples['warm'] or { []f64{} }
			cold_ms: s.samples['cold'] or { []f64{} }
			dot_warm_ms: s.samples['dot_warm'] or { []f64{} }
			// Per subject, not per run: a provider that could not run a probe
			// attempted nothing on it, and charging it the run's attempt count
			// would turn an absence into a hundred per cent loss.
			warm_expected: if 'warm' in s.probes { expected } else { 0 }
			cold_expected: if 'cold' in s.probes { expected } else { 0 }
			dot_warm_expected: if 'dot_warm' in s.probes { expected } else { 0 }
			warm_refused: s.refused['warm'] or { 0 }
			cold_refused: s.refused['cold'] or { 0 }
			dot_warm_refused: s.refused['dot_warm'] or { 0 }
		}
	}

	ranked := core.rank_providers(samples, best_rtt, weights, core.BootstrapSpec{ seed: opts.seed }) or {
		[]core.Ranked{}
	}
	bests := core.compute_bests(metrics_from(samples), best_rtt)

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

		mut reports := []store.ProbeReport{cap: subject.probes.len}
		for name in subject.probes {
			// The edge probe reports under `edge`, not under `probes`: it has an
			// answer and a connect time per host, not a latency distribution.
			if name == 'ecs' {
				continue
			}
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
			edge: edge_report(edge, subject.key)
			capabilities: store.Capabilities{
				// dnssec_validating stays absent until the probe that
				// establishes it lands in M2. Absent is not false.
				transports: transports_used(subject.probes)
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
		names := match probe {
			'tcp' { ['tcp'] }
			// The edge probe asks over UDP and then connects over TCP, and the
			// contract names transports rather than probes.
			'ecs' { ['udp', 'tcp'] }
			'dot_fresh', 'dot_warm' { ['dot'] }
			else { ['udp'] }
		}
		for name in names {
			if name !in out {
				out << name
			}
		}
	}
	return out
}

// median_penalty is the figure the `edge` subscore divides by, absent for a
// provider the edge probe did not reach.
fn median_penalty(edge map[string]core.EdgePenalty, key string) ?f64 {
	found := edge[key] or { return none }
	return found.median_penalty_ms
}

// edge_report renders one provider's per-host detail for the output.
fn edge_report(edge map[string]core.EdgePenalty, key string) store.Edge {
	found := edge[key] or { return store.Edge{} }

	mut hosts := []store.EdgeHost{cap: found.hosts.len}
	for h in found.hosts {
		hosts << store.EdgeHost{
			host: h.host
			answer: h.answer
			connect_ms: h.connect_ms
			penalty_ms: h.penalty_ms
			stale: h.stale
		}
	}
	return store.Edge{
		median_penalty_ms: found.median_penalty_ms
		misrouted: found.misrouted
		measured: found.measured
		hosts: hosts
	}
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
