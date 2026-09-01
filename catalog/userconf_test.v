module catalog

import os

fn test_userconf_path_follows_xdg_config_home() {
	old := os.getenv('XDG_CONFIG_HOME')
	os.setenv('XDG_CONFIG_HOME', '/tmp/xdgtest', true)
	defer {
		if old == '' {
			os.unsetenv('XDG_CONFIG_HOME')
		} else {
			os.setenv('XDG_CONFIG_HOME', old, true)
		}
	}
	assert userconf_path() == '/tmp/xdgtest/dnsbench/providers.toml'
}

fn test_load_userconf_of_a_missing_file_is_empty_not_an_error() ! {
	providers := load_userconf('/nonexistent/dnsbench/providers.toml')!
	assert providers.len == 0
}

fn test_load_userconf_parses_a_real_file() ! {
	dir := os.join_path(os.temp_dir(), 'dnsbench_userconf_test')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'providers.toml')
	os.write_file(path, '
version = 1
generated = "2026-09-01"

[[provider]]
key      = "homelab"
label    = "Homelab"
udp4     = ["192.0.2.53"]
homepage = "https://internal.example"
')!

	providers := load_userconf(path)!
	assert providers.len == 1
	assert providers[0].key == 'homelab'
}

fn test_load_userconf_of_an_invalid_file_is_an_error() ! {
	dir := os.join_path(os.temp_dir(), 'dnsbench_userconf_test_bad')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'providers.toml')
	os.write_file(path, '[[provider]]\nkey = "no-label"\n')!

	if _ := load_userconf(path) {
		assert false, 'expected an error'
	} else {
		assert err.msg().contains('label')
	}
}
