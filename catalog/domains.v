module catalog

// The warm domain set: Tranco, pinned, generated once at release time and
// embedded rather than fetched. docs/DATA.md § Tranco, pinned; the same
// no-network-beyond-the-resolvers-under-test constraint embedded.v documents
// for the provider catalog applies here.
const embedded_global_domains = $embed_file('../data/domains/global.txt')

// The six regional sets docs/DATA.md § Domain sets names, each a Tranco ccTLD
// filter against the same countries core.known_regions and core/geo.v's
// country buckets use, taken in Tranco rank order with no manual curation:
// see docs/PLAN.md § the regional domain sets for why the "+ manual
// curation" half of that section was not attempted.
const embedded_sa_domains = $embed_file('../data/domains/sa.txt')

const embedded_na_domains = $embed_file('../data/domains/na.txt')

const embedded_eu_domains = $embed_file('../data/domains/eu.txt')

const embedded_me_domains = $embed_file('../data/domains/me.txt')

const embedded_af_domains = $embed_file('../data/domains/af.txt')

const embedded_apac_domains = $embed_file('../data/domains/apac.txt')

// DomainSet is a pinned domain list plus the citable id every result using it
// carries in its `domains` field. docs/OUTPUT.md.
pub struct DomainSet {
pub:
	id      string
	domains []string
}

// global_domains returns the compiled-in Tranco global domain set: top 25,
// unfiltered, per docs/DATA.md § Domain sets.
pub fn global_domains() !DomainSet {
	return parse_domain_set(embedded_global_domains.to_string())!
}

// regional_domains returns the compiled-in Tranco set for one of the six
// named regions. docs/DATA.md § Regional sets says a regional run is always
// `global + regional`, never regional alone, so an unrecognised region,
// `global` included, is an error for the caller to fall back on rather than
// a silent empty set.
pub fn regional_domains(region string) !DomainSet {
	text := match region {
		'sa' { embedded_sa_domains.to_string() }
		'na' { embedded_na_domains.to_string() }
		'eu' { embedded_eu_domains.to_string() }
		'me' { embedded_me_domains.to_string() }
		'af' { embedded_af_domains.to_string() }
		'apac' { embedded_apac_domains.to_string() }
		else {
			return error('no regional domain set for "${region}"')
		}
	}
	return parse_domain_set(text)!
}

// parse_domain_set reads a file in the form docs/DATA.md § Tranco, pinned
// shows: a `# tranco:<id> ...` header line naming the snapshot, then one
// domain per line. The id is the first whitespace-separated token after the
// `#`, so the retrieval date and description that follow it are free text.
pub fn parse_domain_set(text string) !DomainSet {
	mut id := ''
	mut domains := []string{}
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if line == '' {
			continue
		}
		if line.starts_with('#') {
			if id == '' {
				fields := line[1..].trim_space().split(' ').filter(it != '')
				if fields.len > 0 && fields[0].starts_with('tranco:') {
					id = fields[0]
				}
			}
			continue
		}
		domains << line
	}
	if id == '' {
		return error('domain set carries no "# tranco:<id>" header')
	}
	if domains.len == 0 {
		return error('domain set is empty')
	}
	return DomainSet{
		id: id
		domains: domains
	}
}
