# Scenario and performance report

Run date: 2026-09-07. Renderer tested: commit `4c368dc`, unchanged by this task.
Environment: Emacs 31.0.91, macOS 27.0 (26A5388g), Apple M4 Max, 128 GiB RAM.
Both `default` and `fixed-pitch` were set to Iosevka, height 150. TextUI 0.8.0
was loaded from `../textui`. No renderer fixes were made.

## Fixtures and artifacts

| File | Coverage |
| --- | --- |
| `mixed-scripts.org` | CJK/Latin within cells, full-width punctuation, ZWJ emoji, flags, combining marks, Thai/Arabic, a long URL, whitespace-only cells |
| `inline-markup.org` | Emphasis, literals, described/bare links, footnotes, timestamps, LaTeX, sub/superscripts, entities, title macro |
| `alignment-cookies.org` | Left/center/right and width cookies, numeric columns, empty/dash cells |
| `groups-and-rules.org` | Outer/duplicate rules, column-group metadata, one column, one row, 30 columns |
| `formulas.org` | Names, captions, ATTR_ORG, stale and recalculated `;%.2f` invoice copies |
| `narrow-window.org` | Wrapping paragraphs, oversized token, 12 columns; 60/80/120-column and 700/1400px runs |
| `adjacent-and-nested.org` | Adjacent tables, immediate following paragraph, folding, quote/example blocks, table.el, non-table pipe text, list indentation |
| `editing.org` | Commented reveal/edit/TAB/RET/recalculate/move-column/leave/undo flow |
| `large.org` | Generated 500 data rows × 8 columns, plus header and separator |
| `huge.org` | Generated 3000 data rows × 6 columns, plus header and separator; **ignored, not committed** |

`gen-large.el` deterministically generates both large fixtures. About one row
in 47 contains a long mixed-script cell. `bench.el` and `visual-check.el` are
standalone GUI harnesses. Evidence is in [bench.log](bench.log),
[visual.log](visual.log), [ert.log](ert.log), and
[huge-cpu-profile.sexp](huge-cpu-profile.sexp).

Screenshots are under ignored `shots/`: 14 file/width captures plus explicit
folded and unfolded captures. **No screenshot was opened or inspected.**
The conclusions below come from ERT, text properties, GUI pixel measurements,
and redisplay hit-testing, not image interpretation.

## Automated results

**33 ERT tests: 31 passed, 2 failed.** All original 22 tests pass. Nine
fixture-wide tests check successful enable, unchanged text, nil modified
flag, identical undo list, one overlay at each independently discovered Org
table, and the requested raw source-row/rendered-line count inequality.
Two additional tests cover actual formula recalculation and column groups.

Failures are deliberately not marked as expected failures:

1. `org-table-widget-demo-column-groups-are-metadata`: the second table in
   `groups-and-rules.org` reports two header rows instead of one. The `/`
   column-group declaration is parsed as an ordinary header row.
2. `org-table-widget-demo-groups-and-rules`: table 1 has eight source lines
   but seven rendered lines. Collapsing duplicate/outer rules is intentional
   and already covered by a passing original test. Thus the requested raw
   line-count invariant conflicts with the renderer's documented behavior;
   this failure does **not** indicate missing data rows.

The independent table oracle uses Org's `:post-affiliated` position rather
than `:begin`, so names/captions are not mistaken for table source. Example
blocks and table.el were skipped correctly. The nested fixture produced six
widgets. Formula recalculation via `org-ctrl-c-ctrl-c` produced 3.75 and 9.00,
matching the precomputed copy.

The new Lisp harnesses/tests byte-compile with warnings treated as errors;
checkdoc reports no warnings. Generated `.elc` files were removed.

## GUI performance

Times below are **seconds**; bold values exceed one second. One measured
run per operation, not a distribution or a cross-machine benchmark. The
normal source `.el` was loaded, not an optimized byte-compiled variant.
`gc-cons-threshold` remained the `-Q` default, 800,000 bytes. TextUI was
preloaded; font fallback/loading costs may still affect early GUI timings.

| Fixture / mode | Cold enable¹ | Warm refresh¹ | Resize² | Enter hook | Leave hook | Redisplay ×5 total | Scroll ×20 total | Live Lisp Δ MiB | Overlays |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500×8 / OFF | 0.006366 | 0.006246 | 0.327321 | 0 | 0 | 0.089224 | 0.008281 | 0.087 | 0 |
| 500×8 / ON | **1.504271** | **1.110483** | **1.387398** | 0.000006 | **1.408740** | 0.010174 | 0.046475 | 9.619 | 1 |
| 3000×6 / OFF | 0.029897 | 0.031206 | 0.008179 | 0.000001 | 0.000001 | 0.001364 | 0.008877 | 0.507 | 0 |
| 3000×6 / ON | **5.186418** | **3.804247** | **4.647830** | 0.000008 | **5.225516** | 0.876111 | 0.025868 | 23.550 | 1 |

¹ OFF has no widget enable/refresh operation: its comparison is
`font-lock-ensure`, not an allegedly equivalent widget layout. ON cold
measures enabling the mode with empty per-buffer caches; ON warm calls
`org-table-widget-refresh`. Point is explicitly reset outside the table.
The log confirms one table and one overlay after cold/warm/resize/leave.

² Initial frame sizing requests 1400×800 pixels; resize requests 1100×800.
Logged text-body widths were 1400 and 1100 pixels. The ON timing is the
explicit `org-table-widget--run-relayout` call after resizing; the OFF
timing is `redisplay`. Neither includes the frame-size setter itself. The
idle debounce timer is deferred/cancelled so it does not add extra runs.

Enter/leave timings are the requested post-command callback durations;
point movement occurs just before timing. OFF's widget callbacks are no-ops.
Redisplay is exactly `(benchmark-run 5 (redisplay t))`. Scrolling is 20
`scroll-up-command` calls from the top, without adding redisplay or
post-command hooks to each iteration. At end-of-buffer the harness counts
and catches that condition: six such calls occurred in 500×8 OFF, none in
the other three cases. These are command costs, not smooth-scroll FPS.

Memory is the sum of live object counts × reported object sizes from
`garbage-collect`, after minus before enabling/fontification. It is **not
RSS** and excludes some native/font/display allocations. Full GC rows,
GC counts, and GC time are retained in `bench.log`.

**Typing responsiveness:** reveal itself is cheap, but restoring the widget
on leaving the table synchronously occupies the command loop for 1.41 or
5.23 seconds. Refresh and resize also block for seconds. These durations
are enough to flag noticeable input stalls without claiming a human typing
latency study. Huge-table redisplay totals 0.876 seconds across five calls;
that total does not establish the maximum individual frame time.

## CPU profiler: huge cold layout

A separate cold huge-table enable was sampled with `profiler-start 'cpu`,
then stopped, shown through `profiler-report`, and serialized. It is separate
from the unprofiled timings above. Top ten **exclusive/self** frames, 1618
total sample-weight units:

| Rank | Frame | Weight | Share |
| --- | --- | ---: | ---: |
| 1 | Automatic GC | 847 | 52.35% |
| 2 | `prin1-to-string` | 315 | 19.47% |
| 3 | `window-text-pixel-size` | 117 | 7.23% |
| 4 | `concat` | 45 | 2.78% |
| 5 | `mapconcat` | 33 | 2.04% |
| 6 | `substring` | 32 | 1.98% |
| 7 | `let*` | 22 | 1.36% |
| 8 | `let` | 22 | 1.36% |
| 9 | `aref` | 10 | 0.62% |
| 10 | `puthash` | 9 | 0.56% |

The inclusive ranking is also logged; `org-table-widget--measure-string`
appears in 33.44% of the sample weight. Inclusive shares overlap and must
not be added. Interpreted forms appear as frames because source was loaded.
The main evidence-backed hypothesis is allocation pressure from rendering
and stringifying propertized strings into cache keys. GC dominates; pixel
measurement is significant, but it is not the largest exclusive cost.

## Pixel geometry and display checks

**36 table/size checks; zero right-border mismatches; four width-check
failures.** Each table's top, header (when present), first data, last data,
and bottom right-border x values matched. All logical rendered lines were
also measured, including off-screen rows of `large.org`.

Measurement method: keep each rendered line's properties intact, attach it
as an overlay `before-string` with `display ""` in a temporary GUI buffer,
and use `window-text-pixel-size` with a large x limit. Measure the prefix
before the last border glyph for its x advance. The measurement window has
the same font/body width. This tests the real before-string pixel mechanism
without inserting the rendered string as source text. It measures logical
line geometry, **not** every glyph's location in the original scrolling
viewport. The separate fold probe uses actual `posn-at-x-y` hit-testing.

At 1400px, common right-border x by table (all sampled row types agree):

| File | Table indices → x pixels |
| --- | --- |
| adjacent-and-nested | 1→128, 2→136, 3→168, 4→208, 5→136, 6→152 |
| alignment-cookies | 1→584, 2→216, 3→464 |
| editing | 1→264 |
| formulas | 1→240, 2→240 |
| groups-and-rules | 1→64, 2→192, 3→112, 4→176, 5→1440 |
| inline-markup | 1→624 |
| large | 1→1392 |
| mixed-scripts | 1→1392 |
| narrow-window | 1→992, 2→1392, 3→948 |

At 700px, mixed-scripts has x=688; narrow-window tables 1/2 have x=688
and table 3 has x=696. Exact 60/80/120-column body sizes were verified as
480/640/960 pixels. Full per-table values and every line width are in
`visual.log`.

Width failures (border glyph itself must also fit):

| File / table | Body width | Rendered width | Overflow |
| --- | ---: | ---: | ---: |
| groups-and-rules / 5 | 1400 | 1448 | 48 |
| narrow-window / 3 | 700 | 704 | 4 |
| narrow-window / 3 | 480 (60 columns) | 704 | 224 |
| narrow-window / 3 | 640 (80 columns) | 704 | 64 |

Other checks:

- The long URL, very long token, mixed-script/emoji rows, and whitespace-only
  cells passed the measured border/width checks at the tested widths.
- The described link's entire propertized source measures **136px**, exactly
  the description-only width: hidden brackets/target do not consume width.
- Bold, italic, underline, strike, verbatim/code, footnote, and timestamp
  faces survive into parsed cells; the property dumps are logged.
- Explicitly folding nested table 4 yielded `source-invisible=2` and no
  rendered-string hit in the visible viewport; unfolding restored the six
  widgets. The startup property alone was not relied on for this check.

## BUGS FOUND

1. **Column-group metadata is rendered as content — `groups-and-rules.org`,
   table 2, source line 13.** `/`, `<`, and `>` become an extra header row
   (`:header-rows` is 2 rather than 1). Hypothesis: the parser recognizes
   alignment-cookie rows but not Org's slash-prefixed group declaration.
2. **Synchronous layout causes multi-second input stalls — `large.org` and
   `huge.org`, table 1.** Warm refresh/resize/leave exceed one second on both;
   huge leave takes 5.23 seconds. Hypothesis: rebuilding the full widget and
   serializing propertized cache keys creates substantial allocation/GC
   pressure, consistent with the CPU profile.
3. **Fit-to-window invariant fails for many columns — `groups-and-rules.org`
   table 5 and `narrow-window.org` table 3.** The four overflows above occur
   despite wrapping being enabled. Hypothesis: when total column minimums
   exceed available width, the allocator returns those minimums with no
   alternative presentation. This is a user-visible fit failure arising
   from a deliberate minimum-width policy, not a border-alignment regression.

No changes to `org-table-widget.el` were made to address these findings.

## Limitations noted

- Width cookies `<10>`/`<20>` do not constrain rendered widths. Explicit
  `<l>`/`<c>`/`<r>` alignment cookies are honored.
- Without explicit cookies, numeric columns remain left-aligned in the
  widget even when Org's text editor auto-right-aligns them. The renderer
  currently defaults unspecified alignments to left; use `<r>` explicitly.
- Duplicate/outer hlines are normalized, so raw source-row count is not a
  valid lower bound for rendered line count. The strict requested ERT
  assertion remains red to expose that contract conflict.
- A finite-width viewport cannot accommodate arbitrarily many columns at
  their preserved minima. The resulting fit failures are listed above;
  a fallback policy is a future design decision, not implemented here.
- Macros, footnotes, entities, and LaTeX remain ordinary Org display syntax;
  this mode is not an export engine, macro expander, or LaTeX previewer.
- Numeric geometry cannot certify the visual appearance of every emoji,
  combining mark, or RTL run. Screenshots are available for a human review
  but were not viewed. Manual TAB/RET/column-move steps are documented in
  `editing.org`; hook/toggle/undo behavior and formula recalculation were
  exercised automatically, not through a human keyboard session.
- Performance figures are a single local source-loaded run. Baselines and
  widget operations are explicitly different where noted; do not infer
  a rigorous speedup ratio or per-frame latency percentile.

## How to run

**GUI launcher rule:** `/opt/homebrew/bin/Emacs` (Emacs.app) does **not**
inherit the shell working directory. Every GUI `-l`, file name inside
`--eval`, and log path must be absolute, or pass
`--chdir /Users/chenyibin/Documents/emacs/package/org-table-widget` first.
Prefer `--batch` whenever real pixels are unnecessary; batch keeps the cwd.
Both GUI scripts use absolute output paths derived from their own file path.

Generate fixtures and run all ERT tests in batch:

```sh
cd /Users/chenyibin/Documents/emacs/package/org-table-widget
/opt/homebrew/bin/Emacs -Q --batch -l demos/gen-large.el \
  -f org-table-widget-demo-generate
/opt/homebrew/bin/Emacs -Q --batch -L . -L ../textui -L test \
  -l org-table-widget.el -l test/org-table-widget-tests.el \
  -l test/org-table-widget-demo-tests.el -f ert-run-tests-batch-and-exit
```

The current combined ERT command exits nonzero for the two documented
failures. Neither is silently converted to an expected failure.

Run the GUI scripts **one at a time**, without moving point or interacting
with their temporary Emacs windows during measurement:

```sh
/opt/homebrew/bin/Emacs -Q -l /Users/chenyibin/Documents/emacs/package/org-table-widget/demos/bench.el
/opt/homebrew/bin/Emacs -Q -l /Users/chenyibin/Documents/emacs/package/org-table-widget/demos/visual-check.el
```

They log results and exit their own clean Emacs instance. `visual-check.el`
logs individual assertion failures and continues, so all fixtures are
covered; inspect its `FAIL` records rather than relying only on exit status.
Screen recording permission must allow `screencapture` for screenshot output.

To read the saved CPU profile, use `M-x profiler-find-profile` and select
`demos/huge-cpu-profile.sexp` in a normal Emacs session.
