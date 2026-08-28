module catalog

// The curated catalog, compiled into the binary.
//
// docs/ARCHITECTURE.md § Design constraints: the tool is fully functional with
// no network beyond the resolvers under test. That rules out fetching this at
// run time, so it travels in the executable.
const embedded_toml = $embed_file('../data/providers.toml')

// embedded returns the compiled-in catalog. A failure here is a build-time
// mistake that reached run time: the data is fixed at compile time, so if it
// parses once it parses every time.
pub fn embedded() !Catalog {
	return parse(embedded_toml.to_string())!
}
