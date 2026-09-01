module catalog

// merge combines the three provider layers of docs/DATA.md § Precedence into
// one catalog, applied in this order:
//
//   1. embedded  — Layer 1, curated and hand-verified
//   2. dnscrypt  — Layer 2, opt-in, cached from the public-resolvers list
//   3. user      — Layer 3, ~/.config/dnsbench/providers.toml
//
// A key already present is never silently replaced by dnscrypt: Layer 1's
// curation, its notes and its verified udp4/dot endpoints, is worth more than
// an uncurated entry sharing the same key, and docs/DATA.md's own inclusion
// criteria exist precisely to make that curation meaningful. A colliding
// dnscrypt entry is skipped and reported rather than merged field by field,
// since "which fields win" has no answer the docs commit to.
//
// A user entry, by contrast, is named an override in docs/DATA.md and replaces
// whatever shares its key, embedded included: it is the one layer meant to
// let an operator's own judgement stand in for the shipped catalog.
pub struct MergeResult {
pub:
	catalog Catalog
	// skipped names every dnscrypt-catalog entry dropped for colliding with an
	// existing key, so a run can report why it saw fewer than the cache holds.
	skipped []string
}

// merge applies the three-layer precedence described above.
pub fn merge(embedded Catalog, dnscrypt []Provider, user []Provider) MergeResult {
	mut by_key := map[string]Provider{}
	mut order := []string{}

	for p in embedded.providers {
		by_key[p.key] = p
		order << p.key
	}

	mut skipped := []string{}
	for p in dnscrypt {
		if p.key in by_key {
			skipped << '${p.key}: already curated in the embedded catalog, DNSCrypt-list entry skipped'
			continue
		}
		by_key[p.key] = p
		order << p.key
	}

	for p in user {
		if p.key !in by_key {
			order << p.key
		}
		by_key[p.key] = p
	}

	mut providers := []Provider{}
	for key in order {
		providers << by_key[key]
	}

	return MergeResult{
		catalog: Catalog{
			version: embedded.version
			generated: embedded.generated
			providers: providers
			cdn_hosts: embedded.cdn_hosts
		}
		skipped: skipped
	}
}
