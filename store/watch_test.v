module store

import core

fn winner(key string) ProviderResult {
	return ProviderResult{
		key: key
		ranked: core.Ranked{
			key: key
			rank: 1
		}
	}
}

fn runner_up(key string, rank int) ProviderResult {
	return ProviderResult{
		key: key
		ranked: core.Ranked{
			key: key
			rank: rank
		}
	}
}

fn excluded_provider(key string) ProviderResult {
	return ProviderResult{
		key: key
		ranked: core.Ranked{
			key: key
			excluded: core.Exclusion.unreachable
		}
	}
}

fn test_no_alert_when_the_winner_holds() {
	previous := RunResult{
		results: [winner('quad9'), runner_up('cloudflare', 2)]
	}
	current := RunResult{
		results: [winner('quad9'), runner_up('cloudflare', 2)]
	}
	assert watch_alerts(previous, current, none).len == 0
}

fn test_an_alert_when_the_winner_changes() {
	previous := RunResult{
		results: [winner('quad9'), runner_up('cloudflare', 2)]
	}
	current := RunResult{
		results: [winner('cloudflare'), runner_up('quad9', 2)]
	}
	alerts := watch_alerts(previous, current, none)
	assert alerts.len == 1
	assert alerts[0].contains('quad9 to cloudflare')
}

// A run where everything is excluded has no winner to compare, and that
// absence is not itself a "change" worth alerting on.
fn test_no_winner_on_either_side_is_not_a_change() {
	previous := RunResult{
		results: [excluded_provider('quad9')]
	}
	current := RunResult{
		results: [excluded_provider('quad9')]
	}
	assert watch_alerts(previous, current, none).len == 0
}

fn test_edge_threshold_is_ignored_when_not_asked_for() {
	current := RunResult{
		results: [
			ProviderResult{
				key: 'quad9'
				ranked: core.Ranked{ key: 'quad9', rank: 1 }
				edge: Edge{ median_penalty_ms: 999.0 }
			},
		]
	}
	assert watch_alerts(current, current, none).len == 0
}

fn test_edge_threshold_alerts_only_past_the_line() {
	current := RunResult{
		results: [
			ProviderResult{
				key: 'quad9'
				ranked: core.Ranked{ key: 'quad9', rank: 1 }
				edge: Edge{ median_penalty_ms: 60.0 }
			},
			ProviderResult{
				key: 'cloudflare'
				ranked: core.Ranked{ key: 'cloudflare', rank: 2 }
				edge: Edge{ median_penalty_ms: 10.0 }
			},
		]
	}
	alerts := watch_alerts(current, current, ?f64(50.0))
	assert alerts.len == 1
	assert alerts[0].contains('quad9')
	assert alerts[0].contains('60.0')
}

// A provider with no edge sample at all must never read as crossing a
// threshold of zero.
fn test_edge_threshold_skips_a_provider_with_no_edge_sample() {
	current := RunResult{
		results: [
			ProviderResult{
				key: 'quad9'
				ranked: core.Ranked{ key: 'quad9', rank: 1 }
			},
		]
	}
	assert watch_alerts(current, current, ?f64(0.0)).len == 0
}
