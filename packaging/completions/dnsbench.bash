# bash completion for dnsbench
#
# The vocabularies below are the ones `dnsbench --help` prints. They are
# repeated here rather than parsed at completion time because a completion that
# runs the binary on every Tab is a completion that hangs when the binary is
# mid-upgrade. `--only` is deliberately left free: it takes catalog keys, and
# nothing installed on the system lists them.

_dnsbench() {
	local cur prev
	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD-1]}

	case $prev in
		--profile)
			mapfile -t COMPREPLY < <(compgen -W "balanced speed privacy streaming gaming" -- "$cur")
			return
			;;
		--format)
			mapfile -t COMPREPLY < <(compgen -W "table json csv markdown" -- "$cur")
			return
			;;
		--palette)
			mapfile -t COMPREPLY < <(compgen -W "default colorblind" -- "$cur")
			return
			;;
		--region)
			mapfile -t COMPREPLY < <(compgen -W "global sa na eu apac af me" -- "$cur")
			return
			;;
		--probes)
			# Comma-separated: complete the name after the last comma and keep
			# what the user already typed in front of it.
			local head=${cur%,*}
			local tail=${cur##*,}
			local names="warm tcp cold ecs dot-fresh dot-warm doh dnssec filter"
			if [[ $cur == *,* ]]; then
				mapfile -t COMPREPLY < <(compgen -P "$head," -W "$names" -- "$tail")
			else
				mapfile -t COMPREPLY < <(compgen -W "$names" -- "$cur")
			fi
			return
			;;
		--history|--ca-bundle)
			mapfile -t COMPREPLY < <(compgen -f -- "$cur")
			return
			;;
		--only|--rounds|--timeout|--cold-zone|--seed)
			return
			;;
	esac

	mapfile -t COMPREPLY < <(compgen -W "--profile --only --rounds --probes --format \
		--history --timeout --cold-zone --ca-bundle --tui --palette --no-color \
		--region --no-geo --force --seed --version --help" -- "$cur")
}

complete -F _dnsbench dnsbench
