# bash completion for dnsbench
#
# The vocabularies below are the ones `dnsbench --help` prints. They are
# repeated here rather than parsed at completion time because a completion that
# runs the binary on every Tab is a completion that hangs when the binary is
# mid-upgrade. `--only`, `--provider` and `--asn` are deliberately left free:
# they take catalog keys or network identifiers, and nothing installed on the
# system lists them.

_dnsbench_history() {
	local cur prev
	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD-1]}

	case $prev in
		--file)
			mapfile -t COMPREPLY < <(compgen -f -- "$cur")
			return
			;;
		--last|--asn|--provider)
			return
			;;
	esac

	mapfile -t COMPREPLY < <(compgen -W "--last --asn --provider --plot --file" -- "$cur")
}

_dnsbench() {
	local cur prev
	cur=${COMP_WORDS[COMP_CWORD]}
	prev=${COMP_WORDS[COMP_CWORD-1]}

	# `history` is a subcommand, not a flag, and only ever the first word.
	if [[ ${COMP_WORDS[1]} == history && $COMP_CWORD -ge 1 ]]; then
		_dnsbench_history
		return
	fi
	if [[ $COMP_CWORD -eq 1 ]]; then
		mapfile -t COMPREPLY < <(compgen -W "update history --profile --only --rounds \
			--probes --format --history --timeout --cold-zone --ca-bundle --catalog \
			--require --near --tui --palette --no-color --region --no-geo --force \
			--seed --watch --watch-count --alert-edge --version --help" -- "$cur")
		return
	fi

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
		--catalog)
			mapfile -t COMPREPLY < <(compgen -W "embedded dnscrypt" -- "$cur")
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
		--only|--rounds|--timeout|--cold-zone|--seed|--require|--watch|--watch-count|--alert-edge)
			return
			;;
	esac

	mapfile -t COMPREPLY < <(compgen -W "--profile --only --rounds --probes --format \
		--history --timeout --cold-zone --ca-bundle --catalog --require --near --tui \
		--palette --no-color --region --no-geo --force --seed --watch --watch-count \
		--alert-edge --version --help" -- "$cur")
}

complete -F _dnsbench dnsbench
