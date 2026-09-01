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
// The version is `v.mod`'s, and the commit is whatever the build was cut from.
// Both are compile-time defines with a working default, so `v -o dnsbench cmd/`
// still builds; `make build` fills them in from the repository so that a result
// can be traced back to the code that produced it.
const tool_version = $d('version', '0.1.0')

const tool_commit = $d('commit', '')

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
	tui       bool
	no_color  bool
	palette   string = 'default'
	region    string
	no_geo    bool
	// catalog selects the provider source, on top of the embedded default and
	// any user override file. docs/DATA.md § Layer 2: 'dnscrypt' opts into the
	// cached DNSCrypt public-resolvers list; anything else is the default.
	catalog string
	require []string
	// near runs a reachability pre-pass and keeps only the fastest candidates,
	// per docs/DATA.md § Layer 2. Meant for --catalog dnscrypt, at hundreds of
	// candidates; harmless on the embedded catalog alone, which never exceeds
	// the keep count and so is never filtered.
	near bool
}

fn main() {
	// A DoT server is free to close an idle connection, and dot_warm holds one
	// open across the whole interleaved plan. Writing to a socket the peer has
	// closed then raises SIGPIPE, whose default action is to kill the process
	// mid-run with no output at all. The write returns an error instead, which
	// the transport already knows how to report.
	os.signal_ignore(.pipe)

	mut args := os.args[1..].clone()
	// One subcommand, and it is not a measurement: it fetches the optional
	// catalog and verifies it. Everything else is flags.
	updating := args.len > 0 && args[0] == 'update'
	if updating {
		args = args[1..].clone()
	}

	opts := parse_args(args) or {
		eprintln(err.msg())
		eprintln('')
		usage()
		exit(store.exit_usage)
	}

	if updating {
		update(opts) or {
			eprintln('dnsbench: ${err.msg()}')
			exit(store.exit_catalog_verification)
		}
		return
	}

	if opts.tui {
		// The TUI owns the terminal, the run and the exit code. It falls back to
		// this path itself when the terminal cannot host it.
		if reason := tui_unavailable() {
			eprintln('dnsbench: ${reason}, falling back to the plain table')
		} else {
			run_tui(opts)
			return
		}
	}

	mut watcher := Watcher(SilentWatcher{})
	result := run(opts, mut watcher) or {
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

// update fetches the DNSCrypt resolver list and verifies its signature.
//
// The transport is not trusted and does not need to be: the file is verified
// against a key that ships in this binary, so a mirror that lies is caught. What
// the transport does have to be is authenticated at all, which is why this goes
// through core.fetch and not through V's HTTP client. docs/V-NOTES.md § net.http
// does not validate certificates.
//
// A failure to verify is exit 4 and leaves whatever was cached before untouched.
// There is no flag to skip it.
fn update(opts Options) ! {
	net := core.detect()
	resolver := first_resolver(net)
	if resolver == '' {
		return error('no resolver configured, so nothing can be looked up')
	}
	ca_bundle := core.find_ca_bundle(opts.ca_bundle)!
	key := catalog.parse_minisign_key(catalog.dnscrypt_minisign_key)!

	mut failures := []string{}
	for source in catalog.dnscrypt_sources {
		body := core.fetch(url: source, resolver: resolver, ca_bundle: ca_bundle) or {
			failures << '${source}: ${err.msg()}'
			continue
		}
		raw := core.fetch(url: '${source}.minisig', resolver: resolver, ca_bundle: ca_bundle) or {
			failures << '${source}.minisig: ${err.msg()}'
			continue
		}

		signature := catalog.parse_minisign_signature(raw.bytestr())!
		// Not `continue`: a mirror that serves a file failing verification is a
		// different event from one that is unreachable, and trying the next
		// mirror after it would be shopping for a copy that passes.
		catalog.verify_minisign(body, signature, key)!

		directory := cache_directory()
		os.mkdir_all(directory)!
		path := os.join_path(directory, catalog.dnscrypt_cache_name)
		os.write_file(path, body.bytestr())!
		os.write_file('${path}.minisig', raw.bytestr())!

		println('verified ${body.len} octets from ${source}')
		println('  ${signature.trusted_comment}')
		println('cached at ${path}')
		return
	}
	return error('no source could be fetched:\n       ' + failures.join('\n       '))
}

// cache_directory follows the XDG base directory specification, because a tool
// that scatters files in a home directory is a tool people uninstall.
fn cache_directory() string {
	base := os.getenv('XDG_CACHE_HOME')
	if base != '' {
		return os.join_path(base, 'dnsbench')
	}
	return os.join_path(os.home_dir(), '.cache', 'dnsbench')
}

// load_catalog assembles the three provider layers of docs/DATA.md §
// Precedence. Layer 3, the user's own override file, is always consulted;
// Layer 2, the DNSCrypt list, only when `--catalog dnscrypt` asked for it,
// and never fatally: a missing or unreadable cache degrades to the embedded
// catalog with a warning rather than failing the run, matching how the rest
// of this tool treats an optional, previously-verified input going missing.
fn load_catalog(opts Options, mut warnings []store.Warning) !catalog.Catalog {
	embedded := catalog.embedded()!

	mut dnscrypt_providers := []catalog.Provider{}
	if opts.catalog == 'dnscrypt' {
		path := os.join_path(cache_directory(), catalog.dnscrypt_cache_name)
		text := os.read_file(path) or {
			warnings << store.Warning{
				level: 'warn'
				key: 'catalog'
				message: '--catalog dnscrypt: ${path} could not be read (${err.msg()}); run `dnsbench update` first. Falling back to the embedded catalog'
			}
			''
		}
		if text != '' {
			parsed := catalog.parse_resolvers_md(text)
			providers, unusable := catalog.providers_from_entries(parsed.entries)
			dnscrypt_providers = providers.clone()
			warnings << store.Warning{
				level: 'info'
				key: 'catalog'
				message: 'dnscrypt catalog: ${parsed.entries.len} resolvers listed, ${providers.len} usable as DoH providers, ${unusable.len} skipped (${summarize_dnscrypt_skips(unusable)})'
			}
			if parsed.skipped.len > 0 {
				warnings << store.Warning{
					level: 'warn'
					key: 'catalog'
					message: 'dnscrypt catalog: ${parsed.skipped.len} stamp(s) failed to decode and were ignored'
				}
			}
		}
	}

	user_providers := catalog.load_userconf(catalog.userconf_path()) or {
		warnings << store.Warning{
			level: 'warn'
			key: 'catalog'
			message: 'user provider file could not be loaded: ${err.msg()}'
		}
		[]catalog.Provider{}
	}

	merged := catalog.merge(embedded, dnscrypt_providers, user_providers)
	for note in merged.skipped {
		warnings << store.Warning{
			level: 'info'
			key: 'catalog'
			message: note
		}
	}

	mut providers := merged.catalog.providers.clone()
	if opts.require.len > 0 {
		required := opts.require
		providers = providers.filter(fn [required] (p catalog.Provider) bool {
			for tag in required {
				if tag !in p.tags {
					return false
				}
			}
			return true
		})
	}

	// --only is an explicit selection; pre-filtering candidates it did not ask
	// about would only risk dropping the one key the caller actually wants.
	if opts.near && opts.only.len == 0 {
		providers = near_filter(providers, catalog.near_default_keep, opts.timeout, mut warnings)
	}

	return catalog.Catalog{
		version: merged.catalog.version
		generated: merged.catalog.generated
		providers: providers
		cdn_hosts: merged.catalog.cdn_hosts
	}
}

// near_filter is the network-touching half of `--near`; catalog.near_rank is
// the pure half that decides who survives, and is what gets tested. A TCP
// connect, never a full query: docs/DATA.md § Layer 2 calls it "a fast
// reachability pass", and a connect is the cheapest thing this tool can time
// that still tells a live IP from a dead one.
//
// Paced like the real plan, docs/METHODOLOGY.md § Rate limit: this pass adds
// its own load to hundreds of resolvers before the run proper even starts,
// and a fast reachability check is not an excuse to hammer them.
fn near_filter(providers []catalog.Provider, keep int, timeout time.Duration, mut warnings []store.Warning) []catalog.Provider {
	mut candidates := []catalog.Provider{}
	for p in providers {
		if p.near_target() != '' {
			candidates << p
		}
	}
	// Nothing to trim: either the catalog is already small, or every candidate
	// worth ranking has no address a TCP connect can test.
	if candidates.len <= keep {
		return providers
	}

	mut pacer := core.new_pacer(core.rate_interval)
	start := time.new_stopwatch()
	mut measured := []catalog.NearMeasurement{}
	for p in candidates {
		now := start.elapsed().nanoseconds()
		send_at := pacer.reserve(p.key, now, core.jitter_factor())
		if send_at > now {
			time.sleep(send_at - now)
		}
		ms := core.connect_ms(p.near_target(), timeout) or { continue }
		measured << catalog.NearMeasurement{
			key: p.key
			ms: ms
		}
	}

	kept := catalog.near_rank(providers, measured, keep)
	warnings << store.Warning{
		level: 'info'
		key: 'catalog'
		message: '--near: ${candidates.len} candidates checked, ${measured.len} reachable, ${kept.len} kept'
	}
	return kept
}

// summarize_dnscrypt_skips turns the skip reasons providers_from_entries
// returns into three counts. Reported per-entry it would be hundreds of lines
// for a run that never asked to see them; docs/DATA.md never promised more
// than knowing how many were unusable and roughly why.
fn summarize_dnscrypt_skips(skipped []string) string {
	mut dnscrypt_protocol := 0
	mut no_address := 0
	mut other := 0
	for s in skipped {
		if s.contains('DNSCrypt-protocol stamp') {
			dnscrypt_protocol++
		} else if s.contains('stamp names no address') {
			no_address++
		} else {
			other++
		}
	}
	mut parts := []string{}
	if dnscrypt_protocol > 0 {
		parts << '${dnscrypt_protocol} DNSCrypt-protocol'
	}
	if no_address > 0 {
		parts << '${no_address} with no address'
	}
	if other > 0 {
		parts << '${other} other'
	}
	return parts.join(', ')
}

// version_line is what `--version` prints and what a bug report should carry.
// The commit is absent from a build that was not cut from a repository, which
// is a fact about that build rather than something to paper over.
fn version_line() string {
	if tool_commit == '' {
		return 'dnsbench ${tool_version}'
	}
	return 'dnsbench ${tool_version} (${tool_commit})'
}

fn usage() {
	eprintln('usage: dnsbench [options]')
	eprintln('       dnsbench update            fetch and verify the DNSCrypt catalog')
	eprintln('')
	eprintln('  --profile <name>   ${core.profiles.keys().join(', ')}  (default: balanced)')
	eprintln('  --only <keys>      comma-separated provider keys')
	eprintln('  --rounds <n>       measured rounds per provider (default: 5)')
	eprintln('  --probes <names>   warm, tcp, cold, ecs, dot-fresh, dot-warm, doh, dnssec, filter')
	eprintln('                     (default: warm)')
	eprintln('  --format <name>    table, json, csv, markdown  (default: table)')
	eprintln('  --history <path>   append the run to a JSONL history file')
	eprintln('  --timeout <ms>     per-query timeout (default: 2000)')
	eprintln('  --cold-zone <zone> wildcard zone for the cold probe')
	eprintln('  --catalog <name>   embedded, dnscrypt  (default: embedded)')
	eprintln('  --require <tags>   comma-separated tags every measured provider must carry')
	eprintln('  --ca-bundle <path> CA bundle for DoT, overriding the system cascade')
	eprintln('  --tui              watch the run in a full-screen terminal interface')
	eprintln('  --palette <name>   ${known_palettes.join(', ')}  (TUI only, default: default)')
	eprintln('  --no-color         plain text in the TUI, as NO_COLOR does')
	eprintln('  --region <code>    ${core.known_regions.join(', ')}  (default: detected)')
	eprintln('  --no-geo           do not look up the public address, ASN or region')
	eprintln('  --force            measure even with a tunnel interface up')
	eprintln('  --seed <n>         fix the shuffle, for a reproducible plan')
	eprintln('  -V, --version')
	eprintln('  -h, --help')
	eprintln('')
	eprintln('Exit: 0 ok, 1 measured with errors, 2 usage, 3 nothing reachable.')
}

// value_options are the flags that take an argument. standalone_options and the
// help flags stand alone.
const value_options = ['--profile', '--only', '--rounds', '--probes', '--format', '--history',
	'--timeout', '--cold-zone', '--ca-bundle', '--seed', '--palette', '--region', '--catalog',
	'--require']

const standalone_options = ['--force', '--tui', '--no-color', '--no-geo', '--near']

fn parse_args(args []string) !Options {
	mut o := Options{}
	mut i := 0

	for i < args.len {
		arg := args[i]
		if arg in ['-h', '--help'] {
			usage()
			exit(store.exit_usage)
		}
		if arg in ['-V', '--version'] {
			println(version_line())
			exit(store.exit_ok)
		}
		if arg in standalone_options {
			match arg {
				'--force' {
					o = Options{ ...o, force: true }
				}
				'--tui' {
					o = Options{ ...o, tui: true }
				}
				'--no-geo' {
					o = Options{ ...o, no_geo: true }
				}
				'--near' {
					o = Options{ ...o, near: true }
				}
				else {
					o = Options{ ...o, no_color: true }
				}
			}
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
			'--palette' {
				if value !in known_palettes {
					return error('unknown palette "${value}"; known: ${known_palettes.join(', ')}')
				}
				o = Options{ ...o, palette: value }
			}
			'--region' {
				if value !in core.known_regions {
					return error('unknown region "${value}"; known: ${core.known_regions.join(', ')}')
				}
				o = Options{ ...o, region: value }
			}
			'--seed' {
				n := u32(value.u64())
				o = Options{ ...o, seed: [n, n ^ u32(0x9e3779b9)] }
			}
			'--catalog' {
				if value !in ['embedded', 'dnscrypt'] {
					return error('unknown catalog "${value}"; known: embedded, dnscrypt')
				}
				o = Options{ ...o, catalog: value }
			}
			'--require' {
				tags := value.split(',').map(it.trim_space()).filter(it != '')
				for tag in tags {
					if tag !in catalog.tag_vocabulary {
						return error('unknown tag "${tag}" in --require; known: ${catalog.tag_vocabulary.keys().join(', ')}')
					}
				}
				o = Options{ ...o, require: tags }
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
	// The same for DoH, plus the request target.
	doh_ip   string
	doh_host string
	doh_path string
	// probes is what this subject can actually run. It is not always the run's
	// probe list: an encrypted-only provider has no plaintext probe.
	probes   []string
	is_cache bool
	declared []string
mut:
	samples map[string][]f64
	failed  map[string]int
	// attempts is how many counted queries were actually put to this subject per
	// probe, the warm-up excluded. It is the denominator of loss, and it is
	// counted rather than assumed so that a run watched while it happens shows
	// the loss it has seen so far instead of the loss of every query it has yet
	// to send.
	attempts map[string]int
	// doh_status is the first HTTP status a DoH endpoint answered with that was
	// not 200, kept so the report can say why rather than only that.
	doh_status int
	// Attempts the resolver answered with a non-NOERROR rcode, held apart from
	// `failed`: one is a resolver declining, the other is nothing coming back.
	refused map[string]int
}

fn run(opts Options, mut watcher Watcher) !store.RunResult {
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

	cat := load_catalog(opts, mut warnings)!

	// Before anything is measured, and never again. docs/ARCHITECTURE.md
	// § Region detection; `--no-geo` skips it and leaves the fields empty.
	origin := core.detect_origin(
		region: opts.region
		disabled: opts.no_geo
		resolver: first_resolver(net)
		timeout: opts.timeout
	)

	if origin.dns_interception {
		// docs/METHODOLOGY.md § Fairness rules: "a security finding, not a
		// measurement caveat." Reported prominently, not blocked: unlike a VPN,
		// which taints every sample the run is about to take, an interception
		// finding is a fact about the network worth surfacing, not a reason by
		// itself to refuse a measurement the user asked for.
		warnings << store.Warning{
			level: 'warn'
			key: 'network'
			message: 'transparent DNS interception detected: a direct query to 8.8.8.8 and a direct query to OpenDNS reported different egress addresses. Something between this machine and those resolvers may be redirecting DNS traffic'
		}
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

	// The trust anchor is resolved once, before anything is measured, so a
	// missing bundle is a startup error rather than sixteen identical handshake
	// failures. docs/ARCHITECTURE.md § TLS trust anchor.
	mut ca_bundle := ''
	if probes.any(it in encrypted_probes) {
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
		own := s.probes.filter(it != 'ecs' && it !in capability_probes)
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

	watcher.begin(RunContext{
		net: net
		origin: origin
		cat: cat
		started: started
		warnings: warnings
	})
	execute(plan, mut subjects, opts, ca_bundle, mut watcher)!

	mut capabilities := map[string]Capability{}
	if probes.any(it in capability_probes) {
		capabilities = measure_capabilities(subjects, probes, opts)
	}

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

	for s in subjects {
		if s.doh_status == 0 {
			continue
		}
		// Naming the status matters. 505 is not a broken endpoint, it is one
		// that serves DoH over HTTP/2 only, which V's stdlib cannot speak.
		suffix := if s.doh_status == 505 { ', it serves DoH over HTTP/2 only' } else { '' }
		warnings << store.Warning{
			level: 'warn'
			key: s.key
			message: '${s.key} doh: endpoint answered HTTP ${s.doh_status} to HTTP/1.1${suffix}'
		}
	}

	duration := f64(time.since(started).microseconds()) / 1_000_000.0
	result := assemble(subjects, edge, capabilities, best_rtt, opts, net, origin, cat, started, duration, warnings, core.BootstrapSpec{ seed: opts.seed })
	// The samples travel with the result so that a frontend can re-rank under a
	// different weighting without measuring anything again. docs/TUI.md § p.
	watcher.finish(result, build_samples(subjects, edge, capabilities, net.ipv6), best_rtt)
	return result
}

// timed_probes is the probe list the plan walks: everything but the edge probe.
//
// The edge probe cannot stand alone. A provider is excluded on `warm` before
// any subscore is read, so an edge-only run would emit a table of unreachable
// rows each carrying an edge penalty nobody would ever see.
fn timed_probes(probes []string) ![]string {
	out := probes.filter(it != 'ecs' && it !in capability_probes)
	if out.len == 0 {
		return error('--probes ecs, dnssec and filter need a latency probe to rank against; add warm')
	}
	return out
}

// Capability is what the two shape-reading probes established about one
// provider. Both fields are absent when the probe did not run or could not
// decide, which is not the same as a no.
struct Capability {
	dnssec_validating ?bool
	filters_ads       ?bool
}

// measure_capabilities asks each provider the two questions that have an answer
// rather than a duration.
//
// One pass, not rounds: whether a resolver validates does not vary between the
// third and the fortieth time it is asked, and asking forty times would be
// forty queries against a deliberately broken zone somebody else operates.
fn measure_capabilities(subjects []Subject, probes []string, opts Options) map[string]Capability {
	mut out := map[string]Capability{}
	mut udp := map[string]&core.UdpTransport{}
	defer {
		for _, mut t in udp {
			t.close()
		}
	}

	want_dnssec := 'dnssec' in probes
	want_filter := 'filter' in probes

	for s in subjects {
		mut validating := ?bool(none)
		mut filtering := ?bool(none)

		if want_dnssec {
			// Asked more than once, because at least one large anycast fleet
			// answers inconsistently and a single reading of it is a coin flip.
			// docs/METHODOLOGY.md § dnssec.
			mut yes := 0
			mut no := 0
			for _ in 0 .. dnssec_attempts {
				plain := ask_rcode(s, opts, dnssec_probe_name, false, mut udp) or { continue }
				with_cd := ask_rcode(s, opts, dnssec_probe_name, true, mut udp) or { continue }
				verdict := core.dnssec_verdict(plain, with_cd) or { continue }
				if verdict {
					yes++
				} else {
					no++
				}
			}
			validating = core.majority_verdict(yes, no)
		}
		if want_filter {
			if answer := ask_answer(s, opts, filter_probe_name, mut udp) {
				filtering = core.is_blocked(answer.code, answer.addresses)
			}
		}

		out[s.key] = Capability{
			dnssec_validating: validating
			filters_ads: filtering
		}
	}
	return out
}

struct Answer {
	code      u8
	addresses []string
}

// ask_answer puts one question to a provider and returns what came back.
fn ask_answer(s Subject, opts Options, name string, mut udp map[string]&core.UdpTransport) ?Answer {
	if s.ip == '' {
		return none
	}
	if s.key !in udp {
		mut t := &core.UdpTransport{}
		t.open(core.Target{ ip: s.ip, timeout: opts.timeout }) or { return none }
		udp[s.key] = t
	}
	mut t := udp[s.key] or { return none }

	msg := core.build_query(name, core.qtype_a) or { return none }
	reply, _ := t.query(msg) or { return none }
	resp := core.parse_response(reply) or {
		return Answer{
			code: core.rcode(reply)
		}
	}
	return Answer{
		code: core.rcode(reply)
		addresses: resp.a_addresses()
	}
}

// ask_rcode is ask_answer for the DNSSEC pair, where only the rcode matters and
// the CD bit has to be set on the control.
fn ask_rcode(s Subject, opts Options, name string, checking_disabled bool, mut udp map[string]&core.UdpTransport) ?u8 {
	if s.ip == '' {
		return none
	}
	if s.key !in udp {
		mut t := &core.UdpTransport{}
		t.open(core.Target{ ip: s.ip, timeout: opts.timeout }) or { return none }
		udp[s.key] = t
	}
	mut t := udp[s.key] or { return none }

	msg := core.build_query_opts(name, core.qtype_a, id: rand.u16(), cd: checking_disabled) or {
		return none
	}
	reply, _ := t.query(msg) or { return none }
	return core.rcode(reply)
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
const known_probes = ['warm', 'tcp', 'cold', 'ecs', 'dot_fresh', 'dot_warm', 'doh', 'dnssec', 'filter']

// encrypted_probes need a TLS connection and a trust anchor.
const dot_probes = ['dot_fresh', 'dot_warm']

const encrypted_probes = ['dot_fresh', 'dot_warm', 'doh']

// capability_probes ask one question each and read the answer's shape. They
// produce no latency distribution, so they never enter the plan.
const capability_probes = ['dnssec', 'filter']

// dnssec_probe_name is a zone signed with a deliberately broken signature, kept
// that way on purpose by its operator so that validation can be tested. Asked
// twice, once ordinarily and once with the CD bit. docs/DATA.md § Capability
// probe names.
const dnssec_probe_name = 'dnssec-failed.org'

// dnssec_attempts is how many times the pair is asked. Three, because a fleet
// that answers inconsistently needs a majority and two readings cannot produce
// one. docs/METHODOLOGY.md § dnssec.
const dnssec_attempts = 3

// filter_probe_name is an advertising domain that resolves normally on a
// resolver that does not filter and is substituted on one that does.
const filter_probe_name = 'doubleclick.net'

// dot_port and dot_timeout are RFC 7858's port and the encrypted-probe budget
// of docs/METHODOLOGY.md § Timeouts, which is longer than the plaintext one
// because a handshake is two more round trips.
const dot_port = 853

const doh_port = 443

const dot_timeout = 5 * time.second

const domain_set_id = 'builtin:top8'

// offered narrows a probe list to the encrypted probes a provider can answer.
//
// A DoT hostname without an address, or a DoH URL a provider does not publish,
// is not an endpoint. Handing it the probe anyway would record a hundred per
// cent loss on a transport it never offered.
fn offered(probes []string, dot_ip string, doh_ip string) []string {
	mut out := []string{}
	for probe in probes {
		if probe in dot_probes && dot_ip != '' {
			out << probe
		}
		if probe == 'doh' && doh_ip != '' {
			out << probe
		}
	}
	return out
}

fn select_subjects(cat catalog.Catalog, opts Options, net core.NetInfo, probes []string, mut warnings []store.Warning) ![]Subject {
	mut out := []Subject{}

	wants_encrypted := probes.any(it in encrypted_probes)
	plaintext := probes.filter(it !in encrypted_probes)

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
		doh_ip := p.doh_address()
		if p.udp4.len == 0 {
			// Encrypted-only entries are not failures and must not read as
			// absence either. Mullvad answers REFUSED on port 53 by design and
			// serves DoT from the same addresses, so it is measurable here
			// exactly when a DoT probe was asked for.
			if !wants_encrypted || (dot_ip == '' && doh_ip == '') {
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
				ip: if dot_ip != '' { dot_ip } else { doh_ip }
				dot_ip: dot_ip
				dot_host: p.dot
				doh_ip: doh_ip
				doh_host: p.doh_host()
				doh_path: p.doh_path()
				probes: offered(probes, dot_ip, doh_ip)
				declared: p.declared()
			}
			continue
		}
		// A provider keeps only the transports it actually offers, rather than
		// scoring a total loss on one it never had.
		mut own := plaintext.clone()
		own << offered(probes, dot_ip, doh_ip)

		out << Subject{
			key: p.key
			label: p.label
			ip: p.udp4[0]
			dot_ip: dot_ip
			dot_host: p.dot
			doh_ip: doh_ip
			doh_host: p.doh_host()
			doh_path: p.doh_path()
			probes: own
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

// Watcher is how a frontend follows a run that is still happening.
//
// The core knows nothing about frontends, and this does not change that: it is
// declared and implemented here, in the command layer, and the scheduler and
// the probes never see it. Returning false aborts the walk, which is what the
// TUI's `a` key does.
interface Watcher {
mut:
	begin(ctx RunContext)
	tick(step int, total int, subjects []Subject) bool
	finish(result store.RunResult, samples []core.Samples, best_rtt ?f64)
}

// RunContext is what a run knows about itself before it starts measuring:
// enough for a frontend to assemble a result out of partial samples without
// waiting for the run to end.
struct RunContext {
	net      core.NetInfo
	origin   core.Origin
	cat      catalog.Catalog
	started  time.Time
	warnings []store.Warning
}

// SilentWatcher is what the plain CLI passes. A run nobody is watching pays one
// call per step for it and nothing else.
struct SilentWatcher {}

fn (mut w SilentWatcher) begin(_ctx RunContext) {}

fn (mut w SilentWatcher) tick(_step int, _total int, _subjects []Subject) bool {
	return true
}

fn (mut w SilentWatcher) finish(_result store.RunResult, _samples []core.Samples, _best_rtt ?f64) {
}

// execute walks the plan and fills in the samples.
//
// A step that fails contributes to loss and nothing else; the run never stops
// for one bad provider, because the networks where that happens are exactly the
// ones worth measuring. docs/ARCHITECTURE.md § Failure policy.
fn execute(plan []core.Step, mut subjects []Subject, opts Options, ca_bundle string, mut watcher Watcher) ! {
	mut udp := map[string]&core.UdpTransport{}
	mut tcp := map[string]&core.TcpTransport{}
	// One TLS connection per provider, held for the run. That is the whole
	// point of dot_warm: the handshake is paid once, as every real client pays
	// it. dot_fresh opens its own and closes it again per query.
	mut dot := map[string]&core.DotTransport{}
	mut doh := map[string]&core.DohTransport{}
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
		for _, mut t in doh {
			t.close()
		}
	}

	for sent, step in plan {
		// The watcher sees every step, including the ones with no subject and the
		// discarded warm-up: a progress bar that skipped them would stall.
		if !watcher.tick(sent, plan.len, subjects) {
			return error(abort_message)
		}

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

		if !step.discard {
			// Counted at dispatch rather than on the way out, so that a partial run
			// divides its losses by what it sent and not by what it planned.
			subjects[idx].attempts[step.probe]++
		}

		out := query_once(step, target, subjects[idx], opts, ca_bundle, mut udp, mut tcp, mut dot, mut doh) or {
			if !step.discard {
				subjects[idx].failed[step.probe]++
			}
			continue
		}

		// Kept before the discard check, because the very first exchange is the
		// discarded one and an endpoint that refuses the HTTP version refuses
		// that one too. The reason would otherwise never reach the report.
		if out.http_status != 0 {
			subjects[idx].doh_status = out.http_status
		}

		// The warm-up query is sent like any other and its result thrown away:
		// it paid for cache fill, ARP and route setup that no later query pays.
		if step.discard {
			continue
		}
		if out.refused || out.code != core.rcode_noerror {
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
	// refused marks an answer that came back and carried no measurement, for a
	// reason the DNS rcode cannot express. A DoH endpoint that returns HTTP 505
	// answered; it just will not speak the version this client speaks.
	refused bool
	// http_status is the status behind that refusal, so the report can say why
	// and not only that. Zero for every probe that is not DoH.
	http_status int
}

fn query_once(step core.Step, target core.Target, subject Subject, opts Options, ca_bundle string, mut udp map[string]&core.UdpTransport, mut tcp map[string]&core.TcpTransport, mut dot map[string]&core.DotTransport, mut doh map[string]&core.DohTransport) !Outcome {
	msg := core.build_query(query_name(step, opts.cold_zone), core.qtype_a)!

	if step.probe in dot_probes {
		return dot_query(step, subject, ca_bundle, msg, mut dot)
	}
	if step.probe == 'doh' {
		return doh_query(step, subject, ca_bundle, msg, mut doh)
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

// doh_query runs one query over HTTPS.
//
// The connection is kept, because HTTP/1.1 keep-alive is how a stub resolver
// would use it and re-handshaking per query would measure the handshake. Unlike
// dot_warm there is no fresh variant: the handshake cost is already published by
// dot_fresh and would be the same two round trips here.
fn doh_query(step core.Step, subject Subject, ca_bundle string, msg []u8, mut doh map[string]&core.DohTransport) !Outcome {
	if subject.doh_ip == '' || subject.doh_host == '' {
		return error('no DoH endpoint for ${subject.key}')
	}
	target := core.Target{
		ip: subject.doh_ip
		port: doh_port
		timeout: dot_timeout
	}

	if step.provider_key !in doh {
		mut t := &core.DohTransport{
			hostname: subject.doh_host
			path: subject.doh_path
			ca_bundle: ca_bundle
		}
		t.open(target)!
		doh[step.provider_key] = t
	}
	mut t := doh[step.provider_key] or { return error('no doh transport') }

	if reply, ms := t.query(msg) {
		return Outcome{
			ms: ms
			code: core.rcode(reply)
		}
	} else {
		// An HTTP status is an answer, not a silence. Quad9's endpoint replies
		// 505 to every HTTP/1.1 request because it serves DoH over h2 only, and
		// V's stdlib has no h2 client; recording that as loss would blame the
		// network for a documented limitation of this tool.
		// Drop the connection either way. An endpoint that answered a status
		// this client cannot use is free to close afterwards, and reusing a
		// socket in that state turns one refusal into a run of read errors.
		t.close()
		doh.delete(step.provider_key)

		if status := core.http_status_of(err.msg()) {
			return Outcome{
				refused: true
				http_status: status
			}
		}
		return err
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

fn assemble(subjects []Subject, edge map[string]core.EdgePenalty, capabilities map[string]Capability, best_rtt ?f64, opts Options, net core.NetInfo, origin core.Origin, cat catalog.Catalog, started time.Time, duration f64, warnings []store.Warning, spec core.BootstrapSpec) store.RunResult {
	weights := core.profiles[opts.profile] or { core.Weights{} }

	samples := build_samples(subjects, edge, capabilities, net.ipv6)

	ranked := core.rank_providers(samples, best_rtt, weights, spec) or { []core.Ranked{} }
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
			if name == 'ecs' || name in capability_probes {
				continue
			}
			reports << store.ProbeReport{
				name: name
				stats: core.compute_counted(subject.samples[name] or { []f64{} }, subject.attempts[name] or { 0 }, subject.refused[name] or { 0 })
				// Recorded on every DoH result, because an HTTP/1.1 measurement
				// is not comparable with a browser's real h2 behaviour and a
				// reader has no way to know which one this was.
				http_version: if name == 'doh' { core.doh_http_version } else { '' }
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
				// Absent is not false: it says the probe did not run, or ran and
				// could not decide.
				dnssec_validating: capabilities[subject.key].dnssec_validating
				filtering: filtering_of(capabilities[subject.key])
				transports: transports_used(subject.probes)
				ipv6: net.ipv6
			}
			declared: subject.declared
		}
	}

	return store.RunResult{
		tool: store.Tool{
			version: tool_version
			commit: tool_commit
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
			asn: origin.asn
			asn_org: origin.asn_org
			ifname: net.ifname
			ipv6: net.ipv6
			region: origin.region
			region_source: origin.source
			vpn_detected: net.vpn_detected()
			dns_interception: origin.dns_interception
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

// build_samples is the bridge from what the run collected to what scoring
// reads. It is separate from assemble because a frontend re-ranking under a
// different weighting needs the samples and not the table.
fn build_samples(subjects []Subject, edge map[string]core.EdgePenalty, capabilities map[string]Capability, ipv6 bool) []core.Samples {
	mut samples := []core.Samples{cap: subjects.len}
	for s in subjects {
		samples << core.Samples{
			base: core.Metrics{
				key: s.key
				is_cache: s.is_cache
				attempted: attempted_of(s)
				ecs_penalty_ms: median_penalty(edge, s.key)
				// False when the probe said no and when it did not run. The
				// score cannot award points for an unknown, and the output
				// keeps the three states apart under capabilities.
				dnssec_validating: capabilities[s.key].dnssec_validating or { false }
				offers_dot: s.dot_ip != ''
				offers_ipv6: ipv6
				declared: s.declared
			}
			warm_ms: s.samples['warm'] or { []f64{} }
			cold_ms: s.samples['cold'] or { []f64{} }
			dot_warm_ms: s.samples['dot_warm'] or { []f64{} }
			// Per subject, not per run: a provider that could not run a probe
			// attempted nothing on it, and charging it the run's attempt count
			// would turn an absence into a hundred per cent loss.
			warm_expected: s.attempts['warm'] or { 0 }
			cold_expected: s.attempts['cold'] or { 0 }
			dot_warm_expected: s.attempts['dot_warm'] or { 0 }
			warm_refused: s.refused['warm'] or { 0 }
			cold_refused: s.refused['cold'] or { 0 }
			dot_warm_refused: s.refused['dot_warm'] or { 0 }
		}
	}
	return samples
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
			'doh' { ['doh'] }
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

// first_resolver is where the two ASN lookups are sent: the machine's own
// resolver, because they are ordinary public names and this is the resolver an
// ordinary lookup would use. Empty when the machine has none configured, which
// skips the lookup rather than picking a public resolver on the user's behalf.
fn first_resolver(net core.NetInfo) string {
	for r in net.resolvers {
		if r.ip != '' {
			return r.ip
		}
	}
	return ''
}

// attempted_of is every counted query the run has put to a subject, on any
// probe.
fn attempted_of(s Subject) int {
	mut total := 0
	for _, n in s.attempts {
		total += n
	}
	return total
}

// filtering_of renders the filter probe's verdict by category.
//
// Only `ads` is probed. There is no test name for the other categories that
// both resolves normally on a resolver that does not filter and is reliably
// blocked by one that does, and pinning a live malicious domain into a shipped
// catalog is not something a benchmark should do. An absent category says the
// question was not asked. docs/DATA.md § Capability probe names.
fn filtering_of(c Capability) map[string]bool {
	mut out := map[string]bool{}
	if blocked := c.filters_ads {
		out['ads'] = blocked
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
			attempted: s.base.attempted
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
