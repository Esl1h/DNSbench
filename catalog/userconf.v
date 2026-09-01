module catalog

import os

// Layer 3 of docs/DATA.md § Precedence: the user's own provider file, same
// schema as data/providers.toml, merged in by merge() with the highest
// precedence of the three layers.

// userconf_path is $XDG_CONFIG_HOME/dnsbench/providers.toml, falling back to
// ~/.config the way the rest of the base directory spec-following code in
// this project does.
pub fn userconf_path() string {
	base := os.getenv('XDG_CONFIG_HOME')
	dir := if base != '' { base } else { os.join_path(os.home_dir(), '.config') }
	return os.join_path(dir, 'dnsbench', 'providers.toml')
}

// load_userconf reads the user's override file, or returns no providers at
// all when the file is simply absent, which is the common case and not an
// error. A file that exists but fails to parse is: it goes through the same
// strict validation as the embedded catalog, so a typo is caught rather than
// silently producing a provider with a hole in it.
pub fn load_userconf(path string) ![]Provider {
	if !os.exists(path) {
		return []Provider{}
	}
	text := os.read_file(path)!
	cat := parse(text)!
	return cat.providers
}
