# fish completion for dnsbench
#
# The vocabularies are the ones `dnsbench --help` prints, repeated here rather
# than parsed at completion time. `--only`, `--provider` and `--asn` take
# catalog keys or network identifiers and are left free, because nothing
# installed on the system lists them.

complete -c dnsbench -f

# The two subcommands, offered only in first position.
complete -c dnsbench -n __fish_use_subcommand -a update -d 'fetch and verify the DNSCrypt catalog'
complete -c dnsbench -n __fish_use_subcommand -a history -d 'read a JSONL history file back'

set -l main_run 'not __fish_seen_subcommand_from update history'

complete -c dnsbench -n "$main_run" -l profile -r -d 'weight profile for the composite score' \
	-a 'balanced speed privacy streaming gaming'
complete -c dnsbench -n "$main_run" -l only -r -d 'measure only these catalog keys'
complete -c dnsbench -n "$main_run" -l catalog -r -d 'provider source' -a 'embedded dnscrypt'
complete -c dnsbench -n "$main_run" -l require -r -d 'tags every measured provider must carry'
complete -c dnsbench -n "$main_run" -l near -d 'reachability pre-pass for --catalog dnscrypt'
complete -c dnsbench -n "$main_run" -l rounds -r -d 'measured rounds per provider'
complete -c dnsbench -n "$main_run" -l probes -r -d 'which probes to run' \
	-a 'warm tcp cold ecs dot-fresh dot-warm doh dnssec filter'
complete -c dnsbench -n "$main_run" -l format -r -d 'output format' -a 'table json csv markdown'
complete -c dnsbench -n "$main_run" -l history -r -F -d 'append the run to a JSONL history file'
complete -c dnsbench -n "$main_run" -l timeout -r -d 'per-query timeout in milliseconds'
complete -c dnsbench -n "$main_run" -l cold-zone -r -d 'wildcard zone the cold probe asks under'
complete -c dnsbench -n "$main_run" -l ca-bundle -r -F -d 'CA bundle for DoT and DoH'
complete -c dnsbench -n "$main_run" -l tui -d 'watch the run in a full-screen interface'
complete -c dnsbench -n "$main_run" -l palette -r -d 'TUI colour palette' -a 'default colorblind'
complete -c dnsbench -n "$main_run" -l no-color -d 'plain text in the TUI'
complete -c dnsbench -n "$main_run" -l region -r -d 'region, normally detected' \
	-a 'global sa na eu apac af me'
complete -c dnsbench -n "$main_run" -l no-geo -d 'do not look up the public address, ASN or region'
complete -c dnsbench -n "$main_run" -l force -d 'measure even with a tunnel interface up'
complete -c dnsbench -n "$main_run" -l seed -r -d 'fix the shuffle, for a reproducible plan'
complete -c dnsbench -n "$main_run" -l watch -r -d 'repeat the run at a fixed interval'
complete -c dnsbench -n "$main_run" -l watch-count -r -d 'stop after n measurements'
complete -c dnsbench -n "$main_run" -l alert-edge -r -d 'alert past this edge penalty, in ms'
complete -c dnsbench -n "$main_run" -s V -l version -d 'print the version and the commit'
complete -c dnsbench -n "$main_run" -s h -l help -d 'print the flag list'

set -l in_history '__fish_seen_subcommand_from history'

complete -c dnsbench -n "$in_history" -l last -r -d 'only runs within this window'
complete -c dnsbench -n "$in_history" -l asn -r -d 'only this network'
complete -c dnsbench -n "$in_history" -l provider -r -d 'only this provider'
complete -c dnsbench -n "$in_history" -l plot -d 'sparkline of p50 over time, needs --provider'
complete -c dnsbench -n "$in_history" -l file -r -F -d 'history file to read'
