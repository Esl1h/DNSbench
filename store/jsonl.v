module store

import json2
import os

// Append-only run history, one flattened measurement per line.
//
// Not SQLite, deliberately: V's db.sqlite needs sqlite3.h at build time, which
// costs either the self-contained binary or the one-second build. For a tool
// run a few times a week, JSONL is jq-able, grep-able, diffable and
// attachable to a support ticket. docs/OUTPUT.md § history.
//
// The network fingerprint on every line is not decoration. Without it, history
// averages a fibre run with a mobile one and reports the mean of two unrelated
// networks. That exact mistake, overwriting a mobile log with a fibre one,
// happened during the research that motivated this tool.

// Line is one (provider, probe) measurement, flattened.
pub struct Line {
pub:
	ts     string
	asn    string
	ifname string
	ipv6   bool

	provider string
	probe    string

	n       int
	refused int
	p50     ?f64
	p95     ?f64
	jitter  ?f64
	loss    f64

	edge_penalty   ?f64
	edge_misrouted int
	score          ?f64
	profile        string

	catalog_version int
	domains         string
	cold_mode       string
	tool            string
}

// lines flattens a run into one entry per (provider, probe).
//
// Excluded providers carry no score and say so with a null, rather than being
// left out: a resolver that was unreachable last Tuesday is a fact worth
// keeping.
pub fn (r RunResult) lines() []Line {
	mut out := []Line{}
	for p in r.results {
		score := if p.ranked.excluded != none { ?f64(none) } else { ?f64(round1(p.ranked.score)) }
		for probe in p.probes {
			out << Line{
				ts: r.run.started_at
				asn: r.network.asn
				ifname: r.network.ifname
				ipv6: r.network.ipv6
				provider: p.key
				probe: probe.name
				n: probe.stats.n
				refused: probe.stats.refused
				p50: probe.stats.p50
				p95: probe.stats.p95
				jitter: probe.stats.jitter
				loss: probe.stats.loss
				edge_penalty: p.edge.median_penalty_ms
				edge_misrouted: p.edge.misrouted
				score: score
				profile: r.run.profile
				catalog_version: r.datasets.catalog.version
				domains: r.datasets.domains.warm
				cold_mode: r.datasets.domains.cold_mode
				tool: r.tool.version
			}
		}
	}
	return out
}

// to_jsonl renders the lines, newline-terminated, ready to append.
pub fn (r RunResult) to_jsonl() string {
	mut out := []string{}
	for line in r.lines() {
		out << line.encode()
	}
	if out.len == 0 {
		return ''
	}
	return out.join('\n') + '\n'
}

// encode writes one line. Absent figures are explicit nulls for the same reason
// they are in the JSON output: an omitted key is indistinguishable from an
// older writer, and 0 ms is a latency.
pub fn (l Line) encode() string {
	mut m := map[string]json2.Any{}
	m['ts'] = l.ts
	m['asn'] = l.asn
	m['ifname'] = l.ifname
	m['ipv6'] = l.ipv6
	m['provider'] = l.provider
	m['probe'] = l.probe
	m['n'] = l.n
	m['refused'] = l.refused
	m['p50'] = opt_any(l.p50)
	m['p95'] = opt_any(l.p95)
	m['jitter'] = opt_any(l.jitter)
	m['loss'] = round1(l.loss)
	m['edge_penalty'] = opt_any(l.edge_penalty)
	m['edge_misrouted'] = l.edge_misrouted
	m['score'] = opt_any(l.score)
	m['profile'] = l.profile
	m['catalog_version'] = l.catalog_version
	m['domains'] = l.domains
	m['cold_mode'] = l.cold_mode
	m['tool'] = l.tool
	return json2.Any(m).str()
}

// append writes a run's lines to the history file, creating it if needed.
//
// Append-only and never rewritten: a history a tool can edit is a history a bug
// can quietly rewrite.
pub fn append(path string, r RunResult) ! {
	body := r.to_jsonl()
	if body == '' {
		return
	}
	dir := os.dir(path)
	if dir != '' && !os.exists(dir) {
		os.mkdir_all(dir)!
	}
	mut f := os.open_append(path)!
	defer {
		f.close()
	}
	f.write_string(body)!
}

// read_history reads every line of a history file back, tolerant of both a
// file that has never been written (`dnsbench history` before the first
// `--history` run is not an error) and of one bad line partway through a
// file that has otherwise been appended to correctly. The second return
// value names every line that failed to parse, by number.
pub fn read_history(path string) ([]Line, []string) {
	if !os.exists(path) {
		return []Line{}, []string{}
	}
	text := os.read_file(path) or { return []Line{}, []string{} }

	mut lines := []Line{}
	mut errors := []string{}
	for i, raw in text.split_into_lines() {
		trimmed := raw.trim_space()
		if trimmed == '' {
			continue
		}
		line := parse_line(trimmed) or {
			errors << 'line ${i + 1}: ${err.msg()}'
			continue
		}
		lines << line
	}
	return lines, errors
}

// comparable reports whether two history lines describe measurements that may
// be aggregated together.
//
// Four things make results incomparable, and each of them silently, which is
// why this is a function rather than a note in the documentation:
//
//   A different network. Fibre and mobile are different measurements of
//   different things wearing the same units.
//
//   A different cold mode. `own` recurses to one controlled zone; `wild`
//   recurses to whatever the random label lands on. The numbers are not the
//   same quantity.
//
//   A different domain set. A moving dataset makes June incomparable with
//   August, which is the whole reason the Tranco ID is pinned.
//
//   A different probe. Comparing a warm sample with a cold one needs no
//   explanation.
pub fn comparable(a Line, b Line) bool {
	return a.asn == b.asn && a.ifname == b.ifname && a.cold_mode == b.cold_mode && a.domains == b.domains && a.probe == b.probe
}

// group_key is what `history` groups by when no filter is given.
pub fn (l Line) group_key() string {
	return '${l.asn}|${l.ifname}|${l.cold_mode}|${l.domains}|${l.probe}'
}

// parse_line reads one history line back.
pub fn parse_line(text string) !Line {
	any := json2.decode[json2.Any](text)!
	m := any.as_map()

	return Line{
		ts: str_of(m, 'ts')
		asn: str_of(m, 'asn')
		ifname: str_of(m, 'ifname')
		ipv6: m['ipv6'] or { json2.Any(false) }.bool()
		provider: str_of(m, 'provider')
		probe: str_of(m, 'probe')
		n: m['n'] or { json2.Any(0) }.int()
		refused: m['refused'] or { json2.Any(0) }.int()
		p50: f64_of(m, 'p50')
		p95: f64_of(m, 'p95')
		jitter: f64_of(m, 'jitter')
		loss: f64_of(m, 'loss') or { 0.0 }
		edge_penalty: f64_of(m, 'edge_penalty')
		score: f64_of(m, 'score')
		profile: str_of(m, 'profile')
		catalog_version: m['catalog_version'] or { json2.Any(0) }.int()
		domains: str_of(m, 'domains')
		cold_mode: str_of(m, 'cold_mode')
		tool: str_of(m, 'tool')
	}
}

fn str_of(m map[string]json2.Any, key string) string {
	return m[key] or { return '' }.str()
}

// f64_of returns none for a null or a missing key, which is how a figure that
// was absent when written stays absent when read.
fn f64_of(m map[string]json2.Any, key string) ?f64 {
	value := m[key] or { return none }
	if value is json2.Null {
		return none
	}
	return value.f64()
}
