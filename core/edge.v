module core

// The edge probe, and the arithmetic that turns its raw connect times into the
// `edge` subscore. docs/METHODOLOGY.md § ecs.
//
// EDNS Client Subnet lets a resolver pass a prefix of the client's network to
// the authoritative server, so a CDN can answer with a nearby edge. Without it
// the CDN sees only the resolver and guesses. That guess is not paid at lookup
// time, it is paid on every connection opened afterwards, which is why a
// resolver can win by 2 ms on `warm` and lose 90 ms per connection to the edge
// it chose.
//
// The probe is self-calibrating: the baseline for each host is the best connect
// time any provider in this run achieved for it. No geolocation, no IP
// database, no country code, and equally valid from São Paulo, Lagos or
// Helsinki.

// EdgeSample is one provider's outcome for one CDN host: the address it handed
// back and how long a TCP connection to that address took.
pub struct EdgeSample {
pub:
	host string
	// answer is the address that was connected to, absent when the provider
	// returned no address at all.
	answer ?string
	// connect_ms is the TCP connect time. Connect only, never a TLS handshake
	// or a request: the probe measures distance, not server behaviour.
	connect_ms ?f64
	// suffix_ok is whether this provider's CNAME chain still ended where the
	// catalog says it should. Only consulted when requires_suffix is true.
	suffix_ok bool
	// requires_suffix mirrors the catalog entry, so that this function needs
	// nothing but the samples to decide what is stale.
	requires_suffix bool
}

// EdgeHostPenalty is one host's line in one provider's edge report.
pub struct EdgeHostPenalty {
pub:
	host       string
	answer     ?string
	connect_ms ?f64
	// penalty_ms is this provider's connect time above the best any provider
	// achieved for this host. Absent when there is nothing to compare, which is
	// a provider that could not resolve the host or a host that went stale.
	penalty_ms ?f64
	stale      bool
}

// EdgePenalty is a provider's whole edge result.
pub struct EdgePenalty {

	// median_penalty_ms is the median across hosts, by nearest rank, matching
	// every other percentile the tool reports. Absent when no host produced a
	// penalty at all, which is not the same as a penalty of zero.
pub:
	median_penalty_ms ?f64
	hosts             []EdgeHostPenalty
}

// edge_penalties turns per-provider connect times into per-provider penalties.
//
// Two rules carry all the weight. The baseline for a host is the minimum
// connect time achieved by any provider in this run, so a provider that
// resolves fewer hosts is flagged rather than favoured by a shorter, easier
// set. And a stale host contributes to nobody: an entry whose CNAME chain no
// longer ends where the catalog says is measuring some other CDN, and a wrong
// number is worse than a visible gap.
pub fn edge_penalties(samples map[string][]EdgeSample) map[string]EdgePenalty {
	stale := stale_hosts(samples)
	best := best_connect(samples)

	mut out := map[string]EdgePenalty{}
	for key, provider_samples in samples {
		mut hosts := []EdgeHostPenalty{cap: provider_samples.len}
		mut penalties := []f64{cap: provider_samples.len}

		for s in provider_samples {
			is_stale := stale[s.host] or { false }
			mut penalty := ?f64(none)
			if !is_stale {
				if ms := s.connect_ms {
					if floor := best[s.host] {
						penalty = ms - floor
						penalties << ms - floor
					}
				}
			}
			hosts << EdgeHostPenalty{
				host: s.host
				answer: s.answer
				connect_ms: s.connect_ms
				penalty_ms: penalty
				stale: is_stale
			}
		}

		penalties.sort()
		out[key] = EdgePenalty{
			median_penalty_ms: percentile(penalties, 50)
			hosts: hosts
		}
	}
	return out
}

// stale_hosts marks the hosts that are no longer measuring what they were
// chosen to measure.
//
// The check is run-wide rather than per provider on purpose. One resolver
// answering oddly for a host is a fact about that resolver and is exactly the
// signal the probe exists to catch; the entry has only rotted when the expected
// chain is gone for everyone.
fn stale_hosts(samples map[string][]EdgeSample) map[string]bool {
	mut requires := map[string]bool{}
	mut met := map[string]bool{}

	for _, provider_samples in samples {
		for s in provider_samples {
			if s.requires_suffix {
				requires[s.host] = true
			}
			if s.suffix_ok {
				met[s.host] = true
			}
		}
	}

	mut out := map[string]bool{}
	for host, needed in requires {
		out[host] = needed && !(met[host] or { false })
	}
	return out
}

// best_connect is the per-host floor: the fastest connect any provider managed.
//
// Stale hosts are not filtered here, because the only caller reads this map
// inside a branch that has already excluded them. Filtering twice would be a
// guard no test could distinguish from its absence.
fn best_connect(samples map[string][]EdgeSample) map[string]f64 {
	mut out := map[string]f64{}
	for _, provider_samples in samples {
		for s in provider_samples {
			ms := s.connect_ms or { continue }
			if existing := out[s.host] {
				if ms < existing {
					out[s.host] = ms
				}
				continue
			}
			out[s.host] = ms
		}
	}
	return out
}

// best_edge_rtt is the shortest CDN connect any provider achieved in this run.
//
// It is the scale the `edge` subscore is drawn against, not a penalty: a 30 ms
// penalty means something different on a link whose best edge is 8 ms than on
// one whose best edge is 200 ms, and docs/SCORING.md defines the subscore as
// `100 * rtt / (rtt + penalty)` for exactly that reason. Stale hosts are left
// out, on the same terms as everywhere else.
pub fn best_edge_rtt(samples map[string][]EdgeSample) ?f64 {
	stale := stale_hosts(samples)

	mut best := ?f64(none)
	for _, provider_samples in samples {
		for s in provider_samples {
			if stale[s.host] or { false } {
				continue
			}
			ms := s.connect_ms or { continue }
			if current := best {
				if ms < current {
					best = ms
				}
				continue
			}
			best = ms
		}
	}
	return best
}
