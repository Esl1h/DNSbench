module main

import os
import term.ui as tui
import time
import core
import store

// The terminal interface of docs/TUI.md.
//
// It measures nothing. The run happens on its own thread, exactly the run the
// plain CLI performs, and reaches this file as finished snapshots down a
// channel. What is here is the frame loop, the layout and the keys: the drawing
// half of docs/TUI.md, with the rules it draws by in cmd/tui_view.v where they
// can be tested without a terminal.

// tui_frame_rate is the ceiling, not the redraw rate. A frame is only painted
// when something changed, because a benchmark that burns CPU redrawing is
// perturbing its own measurement.
const tui_frame_rate = 15

// tui_snapshot_interval is how often the measuring thread assembles what it has
// so far. Every step would mean ranking sixteen providers a few hundred times a
// second, and the bootstrap is not free.
const tui_snapshot_interval = 700 * time.millisecond

// tui_live_resamples is the bootstrap size for a snapshot of a run still in
// progress. The published figure is core.default_resamples and the final
// snapshot uses it; a live interval is redrawn every second and is allowed to
// be coarser than the one that ends up in the JSON.
const tui_live_resamples = 120

// abort_message is what `a` makes execute return. It is matched rather than
// reported, because an aborted run is not a failed one.
const abort_message = 'run aborted'

const known_palettes = ['default', 'colorblind']

// tui_unavailable says why this terminal cannot host the interface, and nothing
// when it can.
//
// term.ui panics rather than returning an error when stdin or stdout is not a
// TTY, so the check happens here, before it is given the chance. A run whose
// output is being piped into a file wants the table anyway, which is what the
// caller falls back to.
fn tui_unavailable() ?string {
	term := os.getenv('TERM')
	if term == '' {
		return 'TERM is not set'
	}
	if term == 'dumb' {
		return 'TERM is ${term}'
	}
	if os.is_atty(0) == 0 || os.is_atty(1) == 0 {
		return 'not running under a TTY'
	}
	return none
}

// Frame is one state of the world as the measuring thread saw it.
struct Frame {
	result   store.RunResult
	samples  []core.Samples
	best_rtt ?f64
	step     int
	total    int
	done     bool
	// failure is set when the run could not start or could not continue. An
	// abort is not a failure and leaves this empty.
	failure string
}

// LiveWatcher is the Watcher the TUI passes into the run.
//
// It runs on the measuring thread and touches nothing the drawing thread owns:
// everything crosses between them through the two channels, which is what keeps
// the samples from being read while they are being appended to.
struct LiveWatcher {
	opts   Options
	frames chan Frame
	abort  chan bool
mut:
	ctx     RunContext
	last    time.Time
	started bool
}

fn (mut w LiveWatcher) begin(ctx RunContext) {
	w.ctx = ctx
	w.started = true
	w.last = time.now()
}

fn (mut w LiveWatcher) tick(step int, total int, subjects []Subject) bool {
	mut stop := false
	if w.abort.try_pop(mut stop) == .success {
		// The partial result goes out before the walk unwinds, so that `a`
		// keeps what was measured rather than only what was drawn.
		w.emit(subjects, step, total, true)
		return false
	}
	if time.since(w.last) < tui_snapshot_interval {
		return true
	}
	w.last = time.now()
	w.emit(subjects, step, total, false)
	return true
}

fn (mut w LiveWatcher) finish(result store.RunResult, samples []core.Samples, best_rtt ?f64) {
	w.frames.try_push(Frame{
		result: result
		samples: samples
		best_rtt: best_rtt
		step: 1
		total: 1
		done: true
	})
}

// emit assembles the run as it stands and offers it to the drawing thread.
//
// The edge and capability probes have not run yet at this point, so their
// columns are absent rather than provisional. An absent figure is already what
// the table prints for something it has not measured.
fn (mut w LiveWatcher) emit(subjects []Subject, step int, total int, final bool) {
	if !w.started {
		return
	}
	edge := map[string]core.EdgePenalty{}
	capabilities := map[string]Capability{}
	duration := f64(time.since(w.ctx.started).microseconds()) / 1_000_000.0
	partial := assemble(subjects, edge, capabilities, none, w.opts, w.ctx.net, w.ctx.origin, w.ctx.cat, w.ctx.started, duration, w.ctx.warnings, core.BootstrapSpec{
		resamples: tui_live_resamples
		seed: w.opts.seed
	})

	// A snapshot that dropped because the drawing thread was busy is not worth
	// waiting for: another one follows in well under a second.
	w.frames.try_push(Frame{
		result: store.RunResult{
			...partial
			run: store.Run{
				...partial.run
				// Never complete. Every snapshot this function makes is of a run
				// that has not finished, including the last one before an abort,
				// and docs/ARCHITECTURE.md § Failure policy says a partial result
				// must say so rather than leave the reader to infer it.
				complete: false
			}
		}
		samples: build_samples(subjects, edge, capabilities, w.ctx.net.ipv6)
		step: step
		total: total
		done: final
	})
}

// measure is the whole run, on its own thread.
fn measure(opts Options, frames chan Frame, abort chan bool) {
	mut watcher := Watcher(&LiveWatcher{
		opts: opts
		frames: frames
		abort: abort
	})
	run(opts, mut watcher) or {
		if err.msg() != abort_message {
			frames <- Frame{
				done: true
				failure: err.msg()
			}
		}
		return
	}
}

// ── palette ──────────────────────────────────────────────────────────────────

// Palette turns a Tone into a colour. It is the only place colours are named,
// so `--palette colorblind` is a different table of the same size rather than a
// branch at every draw call.
struct Palette {
	good tui.Color
	warn tui.Color
	bad  tui.Color
	info tui.Color
	dim  tui.Color
	head tui.Color
	// mono drops colour entirely. Every rule in docs/TUI.md § Colour semantics
	// is duplicated by a number or a glyph, so a monochrome table says the same
	// things in the same places.
	mono bool
}

fn palette_for(name string, mono bool) Palette {
	if name == 'colorblind' {
		// Blue and orange rather than green and red, which is the one swap that
		// covers deuteranopia and protanopia together.
		return Palette{
			good: tui.Color{0, 119, 187}
			warn: tui.Color{221, 170, 51}
			bad: tui.Color{238, 119, 51}
			info: tui.Color{170, 68, 255}
			dim: tui.Color{136, 136, 136}
			head: tui.Color{200, 200, 200}
			mono: mono
		}
	}
	return Palette{
		good: tui.Color{76, 175, 80}
		warn: tui.Color{255, 179, 0}
		bad: tui.Color{229, 57, 53}
		info: tui.Color{66, 165, 245}
		dim: tui.Color{136, 136, 136}
		head: tui.Color{200, 200, 200}
		mono: mono
	}
}

fn (p Palette) of(tone Tone) tui.Color {
	return match tone {
		.good { p.good }
		.warn { p.warn }
		.bad { p.bad }
		.info { p.info }
		.dim { p.dim }
		.plain { p.head }
	}
}

// gradient_of paints the score across the run's own observed range, good at the
// top and bad at the bottom, through warn in the middle.
fn (p Palette) gradient_of(fraction f64) tui.Color {
	if fraction >= 0.5 {
		return blend(p.warn, p.good, (fraction - 0.5) * 2.0)
	}
	return blend(p.bad, p.warn, fraction * 2.0)
}

fn blend(from tui.Color, to tui.Color, t f64) tui.Color {
	return tui.Color{
		r: u8(f64(from.r) + (f64(to.r) - f64(from.r)) * t)
		g: u8(f64(from.g) + (f64(to.g) - f64(from.g)) * t)
		b: u8(f64(from.b) + (f64(to.b) - f64(from.b)) * t)
	}
}

// ── the application ──────────────────────────────────────────────────────────

// Mode is what the keyboard is currently doing. Every mode but `table` is an
// overlay drawn on top of it.
enum Mode {
	table
	detail
	help
	filters
	export
	search
}

// LineKind is what one line of the scrolling area holds.
enum LineKind {
	row
	// A tier band. docs/SCORING.md groups providers whose intervals overlap,
	// and the rule between them is where that grouping becomes visible.
	band
	caption
}

struct ScreenLine {
	kind    LineKind
	index   int
	text    string
	section Section
}

struct App {
mut:
	ctx     &tui.Context = unsafe { nil }
	opts    Options
	palette Palette
	frames  chan Frame
	abort   chan bool
	latest  Frame
	have    bool
	running bool
	started time.Time

	view       int
	profile    string
	sort_by    Column
	descending bool
	filters    []string
	search     string
	mode       Mode
	selected   int
	scroll     int
	status     string
	lines      []ScreenLine
	dirty      bool
	clock      string
}

// run_tui owns the terminal for the rest of the process.
//
// It never returns: the frame loop runs until a key exits, which is also where
// the exit code is decided, so that a scripted `--tui` run still says what it
// found.
fn run_tui(opts Options) {
	mut app := &App{
		opts: opts
		profile: opts.profile
		sort_by: .rank
		palette: palette_for(opts.palette, opts.no_color || os.getenv('NO_COLOR') != '')
		frames: chan Frame{ cap: 8 }
		abort: chan bool{ cap: 1 }
		started: time.now()
		dirty: true
		status: 'measuring'
	}
	app.running = true

	spawn measure(opts, app.frames, app.abort)
	app.ctx = tui.init(
		user_data: app
		event_fn: on_event
		frame_fn: on_frame
		hide_cursor: true
		frame_rate: tui_frame_rate
		window_title: 'dnsbench'
		// SIGPIPE is deliberately not in this list. main() ignores it because a
		// DoT server may close an idle connection mid-run, and letting term.ui
		// install its own handler would put the kill back.
		reset: [.hup, .int, .quit, .term]
	)
	app.ctx.run() or {
		eprintln('dnsbench: ${err.msg()}')
		exit(store.exit_measurement_error)
	}
}

fn on_frame(x voidptr) {
	mut app := unsafe { &App(x) }
	app.drain()
	app.tick_clock()
	if !app.dirty {
		return
	}
	app.dirty = false
	app.draw()
}

// drain takes every snapshot waiting and keeps the newest. Drawing the ones in
// between would cost a frame each and show nothing a later one does not.
fn (mut a App) drain() {
	mut frame := Frame{}
	mut received := false
	for a.frames.try_pop(mut frame) == .success {
		a.latest = frame
		received = true
	}
	if !received {
		return
	}
	a.have = a.latest.failure == ''
	if a.latest.done {
		a.running = false
		a.status = if a.latest.failure != '' {
			'run failed: ${a.latest.failure}'
		} else if a.latest.result.run.complete {
			'run complete'
		} else {
			'run stopped, results are partial'
		}
	}
	if a.profile != a.latest.result.run.profile {
		// A profile chosen while the run was still going survives the next
		// snapshot, which arrives ranked under the profile the run started
		// with. Re-ranking is arithmetic on samples already taken.
		a.apply_profile()
	}
	a.rebuild()
}

// tick_clock redraws once a second so the elapsed time moves, and not more
// often. Everything else redraws when it changes.
fn (mut a App) tick_clock() {
	now := elapsed_text(a.started)
	if now != a.clock {
		a.clock = now
		a.dirty = true
	}
}

fn elapsed_text(from time.Time) string {
	seconds := int(time.since(from).seconds())
	return '${seconds / 60:02d}:${seconds % 60:02d}'
}

// ── model ────────────────────────────────────────────────────────────────────

// rebuild turns the current result into the lines the table draws, applying the
// sort, the filters and the search.
//
// The selected provider is followed across the rebuild by key rather than by
// position: a row that moves because a snapshot arrived, or because the sort
// changed, must not take the selection with it to whatever is now in its place.
fn (mut a App) rebuild() {
	previous := a.selected_key()

	rows := display_rows(a.latest.result.results, a.sort_by, a.probe_view(), a.descending, a.filters, a.search)

	mut lines := []ScreenLine{cap: rows.len + 4}
	mut section := Section.ranked
	mut tier := 0
	for i, row in rows {
		p := a.latest.result.results[row.index]
		if i == 0 || row.section != section {
			section = row.section
			if caption := section_caption(section) {
				lines << ScreenLine{
					kind: .caption
					text: caption
					section: section
				}
			}
			tier = 0
		}
		if section == .ranked && tier != 0 && p.ranked.tier != tier {
			lines << ScreenLine{
				kind: .band
				section: section
			}
		}
		tier = p.ranked.tier
		lines << ScreenLine{
			kind: .row
			index: row.index
			section: section
		}
	}
	a.lines = lines

	a.selected = 0
	if previous != '' {
		for i, line in a.lines {
			if line.kind == .row && a.latest.result.results[line.index].key == previous {
				a.selected = i
				break
			}
		}
	}
	if a.lines.len > 0 && a.lines[a.selected].kind != .row {
		a.move_selection(1)
	}
	a.dirty = true
}

fn section_caption(section Section) ?string {
	return match section {
		.ranked { none }
		.not_ranked { 'not ranked' }
		.cache { 'local resolvers (cache, not comparable in warm)' }
	}
}

fn (a App) selected_key() string {
	if a.selected < 0 || a.selected >= a.lines.len {
		return ''
	}
	line := a.lines[a.selected]
	if line.kind != .row {
		return ''
	}
	return a.latest.result.results[line.index].key
}

fn (a App) selected_result() ?store.ProviderResult {
	if a.selected < 0 || a.selected >= a.lines.len {
		return none
	}
	line := a.lines[a.selected]
	if line.kind != .row {
		return none
	}
	return a.latest.result.results[line.index]
}

// move_selection steps over the bands and captions, which are scenery rather
// than rows and cannot be selected.
fn (mut a App) move_selection(step int) {
	if a.lines.len == 0 {
		return
	}
	mut at := a.selected
	for _ in 0 .. a.lines.len {
		at += step
		if at < 0 || at >= a.lines.len {
			return
		}
		if a.lines[at].kind == .row {
			a.selected = at
			a.dirty = true
			return
		}
	}
}

// apply_profile re-ranks what has already been measured under a different set
// of weights.
//
// Nothing is measured again. That is the point of the key: a reader can see how
// much of the answer is the network and how much of it is the weighting, which
// is the honest way to present a composite score.
fn (mut a App) apply_profile() {
	weights := core.profiles[a.profile] or { return }
	ranked := core.rank_providers(a.latest.samples, a.latest.best_rtt, weights, core.BootstrapSpec{
		resamples: if a.running { tui_live_resamples } else { core.default_resamples }
		seed: a.opts.seed
	}) or { return }

	metrics := metrics_from(a.latest.samples)
	bests := core.compute_bests(metrics, a.latest.best_rtt)

	mut results := []store.ProviderResult{cap: a.latest.result.results.len}
	for r in ranked {
		for p in a.latest.result.results {
			if p.key != r.key {
				continue
			}
			mut m := core.Metrics{}
			for candidate in metrics {
				if candidate.key == r.key {
					m = candidate
					break
				}
			}
			results << store.ProviderResult{
				...p
				ranked: r
				subscores: core.subscores(m, bests)
			}
			break
		}
	}

	a.latest = Frame{
		...a.latest
		result: store.RunResult{
			...a.latest.result
			run: store.Run{
				...a.latest.result.run
				profile: a.profile
				weights: weights
			}
			results: results
		}
	}
}

// ── keys ─────────────────────────────────────────────────────────────────────
fn on_event(e &tui.Event, x voidptr) {
	mut app := unsafe { &App(x) }
	if e.typ == .resized {
		// The layout is recomputed from ctx.window_width on every frame, so a
		// resize needs nothing but a redraw. docs/TUI.md § Implementation notes
		// asks that the initial width never be assumed, and it is not.
		app.dirty = true
		return
	}
	if e.typ != .key_down {
		return
	}
	match app.mode {
		.search { app.search_key(e) }
		.filters { app.filters_key(e) }
		.export { app.export_key(e) }
		.help, .detail { app.overlay_key(e) }
		.table { app.table_key(e) }
	}
}

fn (mut a App) table_key(e &tui.Event) {
	page := if a.ctx.window_height > 10 { a.ctx.window_height - 8 } else { 1 }
	match e.code {
		.q, .escape {
			a.quit()
		}
		.up, .k {
			a.move_selection(-1)
		}
		.down, .j {
			a.move_selection(1)
		}
		.page_up {
			for _ in 0 .. page {
				a.move_selection(-1)
			}
		}
		.page_down {
			for _ in 0 .. page {
				a.move_selection(1)
			}
		}
		.home {
			a.selected = 0
			a.move_selection(if a.lines.len > 0 && a.lines[0].kind == .row { 0 } else { 1 })
			a.dirty = true
		}
		.end {
			a.selected = a.lines.len - 1
			if a.lines.len > 0 && a.lines[a.selected].kind != .row {
				a.move_selection(-1)
			}
			a.dirty = true
		}
		.s {
			a.cycle_sort(if e.modifiers.has(.shift) { -1 } else { 1 })
		}
		._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9 {
			a.sort_by_number(int(e.ascii) - 48)
		}
		.tab {
			a.cycle_view(1)
		}
		.p {
			a.cycle_profile()
		}
		.f {
			a.mode = .filters
			a.dirty = true
		}
		.slash {
			a.mode = .search
			a.dirty = true
		}
		.enter {
			if _ := a.selected_result() {
				a.mode = .detail
				a.dirty = true
			}
		}
		.e {
			a.mode = .export
			a.dirty = true
		}
		.r {
			a.restart()
		}
		.a {
			a.stop()
		}
		.question_mark {
			a.mode = .help
			a.dirty = true
		}
		else {}
	}
}

fn (mut a App) overlay_key(e &tui.Event) {
	match e.code {
		.escape, .q, .left, .enter {
			a.mode = .table
			a.dirty = true
		}
		.up, .k {
			if a.mode == .detail {
				a.move_selection(-1)
			}
		}
		.down, .j {
			if a.mode == .detail {
				a.move_selection(1)
			}
		}
		.c {
			if a.mode == .detail {
				a.export_one('json')
			}
		}
		else {}
	}
}

fn (mut a App) search_key(e &tui.Event) {
	match e.code {
		.escape {
			a.search = ''
			a.mode = .table
			a.rebuild()
		}
		.enter {
			a.mode = .table
			a.dirty = true
		}
		.backspace {
			if a.search.len > 0 {
				a.search = a.search.substr(0, a.search.len - 1)
				a.rebuild()
			}
		}
		else {
			if e.ascii >= 32 && e.ascii < 127 {
				a.search += e.ascii.ascii_str()
				a.rebuild()
			}
		}
	}
}

fn (mut a App) filters_key(e &tui.Event) {
	if e.code == .escape || e.code == .enter || e.code == .f {
		a.mode = .table
		a.dirty = true
		return
	}
	if e.code == .c {
		a.filters = []string{}
		a.rebuild()
		return
	}
	choice := int(e.ascii) - 49
	if choice < 0 || choice >= filters_available.len {
		return
	}
	name := filters_available[choice].name
	if name in a.filters {
		a.filters = a.filters.filter(it != name)
	} else {
		a.filters << name
	}
	a.rebuild()
}

fn (mut a App) export_key(e &tui.Event) {
	match e.code {
		.escape {
			a.mode = .table
		}
		.j { a.export_one('json') }
		.c { a.export_one('csv') }
		.m { a.export_one('markdown') }
		else {
			return
		}
	}
	a.mode = .table
	a.dirty = true
}

// ── actions ──────────────────────────────────────────────────────────────────

// quit restores the terminal and reports what the run found, so that a `--tui`
// session ends with the same exit code the plain table would have produced.
fn (mut a App) quit() {
	a.ctx.set_cursor_position(0, 0)
	a.ctx.show_cursor()
	a.ctx.flush()
	if !a.have {
		exit(store.exit_measurement_error)
	}
	exit(store.exit_code(a.latest.result))
}

fn (mut a App) cycle_sort(step int) {
	mut at := 0
	for i, column in sortable_columns {
		if column == a.sort_by {
			at = i
			break
		}
	}
	if step < 0 {
		// Shift reverses the direction rather than walking the list backwards:
		// docs/TUI.md gives `S` to the direction and `s` to the column.
		a.descending = !a.descending
	} else {
		at = (at + 1) % sortable_columns.len
		a.sort_by = sortable_columns[at]
	}
	a.rebuild()
}

// sort_by_number selects a column by its position on screen, which is what the
// reader can count. A number past the last visible column does nothing rather
// than sorting by something they cannot see.
fn (mut a App) sort_by_number(n int) {
	columns := visible_columns(a.ctx.window_width)
	if n < 1 || n > columns.len {
		return
	}
	column := columns[n - 1].column
	if column !in sortable_columns {
		return
	}
	a.sort_by = column
	a.rebuild()
}

fn (mut a App) cycle_view(step int) {
	a.view = (a.view + step + probe_views.len) % probe_views.len
	a.rebuild()
}

fn (a App) probe_view() string {
	return probe_views[a.view]
}

fn (mut a App) cycle_profile() {
	names := core.profiles.keys()
	mut at := 0
	for i, name in names {
		if name == a.profile {
			at = i
			break
		}
	}
	a.profile = names[(at + 1) % names.len]
	a.apply_profile()
	a.status = 'profile ${a.profile}, re-ranked from the same samples'
	a.rebuild()
}

// restart measures again from the beginning, keeping the screen until the first
// snapshot of the new run arrives.
fn (mut a App) restart() {
	if a.running {
		a.status = 'still measuring, press a to stop it first'
		a.dirty = true
		return
	}
	a.frames = chan Frame{ cap: 8 }
	a.abort = chan bool{ cap: 1 }
	a.started = time.now()
	a.running = true
	a.status = 'measuring'
	a.dirty = true
	spawn measure(a.opts, a.frames, a.abort)
}

// stop ends the walk and keeps what it has. The partial result is emitted by
// the watcher before the run unwinds, so nothing measured is thrown away.
fn (mut a App) stop() {
	if !a.running {
		return
	}
	a.abort.try_push(true)
	a.status = 'stopping, keeping what was measured'
	a.dirty = true
}

// export_one writes the run in one of the published formats.
//
// The file is named for the moment it was written and lands in the working
// directory, because a full-screen program that silently overwrote a file the
// reader could not see would be a poor guest.
fn (mut a App) export_one(format string) {
	if !a.have {
		a.status = 'nothing measured yet'
		a.dirty = true
		return
	}
	extension := match format {
		'json' { 'json' }
		'csv' { 'csv' }
		else { 'md' }
	}
	body := match format {
		'json' { a.latest.result.to_json() }
		'csv' { a.latest.result.to_csv() }
		else { a.latest.result.to_markdown() }
	}
	t := time.now()
	stamp := '${t.year:04d}${t.month:02d}${t.day:02d}-${t.hour:02d}${t.minute:02d}${t.second:02d}'
	path := 'dnsbench-${stamp}.${extension}'
	os.write_file(path, body) or {
		a.status = 'could not write ${path}: ${err.msg()}'
		a.dirty = true
		return
	}
	a.status = 'wrote ${path}'
	a.dirty = true
}

// ── drawing ──────────────────────────────────────────────────────────────────

// The whole frame is written into term.ui's print buffer and flushed once, so
// the terminal never sees a half-drawn table. That buffer is the double buffer
// docs/TUI.md § Implementation notes asks for.
fn (mut a App) draw() {
	width := a.ctx.window_width
	height := a.ctx.window_height
	if width < 20 || height < 8 {
		a.ctx.clear()
		a.put(1, 1, 'terminal too small', .bad)
		a.ctx.reset()
		a.ctx.flush()
		return
	}

	a.ctx.clear()
	columns := visible_columns(width)
	a.draw_header(width)
	a.draw_column_header(columns)
	a.draw_table(columns, width, height)
	a.draw_footer(width, height)

	match a.mode {
		.detail { a.draw_detail(width, height) }
		.help { a.draw_help(width, height) }
		.filters { a.draw_menu(width, height, 'filters', a.filter_menu_lines()) }
		.export { a.draw_menu(width, height, 'export', a.export_menu_lines()) }
		else {}
	}

	a.ctx.reset()
	a.ctx.set_cursor_position(0, 0)
	a.ctx.flush()
}

fn (mut a App) put(x int, y int, text string, tone Tone) {
	if a.palette.mono {
		a.ctx.draw_text(x, y, text)
		return
	}
	a.ctx.set_color(a.palette.of(tone))
	a.ctx.draw_text(x, y, text)
	a.ctx.reset_color()
}

fn (mut a App) put_color(x int, y int, text string, colour tui.Color) {
	if a.palette.mono {
		a.ctx.draw_text(x, y, text)
		return
	}
	a.ctx.set_color(colour)
	a.ctx.draw_text(x, y, text)
	a.ctx.reset_color()
}

fn (mut a App) draw_header(width int) {
	r := a.latest.result
	asn := if r.network.asn == '' { 'ASN unknown' } else { '${r.network.asn} ${r.network.asn_org}' }
	a.put(1, 1, clip('dnsbench ${tool_version}   ${asn}   ${r.network.ifname}   IPv6: ${yes_no(r.network.ipv6)}   region: ${r.network.region}', width), .plain)
	a.put(1, 2, clip('catalog v${r.datasets.catalog.version} (${r.datasets.catalog.source}, ${r.datasets.catalog.providers})   domains ${r.datasets.domains.warm}   cold: ${r.datasets.domains.cold_mode}   profile: ${a.profile}   view: ${view_label(a.probe_view())}', width), .dim)
	a.draw_progress(3, width)
}

// draw_progress is the one line that moves while the run is happening.
//
// It counts queries rather than rounds because the plan is a flat list of steps
// walked in order, interleaved across providers: the run has no round it is
// currently in, which is exactly what makes every provider comparable.
fn (mut a App) draw_progress(y int, width int) {
	elapsed := elapsed_text(a.started)
	head := if a.running {
		'queries ${a.latest.step}/${a.latest.total}'
	} else {
		'${a.latest.result.results.len} providers'
	}
	tail := '${elapsed} elapsed'

	a.put(1, y, head, .plain)
	bar_x := head.len + 3
	bar_width := width - bar_x - tail.len - 2
	if bar_width > 4 {
		fraction := if a.latest.total > 0 && a.running {
			f64(a.latest.step) / f64(a.latest.total)
		} else {
			1.0
		}
		filled := int(f64(bar_width) * fraction)
		a.put(bar_x, y, '█'.repeat(filled), if a.running { Tone.info } else { Tone.good })
		a.put(bar_x + filled, y, '░'.repeat(bar_width - filled), .dim)
	}
	a.put(width - tail.len, y, tail, .dim)
}

// V's format verbs take a literal width, so a column whose width lives in a
// table pads here instead.
fn pad_left(text string, width int) string {
	if text.len >= width {
		return text
	}
	return ' '.repeat(width - text.len) + text
}

fn pad_right(text string, width int) string {
	if text.len >= width {
		return text
	}
	return text + ' '.repeat(width - text.len)
}

fn view_label(probe string) string {
	return probe.replace('_', '-')
}

fn (mut a App) draw_column_header(columns []ColumnSpec) {
	offsets := column_offsets(columns)
	for i, spec in columns {
		header := if spec.column == .provider || spec.column == .flags {
			pad_right(spec.header, spec.width)
		} else {
			pad_left(spec.header, spec.width)
		}
		a.put(offsets[i], 4, header, .dim)
		if spec.column == a.sort_by {
			// The indicator sits in the gap after the column, so no header ever
			// loses a character to it.
			a.put(offsets[i] + spec.width, 4, if a.descending { '^' } else { 'v' }, .info)
		}
	}
}

// column_offsets is where each column starts, one-based as the terminal counts.
fn column_offsets(columns []ColumnSpec) []int {
	mut out := []int{cap: columns.len}
	mut x := table_indent + 1
	for i, spec in columns {
		if i > 0 {
			x += column_gap
		}
		out << x
		x += spec.width
	}
	return out
}

fn clip(text string, width int) string {
	if text.len <= width {
		return text
	}
	return text[..width]
}

fn yes_no(b bool) string {
	return if b { 'yes' } else { 'no' }
}

// draw_table paints the scrolling area: the ranked block, the tier bands, and
// the sections below the line.
fn (mut a App) draw_table(columns []ColumnSpec, width int, height int) {
	top := 5
	bottom := height - 2
	capacity := bottom - top + 1
	if capacity < 1 {
		return
	}

	a.scroll_to_selection(capacity)

	if a.lines.len == 0 {
		message := if a.have { 'nothing matches the current filter' } else { 'measuring' }
		a.put(table_indent + 1, top, message, .dim)
		return
	}

	offsets := column_offsets(columns)
	bests := view_bests(a.latest.result.results, a.probe_view())
	rule := '-'.repeat(if width > table_indent + 2 {
		table_width(columns) - table_indent
	} else {
		1
	})

	for i in 0 .. capacity {
		index := a.scroll + i
		if index >= a.lines.len {
			break
		}
		y := top + i
		line := a.lines[index]
		match line.kind {
			.band {
				a.put(table_indent + 1, y, rule, .dim)
			}
			.caption {
				a.put(table_indent + 1, y, clip('-- ${line.text} ' + rule, rule.len), .dim)
			}
			.row {
				a.draw_row(a.latest.result.results[line.index], line, columns, offsets, bests, y, width, index == a.selected)
			}
		}
	}
}

// scroll_to_selection keeps the selected row on screen and otherwise leaves the
// view where the reader put it.
fn (mut a App) scroll_to_selection(capacity int) {
	if a.selected < a.scroll {
		a.scroll = a.selected
	}
	if a.selected > a.scroll + capacity - 1 {
		a.scroll = a.selected - capacity + 1
	}
	if a.scroll > a.lines.len - capacity {
		a.scroll = a.lines.len - capacity
	}
	if a.scroll < 0 {
		a.scroll = 0
	}
}

fn (mut a App) draw_row(p store.ProviderResult, line ScreenLine, columns []ColumnSpec, offsets []int, bests ViewBests, y int, width int, selected bool) {
	if selected && !a.palette.mono {
		// Inverted background and nothing else. The figures keep the colours
		// they earned, because the selection is about where the reader is and
		// says nothing about the measurement.
		a.ctx.set_bg_color(r: 60, g: 60, b: 60)
		a.ctx.draw_text(1, y, ' '.repeat(width))
	}

	rank := rank_text(p, line.section)
	for i, spec in columns {
		if spec.column == .flags {
			a.draw_flags(p, offsets[i], y, width)
			continue
		}
		text := cell_text(p, spec.column, a.probe_view(), rank)
		if spec.column == .score && !a.palette.mono && p.ranked.excluded == none {
			a.put_color(offsets[i], y, text, a.palette.gradient_of(score_gradient(p, bests)))
			continue
		}
		a.put(offsets[i], y, text, cell_tone(p, spec.column, a.probe_view(), bests))
	}

	if selected && !a.palette.mono {
		a.ctx.reset_bg_color()
	}
}

// rank_text is the number in the first column. A row below the line carries a
// dot: it was measured and it is not competing.
fn rank_text(p store.ProviderResult, section Section) string {
	if section != .ranked || p.ranked.excluded != none {
		return '  .'
	}
	return '${p.ranked.rank:3d}'
}

fn (mut a App) draw_flags(p store.ProviderResult, x int, y int, width int) {
	mut at := x
	for flag in flags_for(p) {
		if at + flag.text.len > width {
			return
		}
		a.put(at, y, flag.text, flag.tone)
		at += flag.text.len + 1
	}
}

// ── footer and overlays ──────────────────────────────────────────────────────
fn (mut a App) draw_footer(width int, height int) {
	mut left := a.status
	if a.mode == .search {
		left = 'search: ${a.search}_'
	} else if a.search != '' || a.filters.len > 0 {
		mut parts := []string{}
		if a.search != '' {
			parts << 'search "${a.search}"'
		}
		if a.filters.len > 0 {
			parts << 'filters ${a.filters.join(', ')}'
		}
		left = '${a.status}   ${parts.join('   ')}'
	}
	warnings := a.latest.result.warnings.len
	if warnings > 0 {
		left += '   ${warnings} warning${if warnings == 1 { '' } else { 's' }}, ? shows them'
	}
	a.put(1, height - 1, clip(left, width), .dim)

	keys := if a.mode == .detail {
		'[<-] back   [c] write JSON   [q] close'
	} else {
		'[^v] select  [s] sort  [S] reverse  [tab] probe  [p] profile  [f] filter  [/] search  [enter] detail  [e] export  [r] rerun  [a] stop  [?] help  [q] quit'
	}
	a.put(1, height, clip(keys, width), .plain)
}

// draw_box clears a rectangle and frames it. Every overlay is one of these, so
// they cannot drift apart in style.
fn (mut a App) draw_box(x int, y int, w int, h int, title string) {
	labelled := '- ${title} '
	head := if title == '' || labelled.len > w - 2 {
		'-'.repeat(w - 2)
	} else {
		labelled + '-'.repeat(w - 2 - labelled.len)
	}
	a.put(x, y, '+' + head + '+', .dim)
	for row in 1 .. h - 1 {
		a.put(x, y + row, '|' + ' '.repeat(w - 2) + '|', .dim)
	}
	a.put(x, y + h - 1, '+' + '-'.repeat(w - 2) + '+', .dim)
}

// The two detail tables are laid out by hand, so their headers and their rows
// are padded from the same numbers and cannot drift apart.
const probe_table_width = 52

const edge_table_width = 61

// draw_detail is where the argument lands.
//
// dot-fresh printed next to dot-warm teaches the handshake lesson in one
// glance, and the per-host edge table shows exactly which CDN a resolver with
// no ECS mishandles. docs/TUI.md § Detail view.
fn (mut a App) draw_detail(width int, height int) {
	p := a.selected_result() or {
		a.mode = .table
		return
	}

	x := 1
	y := 2
	w := width
	h := height - 2
	a.draw_box(x, y, w, h, p.label)

	mut row := y + 1
	inner := x + 2
	limit := y + h - 2

	row = a.detail_probes(p, inner, row, limit)
	row = a.detail_edge(p, inner, row + 1, limit)
	row = a.detail_subscores(p, inner, row + 1, limit)
	a.detail_tags(p, inner, row + 1, limit, w - 4)
}

fn (mut a App) detail_probes(p store.ProviderResult, x int, top int, limit int) int {
	mut row := top
	a.put(x, row, pad_right('PROBE', 12) + pad_left('n', 5) + pad_left('p50', 7) + pad_left('p95', 7) + pad_left('max', 7) + pad_left('jit', 7) + pad_left('loss', 7), .dim)
	row++
	for probe in p.probes {
		if row > limit {
			return row
		}
		s := probe.stats
		a.put(x, row, pad_right(view_label(probe.name), 12) + pad_left('${s.n}', 5) + pad_left(number_cell(s.p50), 7) + pad_left(number_cell(s.p95), 7) + pad_left(number_cell(s.max), 7) + pad_left(number_cell(s.jitter), 7) + pad_left('${s.loss:.1f}%', 7), .plain)
		if note := probe_note(probe) {
			a.put(x + probe_table_width + 2, row, note, .dim)
		}
		row++
	}
	return row
}

// probe_note is the sentence the number needs beside it. Only three probes have
// one, and each is a fact about what was measured rather than a comment on the
// provider.
fn probe_note(probe store.ProbeReport) ?string {
	return match probe.name {
		'dot_fresh' { 'new handshake per query' }
		'dot_warm' { 'persistent, as a real client holds it' }
		'doh' { 'HTTP/${probe.http_version} only, see docs/ARCHITECTURE.md' }
		'cold' { 'recursion, uncached name' }
		else { none }
	}
}

fn (mut a App) detail_edge(p store.ProviderResult, x int, top int, limit int) int {
	if p.edge.hosts.len == 0 {
		return top
	}
	mut row := top
	a.put(x, row, pad_right('CDN EDGE', 26) + pad_left('resolved', 17) + pad_left('connect', 9) + pad_left('penalty', 9), .dim)
	row++
	for host in p.edge.hosts {
		if row > limit {
			return row
		}
		answer := host.answer or { 'no answer' }
		a.put(x, row, pad_right(host.host, 26) + pad_left(answer, 17) + pad_left(number_cell(host.connect_ms), 9) + pad_left(signed_cell(host.penalty_ms), 9), .plain)
		if host.stale {
			// Stale is not a verdict on the resolver. The host stopped steering by
			// DNS, so no answer to it could carry an ECS decision either way.
			a.put(x + edge_table_width + 2, row, 'stale, excluded', .warn)
		} else if penalty := host.penalty_ms {
			if penalty > core.edge_misrouted_ms {
				a.put(x + edge_table_width + 2, row, 'misrouted', .bad)
			}
		}
		row++
	}
	if row <= limit {
		a.put(x, row, pad_right('', 26) + pad_left('median penalty', 17) + pad_left('', 9) + pad_left(signed_cell(p.edge.median_penalty_ms), 9), .plain)
		a.put(x + edge_table_width + 2, row, '${p.edge.misrouted}/${p.edge.measured} misrouted', .dim)
		row++
	}
	return row
}

fn (mut a App) detail_subscores(p store.ProviderResult, x int, top int, limit int) int {
	if top > limit {
		return top
	}
	s := p.subscores
	a.put(x, top, 'SUBSCORES    latency ${score_text(s.latency)}  recursion ${score_text(s.recursion)}  stability ${score_text(s.stability)}  reliability ${s.reliability:5.1f}', .plain)
	if top + 1 > limit {
		return top + 1
	}
	a.put(x, top + 1, '             edge ${score_text(s.edge)}  encrypted ${score_text(s.encrypted)}  capability ${s.capability:5.1f}  privacy ${s.privacy:5.1f}', .plain)
	if top + 2 > limit {
		return top + 2
	}
	composite := if excluded := p.ranked.excluded {
		'not ranked (${excluded.str()})'
	} else {
		'composite ${p.ranked.score:.1f}'
	}
	a.put(x, top + 2, '             ${composite}', .plain)
	return top + 3
}

fn (mut a App) detail_tags(p store.ProviderResult, x int, top int, limit int, width int) {
	if top > limit {
		return
	}
	mut measured := []string{}
	if v := p.capabilities.dnssec_validating {
		measured << if v { 'validates DNSSEC' } else { 'does not validate DNSSEC' }
	}
	for name, blocked in p.capabilities.filtering {
		measured << if blocked { 'blocks ${name}' } else { 'resolves ${name}' }
	}
	measured << 'transports ${p.capabilities.transports.join(', ')}'
	a.put(x, top, clip('measured: ${measured.join(' | ')}', width), .plain)

	if top + 1 <= limit && p.declared.len > 0 {
		// Dim, and on its own line. A claim by the provider is never printed in
		// the same style as something a probe established.
		a.put(x, top + 1, clip('declared: ~${p.declared.join(' ~')}', width), .dim)
	}
}

fn score_text(v ?f64) string {
	value := v or { return '  n/a' }
	return '${value:5.1f}'
}

// draw_help is the key list and, below it, whatever the run has to say for
// itself. The warnings live here because the table has one status line and a
// run on a bad link can produce several.
fn (mut a App) draw_help(width int, height int) {
	mut lines := [
		'[up] [down] [k] [j]      move the selection',
		'[PgUp] [PgDn] [Home] [End]  scroll',
		'[s] cycle the sort column   [S] reverse it   [1]-[9] sort by column number',
		'[tab] cycle which probe fills p50, p95, JIT and LOSS',
		'[p] cycle the weight profile: the table re-ranks, nothing is measured again',
		'[f] filter menu   [/] search by name   [enter] detail   [e] export',
		'[r] measure again   [a] stop and keep what was measured   [q] quit',
		'',
		'+ and - badges were measured this run. ~ is declared by the provider.',
		'EDGE is the median penalty in ms against the best edge any resolver reached.',
		'MIS counts the CDN hosts that came back far enough adrift to be misrouted.',
	]
	if a.latest.result.warnings.len > 0 {
		lines << ''
		lines << 'warnings'
		for w in a.latest.result.warnings {
			lines << '  ${w.level}: ${w.message}'
		}
	}

	w := if width - 6 < 96 { width - 6 } else { 96 }
	h := if lines.len + 4 < height - 4 { lines.len + 4 } else { height - 4 }
	x := (width - w) / 2
	y := (height - h) / 2
	a.draw_box(x, y, w, h, 'keys')
	for i, line in lines {
		if y + 2 + i >= y + h - 1 {
			break
		}
		a.put(x + 2, y + 2 + i, clip(line, w - 4), .plain)
	}
}

fn (mut a App) draw_menu(width int, height int, title string, lines []string) {
	w := if width - 6 < 60 { width - 6 } else { 60 }
	h := lines.len + 4
	x := (width - w) / 2
	y := (height - h) / 2
	a.draw_box(x, y, w, h, title)
	for i, line in lines {
		a.put(x + 2, y + 2 + i, clip(line, w - 4), .plain)
	}
}

// filter_menu_lines says which half of the output each filter reads from. A
// filter on a declared tag and a filter on a probe result answer different
// questions, and the menu is where the reader is told which one they are about
// to ask.
fn (a App) filter_menu_lines() []string {
	mut out := []string{cap: filters_available.len + 2}
	for i, filter in filters_available {
		mark := if filter.name in a.filters { 'x' } else { ' ' }
		source := if filter.measured { 'measured' } else { 'declared' }
		out << '[${i + 1}] [${mark}] ${pad_right(filter.name, 14)} ${pad_right(filter.label, 24)} ${source}'
	}
	out << ''
	out << '[c] clear   [esc] close'
	return out
}

fn (a App) export_menu_lines() []string {
	return [
		'[j] JSON, the contract schema/result.schema.json covers',
		'[c] CSV, one row per provider and probe',
		'[m] Markdown, for pasting into an issue',
		'',
		'written to the working directory   [esc] close',
	]
}
