module store

import time

// Reading history back: docs/OUTPUT.md § history.
//
// `Line.comparable` and `Line.group_key` already refuse to mix networks,
// cold modes, domain sets and probes; this is what filters, groups and plots
// the lines that pass that test. Nothing here touches the file itself, so it
// is exercised with plain `[]Line` values and no filesystem at all.

// HistoryFilter narrows the lines a query considers, before grouping.
pub struct HistoryFilter {

	// since_rfc3339 drops any line older than this instant, compared as a
	// plain string. RFC 3339 timestamps in UTC, which is what every line
	// carries, sort lexicographically in time order, so there is no parser to
	// get wrong here.
pub:
	since_rfc3339 string
	asn           string
	provider      string
}

// filter_lines applies asn, provider and time-window filters together. An
// empty field in the filter matches everything for that field.
pub fn filter_lines(lines []Line, f HistoryFilter) []Line {
	mut out := []Line{}
	for l in lines {
		if f.asn != '' && l.asn != f.asn {
			continue
		}
		if f.provider != '' && l.provider != f.provider {
			continue
		}
		if f.since_rfc3339 != '' && l.ts < f.since_rfc3339 {
			continue
		}
		out << l
	}
	return out
}

// HistoryGroup is one (network, cold mode, domain set, probe, provider)
// bucket, aggregated across every run history holds for it.
pub struct HistoryGroup {
pub:
	group_key    string
	provider     string
	probe        string
	runs         int
	p50_mean     ?f64
	p50_min      ?f64
	p50_max      ?f64
	latest_score ?f64
	latest_ts    string
}

// aggregate buckets lines by network and provider, and summarises each
// bucket. Buckets come back in the order their first line was seen, which for
// an append-only file is the order runs happened in.
pub fn aggregate(lines []Line) []HistoryGroup {
	mut buckets := map[string][]Line{}
	mut order := []string{}
	for l in lines {
		key := '${l.group_key()}|${l.provider}'
		if key !in buckets {
			order << key
		}
		buckets[key] << l
	}

	mut out := []HistoryGroup{}
	for key in order {
		bucket := buckets[key]
		mut p50s := []f64{}
		mut latest := bucket[0]
		for l in bucket {
			if p50 := l.p50 {
				p50s << p50
			}
			// String comparison, not parsed time, for the reason
			// HistoryFilter.since_rfc3339 gives: every ts is RFC 3339 in UTC,
			// and that format sorts lexicographically in time order.
			if l.ts > latest.ts {
				latest = l
			}
		}
		out << HistoryGroup{
			group_key: bucket[0].group_key()
			provider: bucket[0].provider
			probe: bucket[0].probe
			runs: bucket.len
			p50_mean: mean(p50s)
			p50_min: min_of(p50s)
			p50_max: max_of(p50s)
			latest_score: latest.score
			latest_ts: latest.ts
		}
	}
	return out
}

fn mean(values []f64) ?f64 {
	if values.len == 0 {
		return none
	}
	mut sum := 0.0
	for v in values {
		sum += v
	}
	return round1(sum / f64(values.len))
}

fn min_of(values []f64) ?f64 {
	if values.len == 0 {
		return none
	}
	mut lo := values[0]
	for v in values {
		if v < lo {
			lo = v
		}
	}
	return lo
}

fn max_of(values []f64) ?f64 {
	if values.len == 0 {
		return none
	}
	mut hi := values[0]
	for v in values {
		if v > hi {
			hi = v
		}
	}
	return hi
}

// sparkline_blocks are the eight eighths of a Unicode block, low to high.
const sparkline_blocks = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']

// sparkline renders a series as one line of block characters, scaled between
// its own lowest and highest value: `history --plot` has no fixed axis to
// compare against, unlike the run's own score, which is scaled against a
// published range.
//
// A series with no spread at all, every value identical, is not an error:
// it is a resolver holding steady, and it renders as the middle block
// repeated rather than as the lowest or the highest.
pub fn sparkline(values []f64) string {
	if values.len == 0 {
		return ''
	}
	mut lo := values[0]
	mut hi := values[0]
	for v in values {
		if v < lo {
			lo = v
		}
		if v > hi {
			hi = v
		}
	}
	if hi == lo {
		return sparkline_blocks[sparkline_blocks.len / 2].repeat(values.len)
	}

	mut out := ''
	for v in values {
		idx := int((v - lo) / (hi - lo) * f64(sparkline_blocks.len - 1))
		out += sparkline_blocks[idx]
	}
	return out
}

// last_duration parses the compact form `--last` takes: a positive integer
// followed by h (hours), d (days) or w (weeks). Nothing fancier: it names a
// cutoff, not a calendar.
pub fn last_duration(text string) !time.Duration {
	if text.len < 2 {
		return error('"${text}" is not a duration; use a number followed by h, d or w')
	}
	unit := text[text.len - 1]
	n := text[..text.len - 1].int()
	if n <= 0 {
		return error('"${text}" is not a positive duration')
	}
	return match unit {
		`h` { n * time.hour }
		`d` { n * 24 * time.hour }
		`w` { n * 7 * 24 * time.hour }
		else { error('"${text}" must end in h, d or w') }
	}
}
