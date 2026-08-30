#compdef dnsbench
# zsh completion for dnsbench
#
# The vocabularies are the ones `dnsbench --help` prints, repeated here rather
# than parsed at completion time. `--only` takes catalog keys and is left free,
# because nothing installed on the system lists them.

_dnsbench() {
	local -a probes
	probes=(
		'warm:repeated lookups of a fixed domain set'
		'tcp:the same question over TCP'
		'cold:an uncached name, so the resolver has to recurse'
		'ecs:CDN edge quality, the reason the tool exists'
		'dot-fresh:DNS over TLS, handshake included in every sample'
		'dot-warm:DNS over TLS on a held connection, and what the score uses'
		'doh:DNS over HTTPS, HTTP/1.1'
		'dnssec:whether the resolver validates'
		'filter:whether the resolver blocks an advertising domain'
	)

	_arguments -s \
		'--profile[weight profile for the composite score]:profile:(balanced speed privacy streaming gaming)' \
		'--only[measure only these catalog keys]:keys:' \
		'--rounds[measured rounds per provider]:count:' \
		'--probes[which probes to run]:probes:_values -s , probe $probes' \
		'--format[output format]:format:(table json csv markdown)' \
		'--history[append the run to a JSONL history file]:path:_files' \
		'--timeout[per-query timeout in milliseconds]:ms:' \
		'--cold-zone[wildcard zone the cold probe asks under]:zone:' \
		'--ca-bundle[CA bundle for DoT and DoH]:path:_files' \
		'--tui[watch the run in a full-screen interface]' \
		'--palette[TUI colour palette]:palette:(default colorblind)' \
		'--no-color[plain text in the TUI]' \
		'--region[region, normally detected]:region:(global sa na eu apac af me)' \
		'--no-geo[do not look up the public address, ASN or region]' \
		'--force[measure even with a tunnel interface up]' \
		'--seed[fix the shuffle, for a reproducible plan]:seed:' \
		'(-V --version)'{-V,--version}'[print the version and the commit]' \
		'(-h --help)'{-h,--help}'[print the flag list]'
}

_dnsbench "$@"
