module catalog

// --near, docs/DATA.md § Layer 2: probing four hundred resolvers fully is slow
// and impolite, so a reachability pre-pass keeps a run to a fast subset.
//
// The address selection and the ranking live here, with no socket in sight,
// so both can be asserted directly. The reachability pass itself dials TCP
// connects and lives in cmd/, the only layer allowed to touch the network:
// docs/ARCHITECTURE.md § Design constraints.

// near_default_keep is how many providers survive `--near`, per docs/DATA.md
// § Layer 2: "keeps the fastest N (default 25)".
pub const near_default_keep = 25

// near_target is the address a reachability check dials for this provider:
// whichever endpoint it actually offers, DoH's own address over DoT's over a
// bare TCP connect to port 53. Empty means nothing here can be tested by a
// TCP connect at all, and the provider is kept unconditionally rather than
// excluded by a check that never ran.
pub fn (p Provider) near_target() string {
	doh := p.doh_address()
	if doh != '' {
		return '${doh}:443'
	}
	dot := p.dot_address()
	if dot != '' {
		return '${dot}:853'
	}
	if p.udp4.len > 0 {
		return '${p.udp4[0]}:53'
	}
	return ''
}

// NearMeasurement is one successful reachability check. A provider that was
// dialled and never answered simply has no entry here, which is what excludes
// it: unlike an untestable provider, it had its chance.
pub struct NearMeasurement {
pub:
	key string
	ms  f64
}

// near_rank keeps the fastest `keep` measured providers, in order, plus every
// provider `near_target` could not address at all. A provider that was
// testable but never answered is dropped: that is the filter doing its job,
// not a fact this function second-guesses.
pub fn near_rank(providers []Provider, measured []NearMeasurement, keep int) []Provider {
	mut by_key := map[string]Provider{}
	for p in providers {
		by_key[p.key] = p
	}

	mut kept := []Provider{}
	for p in providers {
		if p.near_target() == '' {
			kept << p
		}
	}

	mut sorted := measured.clone()
	sorted.sort(a.ms < b.ms)

	for i, m in sorted {
		if i >= keep {
			break
		}
		p := by_key[m.key] or { continue }
		kept << p
	}

	return kept
}
