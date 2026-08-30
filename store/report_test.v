module store

import core
import json2
import os

// The JSON is the contract. The table and the markdown are not, so what is
// asserted here is the JSON, the CSV, and the history line.
fn sample_run() RunResult {
	weights := core.profiles['balanced'] or { core.Weights{} }

	fast := ProviderResult{
		key: 'cloudflare'
		label: 'Cloudflare'
		ranked: core.Ranked{
			key: 'cloudflare'
			rank: 1
			tier: 1
			score: 91.7
			ci_low: 89.2
			ci_high: 93.4
		}
		subscores: core.Subscores{
			latency: 100.0
			recursion: 100.0
			stability: 100.0
			reliability: 100.0
			edge: 74.2
			encrypted: 100.0
			capability: 90.0
			privacy: 70.0
		}
		probes: [
			ProbeReport{
				name: 'warm'
				stats: core.compute([14.0, 14.2, 14.4, 15.0, 21.7], 5)
			},
			ProbeReport{
				name: 'doh'
				stats: core.compute([100.9, 101.2, 103.0, 110.0, 117.7], 5)
				http_version: '1.1'
			},
		]
		edge: Edge{
			median_penalty_ms: 3.9
			hosts: [
				EdgeHost{
					host: 'www.microsoft.com'
					answer: '23.55.0.0'
					connect_ms: 15.1
					penalty_ms: 3.9
					stale: false
				},
				EdgeHost{
					host: 'cdn.example.invalid'
					stale: true
				},
			]
		}
		capabilities: Capabilities{
			dnssec_validating: true
			filtering: {
				'ads':     false
				'malware': false
			}
			transports: ['udp', 'tcp', 'dot', 'doh']
			ipv6: true
		}
		declared: ['nolog', 'nofilter']
	}

	// A provider that answered nothing: every latency figure must be null, and
	// the row must still be present with its reason.
	dead := ProviderResult{
		key: 'dns4eu-protective'
		label: 'DNS4EU (protective)'
		ranked: core.Ranked{
			key: 'dns4eu-protective'
			excluded: core.Exclusion.unreachable
		}
		subscores: core.Subscores{
			reliability: 0.0
		}
		probes: [
			ProbeReport{
				name: 'warm'
				stats: core.compute([]f64{}, 40)
			},
		]
		declared: []
	}

	return RunResult{
		tool: Tool{
			version: '0.1.0'
			commit: 'a1b2c3d'
		}
		run: Run{
			started_at: '2026-08-28T09:14:02-03:00'
			duration_s: 47.3
			complete: true
			rounds: 5
			profile: 'balanced'
			weights: weights
		}
		network: Network{
			asn: 'AS64496'
			asn_org: 'EXAMPLE TELECOM'
			ifname: 'wlp3s0'
			ipv6: false
			region: 'sa'
			region_source: 'rir'
			vpn_detected: true
		}
		datasets: Datasets{
			catalog: CatalogInfo{
				version: 3
				providers: 16
			}
			domains: DomainInfo{
				warm: 'tranco:K2XVW'
				regional: 'sa'
				cold_mode: 'own'
			}
			cdn_hosts: CdnHostInfo{
				total: 4
				stale: 1
			}
		}
		results: [fast, dead]
		warnings: [
			Warning{
				level: 'warn'
				key: 'network'
				message: 'tunnel interfaces are up: tailscale0'
			},
		]
	}
}

// ── JSON ─────────────────────────────────────────────────────────────────────
fn test_the_json_carries_everything_the_contract_requires() ! {
	doc := json2.decode[json2.Any](sample_run().to_json())!.as_map()

	assert doc['schema_version'] or { json2.Any(0) }.int() == 1
	for key in ['tool', 'run', 'network', 'datasets', 'results'] {
		assert key in doc, 'missing ${key}'
	}

	run := doc['run'] or { json2.Any('') }.as_map()
	assert run['profile'] or { json2.Any('') }.str() == 'balanced'
	assert run['rounds'] or { json2.Any(0) }.int() == 5
	assert run['complete'] or { json2.Any(false) }.bool()

	// The active weights are printed with every result: nothing about the
	// ranking is hidden in the binary. docs/SCORING.md § Principles.
	weights := run['weights'] or { json2.Any('') }.as_map()
	assert weights.len == 8
	assert weights['edge'] or { json2.Any(0) }.f64() == 0.25
}

fn test_a_probe_with_no_samples_serialises_nulls_not_zeros() ! {
	// The reason the fields are nullable at all. A zero p50 beside 100 % loss
	// reads as the fastest resolver in the table.
	doc := json2.decode[json2.Any](sample_run().to_json())!.as_map()
	results := doc['results'] or { json2.Any('') }.arr()

	dead := results[1].as_map()
	assert dead['key'] or { json2.Any('') }.str() == 'dns4eu-protective'

	warm := (dead['probes'] or { json2.Any('') }.as_map()['warm'] or { json2.Any('') }).as_map()
	assert warm['n'] or { json2.Any(-1) }.int() == 0
	assert warm['expected'] or { json2.Any(-1) }.int() == 40
	assert warm['loss'] or { json2.Any(-1.0) }.f64() == 100.0

	for field in ['p50', 'p95', 'max', 'mean', 'jitter'] {
		value := warm[field] or {
			assert false, '${field} is missing entirely; the contract requires the key'
			return
		}
		assert value is json2.Null, '${field} is ${value}, expected null'
	}
}

fn test_an_excluded_provider_stays_in_the_output_with_its_reason() ! {
	// docs/ARCHITECTURE.md § Failure policy: keep it in the output, exclude it
	// from the ranking, show the reason. A silently absent row is a hole nobody
	// notices.
	doc := json2.decode[json2.Any](sample_run().to_json())!.as_map()
	dead := (doc['results'] or { json2.Any('') }.arr())[1].as_map()

	assert (dead['excluded'] or { json2.Any('') }).str() == 'unreachable'
	assert dead['rank'] or { json2.Any('') } is json2.Null
	assert dead['tier'] or { json2.Any('') } is json2.Null
	assert dead['score'] or { json2.Any('') } is json2.Null
}

fn test_measured_capabilities_and_declared_claims_stay_apart() ! {
	// CLAUDE.md § 5, as the output contract sees it. A consumer must be able to
	// tell what was probed from what was asserted, and merging them here would
	// remove that possibility for good.
	doc := json2.decode[json2.Any](sample_run().to_json())!.as_map()
	fast := (doc['results'] or { json2.Any('') }.arr())[0].as_map()

	caps := (fast['capabilities'] or { json2.Any('') }).as_map()
	assert caps['dnssec_validating'] or { json2.Any('') }.bool() == true
	assert caps['transports'] or { json2.Any('') }.arr().len == 4

	declared := (fast['declared'] or { json2.Any('') }).arr()
	assert declared.len == 2
	assert declared[0].str() == 'nolog'

	// Nothing declared appears among the capabilities, and vice versa.
	assert 'nolog' !in caps.keys()
	assert 'dnssec_validating' !in declared.map(it.str())
}

fn test_doh_results_are_labelled_with_their_http_version() ! {
	// An h1.1 measurement is not comparable with a browser's real h2 behaviour,
	// and docs/OUTPUT.md says the output must not hide that.
	doc := json2.decode[json2.Any](sample_run().to_json())!.as_map()
	fast := (doc['results'] or { json2.Any('') }.arr())[0].as_map()
	probes := (fast['probes'] or { json2.Any('') }).as_map()

	doh := (probes['doh'] or { json2.Any('') }).as_map()
	assert doh['http_version'] or { json2.Any('') }.str() == '1.1'

	// A probe that is not DoH carries no version at all.
	warm := (probes['warm'] or { json2.Any('') }).as_map()
	assert 'http_version' !in warm.keys()
}

fn test_a_stale_cdn_host_is_reported_rather_than_dropped() ! {
	// docs/DATA.md: better a visible gap than a silently wrong number.
	doc := json2.decode[json2.Any](sample_run().to_json())!.as_map()
	fast := (doc['results'] or { json2.Any('') }.arr())[0].as_map()
	hosts := ((fast['edge'] or { json2.Any('') }).as_map()['hosts'] or { json2.Any('') }).arr()

	assert hosts.len == 2
	stale := hosts[1].as_map()
	assert stale['stale'] or { json2.Any(false) }.bool()
	assert stale['answer'] or { json2.Any('') } is json2.Null
	assert stale['connect_ms'] or { json2.Any('') } is json2.Null
}

fn test_the_golden_file_matches_what_the_emitter_produces() ! {
	// The golden is validated against schema/result.schema.json by `make schema`
	// and by CI. A diff here is a deliberate change or a regression, and the
	// review decides which. docs/CONTRIBUTING.md § Tests.
	path := os.join_path(@VMODROOT, 'testdata', 'golden', 'run.json')
	produced := sample_run().to_json()

	if !os.exists(path) {
		os.write_file(path, produced)!
		assert false, 'golden written for the first time; re-run to compare'
	}

	expected := os.read_file(path)!
	assert produced == expected, 'output differs from testdata/golden/run.json'
}

// ── CSV ──────────────────────────────────────────────────────────────────────
fn test_the_csv_has_one_row_per_provider_and_probe() ! {
	rows := sample_run().to_csv().trim_space().split('\n')

	assert rows[0] == 'provider,probe,n,expected,refused,p50,p95,max,jitter,loss,edge_penalty,edge_misrouted,score'
	// two probes for cloudflare, one for the unreachable provider
	assert rows.len == 4
	assert rows[1].starts_with('cloudflare,warm,5,5,')
	assert rows[3].starts_with('dns4eu-protective,warm,0,40,')
}

fn test_the_csv_leaves_an_absent_figure_empty_rather_than_zero() ! {
	rows := sample_run().to_csv().trim_space().split('\n')
	dead := rows[3].split(',')

	// provider,probe,n,expected,refused,p50,p95,max,jitter,loss,edge_penalty,
	// edge_misrouted,score
	assert dead[4] == '0'
	assert dead[5] == ''
	assert dead[6] == ''
	assert dead[7] == ''
	assert dead[8] == ''
	assert dead[9] == '100.0'
	// No score: the provider is excluded from the ranking.
	assert dead[12] == ''
}

// ── history ──────────────────────────────────────────────────────────────────
fn test_every_history_line_carries_the_network_fingerprint() ! {
	// Without asn and ifname, history averages a fibre run with a mobile one.
	// docs/OUTPUT.md calls this mandatory, and it is mandatory because that
	// mistake actually happened.
	lines := sample_run().lines()

	assert lines.len == 3
	for l in lines {
		assert l.asn == 'AS64496'
		assert l.ifname == 'wlp3s0'
		assert l.cold_mode == 'own'
		assert l.domains == 'tranco:K2XVW'
		assert l.tool == '0.1.0'
	}
}

fn test_a_history_line_round_trips() ! {
	original := sample_run().lines()[0]
	restored := parse_line(original.encode())!

	assert restored.provider == original.provider
	assert restored.probe == original.probe
	assert restored.n == original.n
	assert restored.p50 or { -1.0 } == original.p50 or { -2.0 }
	assert restored.asn == original.asn
	assert restored.score or { -1.0 } == original.score or { -2.0 }
}

fn test_an_absent_figure_survives_the_round_trip_as_absent() ! {
	// It would be easy for a reader to turn a null back into 0.0 and quietly
	// resurrect the bug the nulls exist to prevent.
	dead := sample_run().lines()[2]
	restored := parse_line(dead.encode())!

	if v := restored.p50 {
		assert false, 'p50 came back as ${v}'
	}
	if v := restored.score {
		assert false, 'score came back as ${v}'
	}
	assert restored.loss == 100.0
	assert restored.n == 0
}

fn test_history_refuses_to_mix_incomparable_runs() ! {
	// docs/OUTPUT.md: history groups by network and refuses to aggregate across
	// cold_mode or incompatible domain sets.
	base := sample_run().lines()[0]

	assert comparable(base, base)

	assert !comparable(base, Line{ ...base, asn: 'AS64500' })
	assert !comparable(base, Line{ ...base, ifname: 'wwan0' })
	assert !comparable(base, Line{ ...base, cold_mode: 'wild' })
	assert !comparable(base, Line{ ...base, domains: 'tranco:OTHER' })
	assert !comparable(base, Line{ ...base, probe: 'cold' })

	// A different provider on the same network is still comparable: that is the
	// whole point of a run.
	assert comparable(base, Line{ ...base, provider: 'quad9' })
}

fn test_the_group_key_separates_networks_and_modes() ! {
	base := sample_run().lines()[0]

	assert base.group_key() == 'AS64496|wlp3s0|own|tranco:K2XVW|warm'
	assert Line{ ...base, cold_mode: 'wild' }.group_key() != base.group_key()
}

fn test_appending_history_creates_the_file_and_adds_to_it() ! {
	path := os.join_path(os.vtmp_dir(), 'dnsbench_history_test.jsonl')
	os.rm(path) or {}
	defer {
		os.rm(path) or {}
	}

	run := sample_run()
	append(path, run)!
	append(path, run)!

	body := os.read_file(path)!
	assert body.trim_space().split('\n').len == 6

	// Every line is independently readable, which is what makes the file
	// grep-able and recoverable if a run is interrupted mid-write.
	for text in body.trim_space().split('\n') {
		line := parse_line(text)!
		assert line.asn == 'AS64496'
	}
}

// ── exit codes ───────────────────────────────────────────────────────────────
fn test_a_clean_run_exits_zero() {
	one_good := RunResult{
		run: Run{
			complete: true
		}
		results: [
			ProviderResult{
				key: 'cloudflare'
			},
		]
	}

	assert exit_code(one_good) == exit_ok
}

fn test_a_run_with_an_unreachable_provider_reports_a_measurement_error() {
	// The sample run has one working provider and one that answered nothing.
	// There are numbers to look at, so this is 1 and not 3.
	assert exit_code(sample_run()) == exit_measurement_error
}

fn test_nothing_reachable_is_a_connectivity_problem_not_a_measurement_one() {
	// docs/OUTPUT.md: 3 means likely no connectivity. A monitoring job seeing 3
	// has nothing to look at and should not page anyone about DNS latency.
	all_dead := RunResult{
		run: Run{
			complete: true
		}
		results: [
			ProviderResult{
				key: 'a'
				ranked: core.Ranked{
					excluded: core.Exclusion.unreachable
				}
			},
			ProviderResult{
				key: 'b'
				ranked: core.Ranked{
					excluded: core.Exclusion.unreachable
				}
			},
		]
	}

	assert exit_code(all_dead) == exit_no_provider_reachable
	assert exit_code(RunResult{}) == exit_no_provider_reachable
}

fn test_an_interrupted_run_exits_one_with_its_partial_results() {
	// SIGINT flushes what it has with complete: false and exits 1.
	// docs/ARCHITECTURE.md § Failure policy.
	interrupted := RunResult{
		run: Run{
			complete: false
		}
		results: [
			ProviderResult{
				key: 'cloudflare'
			},
		]
	}

	assert exit_code(interrupted) == exit_measurement_error
}

fn test_a_cache_or_a_low_n_row_does_not_make_the_run_an_error() {
	// Neither is a failure. A local cache is excluded by design, and a thin
	// sample is a caveat on one row rather than a problem with the run.
	fine := RunResult{
		run: Run{
			complete: true
		}
		results: [
			ProviderResult{
				key: 'system-stub'
				ranked: core.Ranked{
					excluded: core.Exclusion.cache
				}
			},
			ProviderResult{
				key: 'thin'
				ranked: core.Ranked{
					excluded: core.Exclusion.low_n
				}
			},
		]
	}

	assert exit_code(fine) == exit_ok
}

fn test_a_refusing_provider_is_reachable_but_still_an_error() {
	// Mullvad's plaintext addresses answer REFUSED to every name by design.
	// Calling that unreachable blames the network for a decision the operator
	// made, and would send the run to exit 3, which tells a monitoring job it
	// has no connectivity. It has connectivity; it has no measurement.
	refusing := RunResult{
		run: Run{
			complete: true
		}
		results: [
			ProviderResult{
				key: 'mullvad'
				ranked: core.Ranked{
					excluded: core.Exclusion.refused
				}
				probes: [
					ProbeReport{
						name: 'warm'
						stats: core.compute_counted([]f64{}, 40, 40)
					},
				]
			},
		]
	}

	assert exit_code(refusing) == exit_measurement_error

	row := refusing.to_csv().trim_space().split('\n')[1].split(',')
	// provider,probe,n,expected,refused,p50,...,loss
	assert row[2] == '0'
	assert row[4] == '40'
	assert row[9] == '0.0'
}
