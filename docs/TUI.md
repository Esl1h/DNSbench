# TUI design

Built on V's stdlib `term.ui`. No layout engine — coordinates are computed. That is fine for
a table; it is why we are not attempting a GUI.

## Screen budget

Minimum supported terminal: **80 × 24**. Target: 100 × 30. The layout degrades by dropping
columns from the right in a fixed order, never by wrapping or truncating the score.

```
┌ 3 rows ─ header: network fingerprint, run metadata, active profile
├ 1 row  ─ column headers, sort indicator
├ N rows ─ ranked table with tier bands   (scrolls)
├ 2 rows ─ local / cache section, visually separated
├ 1 row  ─ progress bar during the run
└ 1 row  ─ keybindings
```

## Main screen

```
╭────────────────────────────────────────────────────────────────────────────────────────────╮
│ dnsbench 0.1.0   AS27699 Telefonica Brasil   wlan0   IPv6: no   region: SA                 │
│ catalog v3 (embedded, 16)   domains tranco:K2XVW+sa   cold: own   profile: balanced        │
│ round 4/5   ████████████████████████████████████░░░░░░░░   1,247 queries   00:47 elapsed   │
╰────────────────────────────────────────────────────────────────────────────────────────────╯

  #  PROVIDER              SCORE   p50↓    p95   JIT   LOSS    EDGE   DoT   FLAGS
 ─────────────────────────────────────────────────────────────────────────────────────────────
  1  nextdns                92.4   15.0   24.8   3.1   0.0%   +3.9   17.0   ✓DNSSEC ~nolog
  1  cloudflare             91.7   14.2   21.7   2.4   0.0%   +0.0   16.1   ✓DNSSEC ~nolog
 ─────────────────────────────────────────────────────────────────────────────────────────────
  3  gateway 192.168.0.1    81.2   14.8   22.1   2.9   0.0%   +6.2      —   ✗DNSSEC
  4  google                 78.9   18.0   33.6   5.2   0.0%   +1.1   19.4   ✓DNSSEC
  5  adguard                74.1   19.6   28.9   4.8   0.0%   +8.7   21.2   ✓DNSSEC ~nolog ⊘ads
 ─────────────────────────────────────────────────────────────────────────────────────────────
  6  mullvad-base           61.3   38.2   52.1   9.4   0.0%  +41.0   40.1   ✓DNSSEC ~nolog ~audited
  7  quad9-ecs              58.7   16.9   68.1  14.2  22.9%  +11.4   18.3   ✓DNSSEC ~nolog ⚠
  8  quad9                  41.2   16.4   61.0  13.1   0.0%  +97.2   17.8   ✓DNSSEC ~nolog
  9  dns4eu                 22.8  184.3  221.0  18.7   2.9%  +88.1  198.0   ✓DNSSEC

 ── local resolvers (cache — not comparable in warm) ─────────────────────────────────────────
  ·  system stub 127.0.0.53   —     0.3    0.6   0.1   0.0%      —      —   cold: 31.0
  ·  └ upstream 189.46.44.1   —    12.4   19.8   2.7   0.0%   +2.2      —

 ⚠ quad9-ecs: 27/35 TLS handshakes completed (22.9% loss) — possible MTU/CGNAT issue
 ~ declared by provider, not measured

 [↑↓] select  [s] sort  [tab] probe  [p] profile  [f] filter  [enter] detail  [e] export  [q] quit
```

### Reading the example

Three things are visible at a glance that no other tool shows:

- **`quad9` scores 41 despite a 16.4 ms p50.** The `+97.2` edge penalty is why. That is the
  headline finding of the whole project, legible in one row.
- **`quad9-ecs` carries a 22.9 % loss warning.** Handshakes failing on this network.
- **The local stub sits below the line with no score.** Its 0.3 ms is a cache hit and does not
  compete; its cold time (31.0 ms) does, and is shown.

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
| `✓ / ✗` | DNSSEC validation: green / red |
| `⊘` | Filtering active: blue, neutral — blocking is a preference, not a virtue |
| `~` | Declared, unverified: dim, never coloured as if measured |
| `⚠` | Anomaly, warning colour, always paired with a footer line explaining it |
| Tier bands | Dim horizontal rule; same-rank rows share a band |
| Selected row | Inverted background, no colour change to the data |

### Accessibility

- `NO_COLOR` environment variable and `--no-color` are honoured.
- Default palette avoids red/green as the sole distinction: score is also positional (sorted),
  loss is also numeric, edge is also numeric.
- `--palette colorblind` swaps green/red for blue/orange.
- Every colour is 8-bit ANSI with a 16-colour fallback for `TERM=linux`.

## Column priority under narrow terminals

Dropped right-to-left as width shrinks:

```
100+  # PROVIDER SCORE p50 p95 JIT LOSS EDGE DoT FLAGS
 90   # PROVIDER SCORE p50 p95 JIT LOSS EDGE DoT
 80   # PROVIDER SCORE p50 p95 JIT LOSS EDGE
 70   # PROVIDER SCORE p50 p95 LOSS EDGE
```

`EDGE` never drops. It is the reason the tool exists. `FLAGS` and `DoT` go first because they
are available in the detail view.

## Detail view (`enter`)

```
╭─ quad9 ────────────────────────────────────────────────────────────────────────╮
│                                                                                │
│  PROBE          n    p50    p95    max    jit   loss                           │
│  warm          40   16.4   61.0   72.1   13.1    0%                            │
│  cold          40   29.8   48.2   55.0    8.4    0%                            │
│  tcp           40   17.1   28.0   31.2    4.2    0%                            │
│  dot-fresh     40  101.9  124.4  134.2   11.8    0%   ← new handshake per query │
│  dot-warm      40   17.8   26.1   29.9    3.9    0%   ← persistent, real-world  │
│  doh (h1.1)    40   99.1  117.7  129.6   10.2    0%   ⚠ h1.1 only, see docs     │
│                                                                                │
│  CDN EDGE                    resolved      connect    penalty                   │
│  www.microsoft.com     23.55.xxx.xxx        108.4 ms   +97.2  ⚠ Akamai US       │
│  s.glbimg.com         186.192.xxx.xxx        14.1 ms    +2.3                    │
│  assets.nflxext.com    45.57.xxx.xxx         96.7 ms   +84.9  ⚠                 │
│  cdn.jsdelivr.net     104.16.xxx.xxx         13.0 ms    +0.8                    │
│                                            median penalty  +91.1                │
│                                                                                │
│  SUBSCORES     latency 86.6  recursion 93.9  stability 34.1  reliability 100.0 │
│                edge 10.9  encrypted 90.4  capability 90.0  privacy 70.0        │
│                                                             composite  41.2    │
│                                                                                │
│  Switzerland · non-profit · https://quad9.net                                  │
│  ~nolog ~nofilter · malware blocking · no ECS (by design — see docs/METHODOLOGY)│
│                                                                                │
│  [←] back   [c] copy JSON   [w] why this score                                 │
╰────────────────────────────────────────────────────────────────────────────────╯
```

The detail view is where the argument lands: `dot-fresh 101.9` next to `dot-warm 17.8` teaches
the handshake lesson in one glance, and the per-host edge table shows exactly which CDN a
no-ECS resolver mishandles.

## Keybindings

| Key | Action |
|---|---|
| `↑` `↓` `k` `j` | Move selection |
| `PgUp` `PgDn` `Home` `End` | Scroll |
| `s` | Cycle sort column; `S` reverses |
| `1`–`9` | Sort by column N directly |
| `Tab` `Shift+Tab` | Cycle probe view (score / warm / cold / dot / doh / ecs) |
| `p` | Cycle weight profile — table re-ranks live, no re-measurement |
| `f` | Filter menu (`nolog`, `dnssec`, `nofilter`, `no-filtering`, `ipv6`) |
| `/` | Incremental search by provider name |
| `Enter` | Detail view |
| `e` | Export menu (json / csv / markdown / clipboard) |
| `r` | Re-run |
| `a` | Abort current run, keep partial results |
| `?` | Help overlay |
| `q` `Esc` | Quit |

`p` re-ranking without re-measuring is a deliberate feature: it lets a user see how much the
answer depends on the weights, which is the honest way to present a composite score.

## Live behaviour

The table renders from the first result and updates as the scheduler emits. Rows not yet
measured show `····` rather than being absent, so the table does not jump.

Since rounds are interleaved, every provider's numbers improve in precision together rather
than one row completing at a time. Confidence widens and narrows visibly; when a tier boundary
becomes statistically real, the band appears.

Frame rate 15 fps, redraw only on state change. A benchmark that burns CPU redrawing is
perturbing its own measurement.

## Implementation notes

`term.ui` gives `draw_text`, `draw_rect`, RGB colours, and `event_fn` / `frame_fn` callbacks.
No widgets, no layout. Therefore:

- Keep an explicit `Layout` struct with computed column x-offsets, recalculated on resize.
- Double-buffer by building the frame into a `[]string` then flushing, to avoid tearing.
- The table model is a plain `[]Row` plus a sort comparator — sorting is a re-sort of indices,
  never a re-measurement.
- Handle `SIGWINCH` and recompute the layout; do not assume the initial width.
- Verify the binary still builds and runs when `TERM` is unset or `dumb`; fall back to CLI.
