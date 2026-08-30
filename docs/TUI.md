# TUI design

Built on V's stdlib `term.ui`. No layout engine — coordinates are computed. That is fine for
a table; it is why we are not attempting a GUI.

## Screen budget

Minimum supported terminal: **80 × 24**. Target: 100 × 30. The layout degrades by dropping
columns from the right in a fixed order, never by wrapping or truncating the score.

```
3 rows   header: network fingerprint, run metadata, active profile and probe view,
         then the progress bar and the elapsed clock
1 row    column headers, sort indicator
N rows   ranked table with tier bands, then the blocks below the line:
         what was measured but not ranked, then the local caches   (scrolls)
1 row    status: what the run is doing, the active filters, the warning count
1 row    keybindings
```

The blocks below the line are part of the same scrolling area rather than a fixed section, so
a run with nine local resolvers and one ranked provider is as readable as the other way round.

## Main screen

A real run, at 110 columns, captured through a pty:

```sh
dnsbench --tui --only cloudflare,quad9,google,adguard,opendns,controld-unfiltered \
         --probes warm,cold,ecs,dot-warm,dnssec,filter \
         --cold-zone probe.dnsbench.esli.blog --rounds 5
```

```
dnsbench 0.1.0   ASN unknown   wlp3s0   IPv6: yes   region: global
catalog v7 (embedded, 16)   domains builtin:top8   cold: own   profile: balanced   view: warm
6 providers  ████████████████████████████████████████████████████████████████████  05:30 elapsed
    #v PROVIDER            SCORE    p50    p95    JIT   LOSS    EDGE    MIS    DoT  FLAGS
    1  AdGuard              78.0    8.5   21.2    6.4   0.0%    +3.5  0/8      8.3  +ads ~nolog
    1  Quad9                77.2    8.9   13.2   15.3   0.0%    +1.1  0/9     10.1  +DNSSEC -ads ~nolog
    1  Cloudflare           76.0    9.7   44.2   15.1  20.0%    +0.3  0/9      9.6  +DNSSEC -ads ~nolog
    1  Google               68.9   10.6   39.3   29.9   0.0%    +2.5  0/9     11.4  +DNSSEC -ads ~nofilter
  --------------------------------------------------------------------------------------------
    5  Control D (unfilt~   34.1   58.0   66.5    3.8   0.0%   +57.5  9/9        -  -DNSSEC -ads ~nolog
  -- not ranked ------------------------------------------------------------------------------
    .  OpenDNS                 -    9.3   59.2   17.1  40.0%    +2.5  0/9        -

run complete
[^v] select  [s] sort  [S] reverse  [tab] probe  [p] profile  [f] filter  [/] search  [enter] detail
```

### Reading the example

Four things are visible at a glance that no other tool shows:

- **Control D scores 34 with a `+57.5` edge penalty and 9 of 9 hosts misrouted.** Every CDN
  host it was asked about came back far enough adrift to have been answered from the wrong
  region. That is the headline finding of the whole project, legible in one row.
- **OpenDNS sits below the line with no score.** 40 % loss put it under the thirty-sample
  floor, so it is shown with its numbers and excluded from the ranking rather than dropped.
- **AdGuard carries `+ads` and no DNSSEC badge at all.** The filtering probe caught it
  blocking; the DNSSEC probe could not decide, because its fleet does not answer that question
  consistently, and an undecided capability earns no badge rather than a failing one.
- **The top four share tier 1.** Their bootstrap intervals on the score overlap, so the tool
  declines to order them and says so with a band rather than with four different ranks.

## Colour semantics

Colour carries meaning; it is never decorative. Every colour cue is duplicated by a glyph or a
number so the table is fully readable in monochrome.

| Element | Rule |
|---|---|
| `SCORE` | Continuous gradient green → yellow → red across the run's observed range |
| `p50`, `p95`, `DoT` | Green within 1.25× of run best; yellow to 2×; red beyond |
| `JIT` | Green < 5 ms; yellow 5–15; red > 15 |
| `LOSS` | Green 0 %; yellow ≤ 5 %; red > 5 % |
| `EDGE` | Green ≤ +5 ms; yellow ≤ +25; **red beyond** — this column deserves alarm |
| `+DNSSEC` / `-DNSSEC` | DNSSEC validation, measured this run: green / red |
| `+ads` / `-ads` | Filtering, measured this run: blue, neutral. Blocking is a preference, not a virtue |
| `~` | Declared, unverified: dim, never coloured as if measured |
| Tier bands | Dim horizontal rule; rows in the same band share a tier |
| Selected row | Inverted background, no colour change to the data |

The badge spellings are the CLI table's, settled in M2. A `+` or a `-` was established by a
probe during this run and is allowed to contradict the `~` tag beside it; that contradiction
is the point of measuring, so the two must never be printed in the same style.

A capability the probe could not decide has no badge at all. Absent is not false: printing a
provider whose fleet answered inconsistently as failing would be inventing a result.

### Accessibility

- `NO_COLOR` environment variable and `--no-color` are honoured.
- Default palette avoids red/green as the sole distinction: score is also positional (sorted),
  loss is also numeric, edge is also numeric.
- `--palette colorblind` swaps green/red for blue/orange, the one swap that covers
  deuteranopia and protanopia together.
- Colours are named once, as RGB, and `term.ui` renders them as truecolor, 8-bit or the basic
  16 according to what the terminal reports. Under `TERM=linux` that is the 16-colour set.
- `--no-color` and `NO_COLOR` drop every escape sequence, the selected row's background
  included, so the screen is plain text.

## Column priority under narrow terminals

Dropped right-to-left as width shrinks. The number is the narrowest terminal that still shows
the row:

```
102  # PROVIDER SCORE p50 p95 JIT LOSS EDGE MIS DoT FLAGS
 82  # PROVIDER SCORE p50 p95 JIT LOSS EDGE MIS DoT
 75  # PROVIDER SCORE p50 p95 JIT LOSS EDGE MIS
 68  # PROVIDER SCORE p50 p95 JIT LOSS EDGE
 61  # PROVIDER SCORE p50 p95 LOSS EDGE
 54  # PROVIDER SCORE p50 LOSS EDGE
 47  # PROVIDER SCORE p50 EDGE
```

`EDGE` never drops. It is the reason the tool exists, and a build that hid it on an 80-column
terminal would be hiding its own finding. `FLAGS` and `DoT` go first because the detail view
carries both.

`MIS` is the misrouted count, added after this document was first written and after the CLI
table grew the same column: how many CDN hosts came back far enough adrift to have been sent
to the wrong region, out of how many were measured. It informs and does not rank, so it drops
early.

## Detail view (`enter`)

The same run, on the selected row:

```
+- AdGuard --------------------------------------------------------------------------------+
| PROBE           n    p50    p95    max    jit   loss                                     |
| warm           40    8.5   21.2   35.3    6.4   0.0%                                     |
| cold           40   11.4   16.1   25.4    3.7   0.0%  recursion, uncached name           |
| dot-warm       40    8.3   13.7   14.5    3.0   0.0%  persistent, as a real client holds |
|                                                                                          |
| CDN EDGE                           resolved  connect  penalty                            |
| www.microsoft.com                2.20.130.2     14.1     +3.5                            |
| www.apple.com                  23.10.52.235      8.8     +2.7                            |
| assets.msn.com                  2.18.248.10      9.5     +3.9                            |
| www.fastly.com               151.101.249.57     11.4     +5.3                            |
| deb.debian.org                    no answer        -        -                            |
| d1.awsstatic.com                18.67.145.2     11.3     +4.3                            |
| download.docker.com           13.227.110.88      6.7     +0.0                            |
| dl.google.com                172.217.29.142      6.0     +0.3                            |
| www.gstatic.com             142.250.219.131     12.6     +6.0                            |
|                              median penalty              +3.5  0/8 misrouted             |
|                                                                                          |
| SUBSCORES    latency 100.0  recursion 100.0  stability  60.9  reliability 100.0          |
|              edge  61.6  encrypted 100.0  capability  30.0  privacy  40.0                |
|              composite 78.0                                                              |
|                                                                                          |
| measured: blocks ads | transports udp, tcp, dot                                          |
| declared: ~nolog                                                                         |
+------------------------------------------------------------------------------------------+
[<-] back   [c] write JSON   [q] close
```

The detail view is where the argument lands. `dot-fresh` printed next to `dot-warm` teaches
the handshake lesson in one glance, and the per-host edge table shows exactly which CDN a
resolver with no ECS mishandles: run it against Control D and every one of the nine rows
carries a penalty, which is what the `9/9` in the table meant.

A host that answered nothing takes no penalty and is not counted as measured. A provider that
resolves fewer hosts is flagged, never favoured.

Only the probes that ran are listed. Nothing is invented for a probe that was not asked for.

## Keybindings

| Key | Action |
|---|---|
| `↑` `↓` `k` `j` | Move selection |
| `PgUp` `PgDn` `Home` `End` | Scroll |
| `s` | Cycle sort column; `S` reverses the direction |
| `1` to `9` | Sort by the Nth column currently on screen |
| `Tab` | Cycle which probe fills `p50`, `p95`, `JIT` and `LOSS`: warm, cold, tcp, dot-warm, dot-fresh, doh |
| `p` | Cycle weight profile — table re-ranks live, no re-measurement |
| `f` | Filter menu (`dnssec`, `no-filtering`, `ipv6`, `nolog`, `nofilter`), which says of each whether it reads a measurement or a claim |
| `/` | Incremental search by provider name |
| `Enter` | Detail view |
| `e` | Export menu (json / csv / markdown), written to the working directory |
| `r` | Re-run |
| `a` | Abort current run, keep partial results |
| `?` | Help overlay, which is also where the run's warnings are listed |
| `q` `Esc` | Quit; inside an overlay, close it |

`p` re-ranking without re-measuring is a deliberate feature: it lets a user see how much the
answer depends on the weights, which is the honest way to present a composite score.

## Live behaviour

Every provider has a row from the first frame, carrying a dash in every column it has no
figure for, so the table does not jump as results arrive. A dash and not a zero, and not a
`····` placeholder either: the dash is what every other output format in this tool prints for
something it did not measure, and one glyph for one meaning is worth more than a prettier one.

Since rounds are interleaved, every provider's numbers improve in precision together rather
than one row completing at a time. Confidence widens and narrows visibly; when a tier boundary
becomes statistically real, the band appears.

Rows move between blocks while the run is young. A provider below the thirty-sample floor of
`docs/SCORING.md` sits under `not ranked` with its numbers visible, and joins the ranking when
it clears the floor. That is the exclusion doing its job in public rather than a row appearing
from nowhere at the end.

The progress line counts queries, not rounds. The plan is a flat list of steps walked in order
and interleaved across providers, so the run is never in a round: it is some way through a
list, which is what the bar shows.

Frame rate 15 fps, redraw only on state change, and the elapsed clock counts as a change once
a second. A benchmark that burns CPU redrawing is perturbing its own measurement.

## Implementation notes

`term.ui` gives `draw_text`, `draw_rect`, RGB colours, and `event_fn` / `frame_fn` callbacks.
No widgets, no layout. Therefore:

- Column x-offsets are computed from one table of widths and drop orders, recalculated from
  `ctx.window_width` on every frame, so the initial width is never assumed and `SIGWINCH`
  needs nothing but a redraw.
- `term.ui` accumulates every write into its own print buffer and emits it in one `write`, so
  that buffer is the double buffer and a second one in `[]string` would only copy it.
- The table model is a plain list of indices plus a sort key: sorting re-sorts indices and
  never re-measures. So does `p`: it re-ranks the samples already taken under a different set
  of weights.
- The run happens on its own thread and reaches the frame loop as finished snapshots down a
  channel, one about every 700 ms. Nothing is shared between the two threads but the two
  channels, so the samples are never read while they are being appended to.
- Live snapshots use a smaller bootstrap than the published one. The interval is redrawn every
  second and is allowed to be coarser than the one that ends up in the JSON.
- `term.ui` installs its own handlers for the signals named in its `reset` list, and SIGPIPE is
  deliberately left out of the list passed to it: `main` ignores that signal because a DoT
  server may close an idle connection mid-run, and letting the handler back in would put the
  kill back.

## Falling back

`term.ui` panics rather than returning an error when stdin or stdout is not a terminal, so the
check happens before it is given the chance. Three conditions send a `--tui` run to the plain
table, each naming itself on stderr first:

- `TERM` is unset,
- `TERM` is `dumb`,
- stdin or stdout is not a TTY, which is what a piped or redirected run looks like.

Under `TERM=linux` the interface runs, and `term.ui` renders every colour through the basic
16-colour set on its own.
