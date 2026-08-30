# fish completion for dnsbench
#
# The vocabularies are the ones `dnsbench --help` prints, repeated here rather
# than parsed at completion time. `--only` takes catalog keys and is left free,
# because nothing installed on the system lists them.

complete -c dnsbench -f

complete -c dnsbench -l profile -r -d 'weight profile for the composite score' \
	-a 'balanced speed privacy streaming gaming'
complete -c dnsbench -l only -r -d 'measure only these catalog keys'
complete -c dnsbench -l rounds -r -d 'measured rounds per provider'
complete -c dnsbench -l probes -r -d 'which probes to run' \
	-a 'warm tcp cold ecs dot-fresh dot-warm doh dnssec filter'
complete -c dnsbench -l format -r -d 'output format' -a 'table json csv markdown'
complete -c dnsbench -l history -r -F -d 'append the run to a JSONL history file'
complete -c dnsbench -l timeout -r -d 'per-query timeout in milliseconds'
complete -c dnsbench -l cold-zone -r -d 'wildcard zone the cold probe asks under'
complete -c dnsbench -l ca-bundle -r -F -d 'CA bundle for DoT and DoH'
complete -c dnsbench -l tui -d 'watch the run in a full-screen interface'
complete -c dnsbench -l palette -r -d 'TUI colour palette' -a 'default colorblind'
complete -c dnsbench -l no-color -d 'plain text in the TUI'
complete -c dnsbench -l region -r -d 'region, normally detected' \
	-a 'global sa na eu apac af me'
complete -c dnsbench -l no-geo -d 'do not look up the public address, ASN or region'
complete -c dnsbench -l force -d 'measure even with a tunnel interface up'
complete -c dnsbench -l seed -r -d 'fix the shuffle, for a reproducible plan'
complete -c dnsbench -s V -l version -d 'print the version and the commit'
complete -c dnsbench -s h -l help -d 'print the flag list'
