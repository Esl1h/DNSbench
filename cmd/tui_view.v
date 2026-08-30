module main

import core
import store

// The pure half of the terminal interface.
//
// Which columns fit, what each cell says, how the rows are ordered, which of
// them are shown and what colour each figure earns. It draws nothing and does
// not import term.ui, which is what lets every rule in docs/TUI.md be asserted
// by a test with no terminal attached.

// Column is one field of the table, in the order it is printed.
enum Column {
	rank
	provider
	score
	p50
	p95
	jitter
	loss
	edge
	misrouted
	dot
	flags
}

// ColumnSpec is the width the column occupies and how readily it is given up
// when the terminal is too narrow to hold everything.
//
// `edge` carries no drop rank and never leaves the table. It is the reason the
// tool exists, and a build of dnsbench that hides it on an 80-column terminal
// would be hiding its own finding. `flags` and `dot` go first because the
// detail view has both.
struct ColumnSpec {
	column Column
	header string
	width  int
	// drop_order counts up from 1, lowest dropped first. Zero never drops.
	drop_order int
}

const table_indent = 2

const column_gap = 2

const column_specs = [
	ColumnSpec{
		column: .rank
		header: '  #'
		width: 3
	},
	ColumnSpec{
		column: .provider
		header: 'PROVIDER'
		width: 18
	},
	ColumnSpec{
		column: .score
		header: 'SCORE'
		width: 5
	},
	ColumnSpec{
		column: .p50
		header: '  p50'
		width: 5
	},
	ColumnSpec{
		column: .p95
		header: '  p95'
		width: 5
		drop_order: 5
	},
	ColumnSpec{
		column: .jitter
		header: '  JIT'
		width: 5
		drop_order: 4
	},
	ColumnSpec{
		column: .loss
		header: ' LOSS'
		width: 5
		drop_order: 6
	},
	ColumnSpec{
		column: .edge
		header: '  EDGE'
		width: 6
	},
	ColumnSpec{
		column: .misrouted
		header: '  MIS'
		width: 5
		drop_order: 3
	},
	ColumnSpec{
		column: .dot
		header: '  DoT'
		width: 5
		drop_order: 2
	},
	ColumnSpec{
		column: .flags
		header: 'FLAGS'
		width: 18
		drop_order: 1
	},
]

// visible_columns drops from the right, in the published order, until the table
// fits.
//
// Never by wrapping and never by truncating a figure: a score printed as `9` is
// worse than a score not printed at all, because the reader has no way to see
// that a digit went missing.
fn visible_columns(width int) []ColumnSpec {
	mut shown := column_specs.clone()
	for {
		if table_width(shown) <= width {
			return shown
		}
		mut victim := -1
		mut worst := 0
		for i, spec in shown {
			if spec.drop_order > 0 && (victim < 0 || spec.drop_order < worst) {
				victim = i
				worst = spec.drop_order
			}
		}
		if victim < 0 {
			// Everything droppable is gone. What is left is the minimum table
			// and it is printed even if the terminal cannot hold it, because
			// the alternative is a screen with no numbers on it.
			return shown
		}
		shown.delete(victim)
	}
	return shown
}

// table_width is what the given columns occupy, gaps and indent included.
fn table_width(shown []ColumnSpec) int {
	mut total := table_indent
	for i, spec in shown {
		if i > 0 {
			total += column_gap
		}
		total += spec.width
	}
	return total
}

// Tone is what a figure earned, not what colour it is printed in. The palette
// decides that, and in monochrome every tone renders the same: docs/TUI.md
// requires that colour never be the only carrier of meaning, so every cell that
// has a tone also has a number or a glyph beside it.
enum Tone {
	plain
	good
	warn
	bad
	// info is neutral and deliberately not on the good/bad axis. Blocking is a
	// preference, not a virtue.
	info
	// dim is what declared, unverified material is printed in. It is never
	// coloured as if it had been measured.
	dim
}

// Flag is one badge in the FLAGS column, carrying whether it was measured.
struct Flag {
	text string
	tone Tone
}

// ViewBests are the reference points the latency columns are coloured against.
//
// They are the best figures on the screen, recomputed per frame from the rows
// actually shown, because docs/SCORING.md scores everything relative to the
// run and a colour drawn against an absolute threshold would say something
// different from the number beside it.
struct ViewBests {
	p50 ?f64
	p95 ?f64
	dot ?f64
	// The observed score range, which the score gradient is drawn across.
	score_low  f64
	score_high f64
}

// probe_views are what Tab cycles through: the probe whose distribution fills
// the p50, p95, JIT and LOSS columns. The DoT column is always dot_warm, and
// the EDGE column is always the edge probe, because neither is a distribution
// over the domain set.
const probe_views = ['warm', 'cold', 'tcp', 'dot_warm', 'dot_fresh', 'doh']

// view_bests measures the screen against itself.
fn view_bests(results []store.ProviderResult, view string) ViewBests {
	mut p50 := ?f64(none)
	mut p95 := ?f64(none)
	mut dot := ?f64(none)
	mut low := ?f64(none)
	mut high := ?f64(none)

	for p in results {
		if p.is_cache {
			// A cache hit answers from memory. Colouring the network resolvers
			// against 0.3 ms would paint every one of them red.
			continue
		}
		stats := stats_named(p, view)
		p50 = lower(p50, stats.p50)
		p95 = lower(p95, stats.p95)
		dot = lower(dot, stats_named(p, 'dot_warm').p50)
		if p.ranked.excluded == none {
			low = lower(low, p.ranked.score)
			high = higher(high, p.ranked.score)
		}
	}

	return ViewBests{
		p50: p50
		p95: p95
		dot: dot
		score_low: low or { 0.0 }
		score_high: high or { 100.0 }
	}
}

fn lower(current ?f64, candidate ?f64) ?f64 {
	value := candidate or { return current }
	found := current or { return value }
	return if value < found { value } else { found }
}

fn higher(current ?f64, candidate ?f64) ?f64 {
	value := candidate or { return current }
	found := current or { return value }
	return if value > found { value } else { found }
}

// stats_named is one probe's distribution, empty when the provider did not run
// it. An empty Stats has no p50, so the cell prints a dash rather than a zero.
fn stats_named(p store.ProviderResult, name string) core.Stats {
	for probe in p.probes {
		if probe.name == name {
			return probe.stats
		}
	}
	return core.Stats{}
}

// ── cells ────────────────────────────────────────────────────────────────────

// cell_text is what one column says about one provider.
//
// A figure that was not measured prints a dash. Never a zero: zero is the best
// value in every latency column on this screen and would sort and colour as
// such. docs/METHODOLOGY.md § Nothing is not zero.
fn cell_text(p store.ProviderResult, column Column, view string, selected_rank string) string {
	stats := stats_named(p, view)
	return match column {
		.rank { selected_rank }
		.provider { '${truncate(p.label, 18):-18s}' }
		.score {
			if p.ranked.excluded != none { '    -' } else { '${p.ranked.score:5.1f}' }
		}
		.p50 { number_cell(stats.p50) }
		.p95 { number_cell(stats.p95) }
		.jitter { number_cell(stats.jitter) }
		.loss {
			if stats.expected == 0 { '    -' } else { '${stats.loss:4.1f}%' }
		}
		.edge { signed_cell(p.edge.median_penalty_ms) }
		.misrouted { misrouted_text(p) }
		.dot { number_cell(stats_named(p, 'dot_warm').p50) }
		.flags { flags_for(p).map(it.text).join(' ') }
	}
}

fn number_cell(v ?f64) string {
	value := v or { return '    -' }
	return '${value:5.1f}'
}

// signed_cell prints the edge penalty with its sign, because +0.0 and a blank
// are different statements: one says this resolver is on the run's best edge,
// the other says nothing was measured. V's format verbs have no sign flag, so
// the sign is written here.
fn signed_cell(v ?f64) string {
	value := v or { return '     -' }
	sign := if value < 0 { '-' } else { '+' }
	magnitude := if value < 0 { -value } else { value }
	printed := '${sign}${magnitude:.1f}'
	return '${printed:6s}'
}

// misrouted_text prints the count over what was measured. Three on its own is
// unreadable without knowing whether the host set held four or forty.
fn misrouted_text(p store.ProviderResult) string {
	if p.edge.measured == 0 {
		return '    -'
	}
	return '${p.edge.misrouted}/${p.edge.measured}'
}

fn truncate(s string, width int) string {
	if s.len <= width {
		return s
	}
	return s[..width - 1] + '~'
}

// flags_for renders the badges, measured first and declared after.
//
// The two are never merged and never share a tone. A `~` badge is dim because
// it is a claim by the provider; a `+` or `-` badge was established by a probe
// during this run and is allowed to contradict the claim beside it.
fn flags_for(p store.ProviderResult) []Flag {
	mut out := []Flag{}
	if v := p.capabilities.dnssec_validating {
		out << Flag{
			text: if v { '+DNSSEC' } else { '-DNSSEC' }
			tone: if v { .good } else { .bad }
		}
	}
	if blocked := p.capabilities.filtering['ads'] {
		out << Flag{
			text: if blocked { '+ads' } else { '-ads' }
			tone: .info
		}
	}
	for d in p.declared {
		out << Flag{
			text: '~${d}'
			tone: .dim
		}
	}
	return out
}

// ── tones ────────────────────────────────────────────────────────────────────

// The thresholds of docs/TUI.md § Colour semantics, in one place so that the
// table and the detail view cannot disagree about what counts as slow.
const latency_good_ratio = 1.25

const latency_warn_ratio = 2.0

const jitter_good_ms = 5.0

const jitter_warn_ms = 15.0

const loss_warn_pct = 5.0

const edge_good_ms = 5.0

const edge_warn_ms = 25.0

// cell_tone is what a figure earned. Absent figures earn nothing: a dash is not
// a bad result, it is the absence of one.
fn cell_tone(p store.ProviderResult, column Column, view string, bests ViewBests) Tone {
	stats := stats_named(p, view)
	return match column {
		.score { score_tone(p, bests) }
		.p50 { latency_tone(stats.p50, bests.p50) }
		.p95 { latency_tone(stats.p95, bests.p95) }
		.jitter { threshold_tone(stats.jitter, jitter_good_ms, jitter_warn_ms) }
		.loss { loss_tone(stats) }
		.edge { threshold_tone(p.edge.median_penalty_ms, edge_good_ms, edge_warn_ms) }
		.dot { latency_tone(stats_named(p, 'dot_warm').p50, bests.dot) }
		else { .plain }
	}
}

// score_gradient places a score in the run's own observed range, 0 at the worst
// and 1 at the best. The palette turns that into a colour; monochrome readers
// have the sort order, which says the same thing.
fn score_gradient(p store.ProviderResult, bests ViewBests) f64 {
	if p.ranked.excluded != none {
		return 0.0
	}
	span := bests.score_high - bests.score_low
	if span <= 0 {
		return 1.0
	}
	fraction := (p.ranked.score - bests.score_low) / span
	if fraction < 0 {
		return 0.0
	}
	if fraction > 1 {
		return 1.0
	}
	return fraction
}

fn score_tone(p store.ProviderResult, bests ViewBests) Tone {
	if p.ranked.excluded != none {
		return .dim
	}
	gradient := score_gradient(p, bests)
	if gradient >= 0.66 {
		return .good
	}
	if gradient >= 0.33 {
		return .warn
	}
	return .bad
}

// latency_tone measures against the best figure on the screen, not against a
// fixed millisecond count. A 40 ms p50 is excellent on a satellite link and
// poor on fibre, and the run already knows which one it is on.
fn latency_tone(v ?f64, best ?f64) Tone {
	value := v or { return .plain }
	reference := best or { return .plain }
	if reference <= 0 {
		return .plain
	}
	ratio := value / reference
	if ratio <= latency_good_ratio {
		return .good
	}
	if ratio <= latency_warn_ratio {
		return .warn
	}
	return .bad
}

fn threshold_tone(v ?f64, good f64, warn f64) Tone {
	value := v or { return .plain }
	if value <= good {
		return .good
	}
	if value <= warn {
		return .warn
	}
	return .bad
}

fn loss_tone(stats core.Stats) Tone {
	if stats.expected == 0 {
		return .plain
	}
	if stats.loss == 0 {
		return .good
	}
	if stats.loss <= loss_warn_pct {
		return .warn
	}
	return .bad
}

// ── ordering and selection ───────────────────────────────────────────────────

// Section is which block of the screen a row belongs to. The order of the
// values is the order the blocks are drawn in.
enum Section {
	ranked
	not_ranked
	// A local cache answers from memory, which is not comparable with a network
	// round trip. docs/SCORING.md calls putting the two in one list the most
	// important exclusion there is, so the cache rows sit below the line with
	// no score and no rank.
	cache
}

// DisplayRow is one line of the table: which result it shows and which block it
// sits in.
struct DisplayRow {
	index   int
	section Section
}

// sortable_columns are what `s` cycles through and what `1` to `9` select.
// `rank` is first because it is the run's own answer, and returning to it after
// exploring is the common move.
const sortable_columns = [Column.rank, .provider, .score, .p50, .p95, .jitter, .loss, .edge,
	.misrouted, .dot]

struct SortRow {
	index int
	text  string
	num   f64
	rank  int
}

// display_rows is the whole visible list: the ranked block in the requested
// order, then whatever was measured but not ranked, then the local caches.
//
// Only the ranked block is sorted. The other two keep the order they were
// assembled in, because neither carries a score to sort by and shuffling them
// would only make a row harder to find again.
fn display_rows(results []store.ProviderResult, column Column, view string, descending bool, filters []string, search string) []DisplayRow {
	mut ranked := []SortRow{}
	mut absent := []SortRow{}
	mut others := []DisplayRow{}
	mut caches := []DisplayRow{}

	for i, p in results {
		if !matches_filters(p, filters) || !matches_search(p, search) {
			continue
		}
		if p.is_cache {
			caches << DisplayRow{
				index: i
				section: .cache
			}
			continue
		}
		if p.ranked.excluded != none {
			others << DisplayRow{
				index: i
				section: .not_ranked
			}
			continue
		}
		text, num, has := sort_key(p, column, view)
		row := SortRow{
			index: i
			text: text
			num: num
			rank: p.ranked.rank
		}
		// A provider with no figure in the sorted column keeps its place at the
		// end whichever way the sort runs. Reversing the order of what was
		// never measured says nothing.
		if has {
			ranked << row
		} else {
			absent << row
		}
	}

	ranked.sort_with_compare(compare_sort_rows)
	if descending {
		ranked.reverse_in_place()
	}

	mut out := []DisplayRow{cap: results.len}
	for row in ranked {
		out << DisplayRow{
			index: row.index
			section: .ranked
		}
	}
	for row in absent {
		out << DisplayRow{
			index: row.index
			section: .ranked
		}
	}
	out << others
	out << caches
	return out
}

fn compare_sort_rows(a &SortRow, b &SortRow) int {
	if a.text != b.text {
		return if a.text < b.text { -1 } else { 1 }
	}
	if a.num != b.num {
		return if a.num < b.num { -1 } else { 1 }
	}
	// The run's own ranking breaks every tie, so the order is total and a
	// reversed sort is the exact mirror of the forward one.
	return a.rank - b.rank
}

// sort_key is what a column sorts by, and whether the provider has one at all.
//
// The latency columns sort by whichever probe the table is currently showing,
// so that sorting by p50 while looking at `cold` orders by cold and not by
// something off screen.
fn sort_key(p store.ProviderResult, column Column, view string) (string, f64, bool) {
	if column == .provider {
		return p.label.to_lower(), 0.0, true
	}
	if column == .flags {
		return flags_for(p).map(it.text).join(' '), 0.0, true
	}
	if column == .rank {
		return '', f64(p.ranked.rank), true
	}
	if column == .score {
		return '', p.ranked.score, p.ranked.excluded == none
	}
	if column == .edge {
		return '', p.edge.median_penalty_ms or { 0.0 }, p.edge.median_penalty_ms != none
	}
	if column == .misrouted {
		return '', f64(p.edge.misrouted), p.edge.measured > 0
	}

	stats := stats_named(p, view)
	if column == .loss {
		return '', stats.loss, stats.expected > 0
	}

	value := match column {
		.p50 { stats.p50 }
		.p95 { stats.p95 }
		.jitter { stats.jitter }
		else { stats_named(p, 'dot_warm').p50 }
	}
	return '', value or { 0.0 }, value != none
}

// ── filtering ────────────────────────────────────────────────────────────────

// Filter is one entry of the `f` menu. `measured` is not decoration: it decides
// which half of the output the filter reads from, and the menu says which one
// the reader is about to apply.
struct Filter {
	name     string
	label    string
	measured bool
}

// filters_available are the five of docs/TUI.md § Keybindings.
//
// Two of them read declared tags and three read probe results, and they are
// never merged. A provider that declares `nolog` has said so; a provider that
// validates DNSSEC was caught doing it.
const filters_available = [
	Filter{
		name: 'dnssec'
		label: 'validates DNSSEC'
		measured: true
	},
	Filter{
		name: 'no-filtering'
		label: 'resolved the ad domain'
		measured: true
	},
	Filter{
		name: 'ipv6'
		label: 'IPv6 available'
		measured: true
	},
	Filter{
		name: 'nolog'
		label: 'declares nolog'
	},
	Filter{
		name: 'nofilter'
		label: 'declares nofilter'
	},
]

// matches_filters is an AND across everything switched on. A filter reading a
// question that was never asked excludes the provider rather than assuming an
// answer for it.
fn matches_filters(p store.ProviderResult, filters []string) bool {
	for name in filters {
		matched := match name {
			'dnssec' { p.capabilities.dnssec_validating or { false } }
			'no-filtering' { !(p.capabilities.filtering['ads'] or { true }) }
			'ipv6' { p.capabilities.ipv6 }
			'nolog' { 'nolog' in p.declared }
			'nofilter' { 'nofilter' in p.declared }
			else { true }
		}
		if !matched {
			return false
		}
	}
	return true
}

// matches_search is an incremental substring match over the name a reader can
// see and the key they would pass to --only.
fn matches_search(p store.ProviderResult, query string) bool {
	if query == '' {
		return true
	}
	needle := query.to_lower()
	return p.label.to_lower().contains(needle) || p.key.to_lower().contains(needle)
}
