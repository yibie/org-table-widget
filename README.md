# org-table-widget

Display Org tables as responsive, pixel-aligned widgets inside ordinary Org
buffers, powered by [TextUI](https://github.com/yibie/textui).

- Align mixed CJK, Latin text, emoji and inline code using pixel widths.
- Wrap long cells and reflow after window resizing or text scaling.
- Preserve Org cell faces and links; support `<l>`, `<c>` and `<r>` alignment,
  horizontal separators, Unicode/ASCII borders and alternating row backgrounds.
- Hide alignment and column-group declaration rows from the rendered table.

Rendering uses overlays, leaving the source table intact for Org editing,
export, formulas and Babel. Moving point into a table reveals its source;
moving out renders it again.

The cursor-entry correction for moving upward into a table preview is adapted
from [karthink's org-latex-preview fix](https://github.com/karthink/org-mode/blob/olp/lisp/org-latex-preview.el#L670).
Thanks to karthink for the fix and for explaining the multi-line preview edge case.

## Requirements

Emacs **29.1+**, Org **9.6+**, [TextUI **0.8.0+**](https://github.com/yibie/textui),
and a **graphical Emacs frame** for rendered widgets. In a terminal, the mode
can be enabled, but automatic rendering is skipped and tables stay as editable
Org source.

## Installation

Not on MELPA yet. Install TextUI first, then this package:

```elisp
(require 'package-vc)
(package-vc-install "https://github.com/yibie/textui")
(package-vc-install "https://github.com/yibie/org-table-widget" "v0.1.0")
```

Alternatively, clone both repositories and add their directories manually:

```elisp
(add-to-list 'load-path "/path/to/textui")
(add-to-list 'load-path "/path/to/org-table-widget")
(require 'org-table-widget)
```

## Usage

Enable automatically in Org buffers:

```elisp
(require 'org-table-widget)
(add-hook 'org-mode-hook #'org-table-widget-mode)
```

Use `M-x org-table-widget-mode` to enable or disable it in the current buffer,
`M-x org-table-widget-toggle` to reveal or render the table at point, and
`M-x org-table-widget-refresh` to refresh the buffer's tables.

### Options

Customize with `M-x customize-group RET org-table-widget RET`.

| Option | Default | Meaning |
| --- | --- | --- |
| `org-table-widget-use-unicode-borders` | `t` | Use Unicode borders; nil selects ASCII. |
| `org-table-widget-zebra-stripe` | `t` | Alternate data-row backgrounds. |
| `org-table-widget-wrap-columns` | `t` | Wrap cell content; nil uses natural widths. |
| `org-table-widget-max-width-fraction` | `1.0` | Fraction of the window body width available to the table. |
| `org-table-widget-relayout-delay` | `0.15` | Idle seconds before resize relayout; zero or negative means immediate. |
| `org-table-widget-reveal-on-point` | `t` | Reveal source when point enters a table. |
| `org-table-widget-cell-properties` | `(face font-lock-face invisible display mouse-face help-echo keymap follow-link htmlize-link org-emphasis)` | Text properties retained in rendered cells. |

### Compatibility

- **`org-modern`:** Set `org-modern-table` to `nil` so the two packages do not
  style the same table. Non-table styling has been smoke-tested in both
  mode-enabling orders, including through `org-mode-hook`, with Emacs 31.0.91,
  Org 9.8.7 and org-modern 1.15. A reported load-order conflict has not yet been
  reproduced; please include package versions and a minimal configuration when
  reporting it.
- **`visual-line-mode`:** Cursor entry is tested with the mode both enabled and
  disabled: Down reveals the first source row, and Up reveals the last source
  row. A narrow-window layout smoke test also passed with the mode enabled.
  This does not eliminate the minimum-width overflow limitation noted below.

## Status

**0.1.0 is an early release.** Known limitations:

- Org width cookies are ignored.
- Very wide tables can overflow the window when minimum column widths do not fit.
  Overflow is truncated when `truncate-lines` is non-nil (the Org default), or
  wraps when nil; the widget does not change `truncate-lines`.
- Numeric columns are not automatically right-aligned; use an explicit `<r>` cookie.
- Coexistence with `valign` is untested; see above for `org-modern` test coverage.

See [CHANGELOG.md](CHANGELOG.md) for release changes.

## Performance

Measured with `demos/bench.el` on macOS, Apple M4 Max,
Emacs 31.0.91 GUI, with Iosevka at height 150. Times are seconds.

| Table | First display | Refresh | Resize relayout | Leave table |
| --- | ---: | ---: | ---: | ---: |
| 500 × 8 (`large.org`) | 0.355002 | 0.007237 | 0.279066 | 0.007163 |
| 3000 × 6 (generated `huge.org`) | 1.339867 | 0.034297 | 1.052924 | 0.034108 |

Refresh and leave-table timings reuse unchanged content; edits require rebuilding.
These are single-run measurements on this machine, not guarantees for other setups.

## Demos and tests

Browse [demos/](demos/) for example tables, benchmarks and visual checks.
With TextUI checked out alongside this repository, generate the benchmark inputs
(including the untracked `huge.org`), then run each GUI script in a separate Emacs:

```sh
emacs -Q --batch -l /absolute/path/to/org-table-widget/demos/gen-large.el -f org-table-widget-demo-generate
emacs -Q -l /absolute/path/to/org-table-widget/demos/bench.el
emacs -Q -l /absolute/path/to/org-table-widget/demos/visual-check.el
```

Replace `/absolute/path/to` with your checkout's parent directory. Scripts write
ignored logs/profiles under `demos/` and screenshots under `demos/shots/`, then exit.

With TextUI checked out alongside this repository, run the full ERT suite:

```sh
cd /path/to/org-table-widget
emacs -Q --batch -L . -L ../textui -L test -l org-table-widget.el \
  -l test/org-table-widget-tests.el -l test/org-table-widget-demo-tests.el \
  -f ert-run-tests-batch-and-exit
```

The redisplay-dependent motion test is skipped in batch mode. In a graphical
Emacs, load `test/org-table-widget-tests.el` and run
`M-x ert RET org-table-widget-reveal-vertical-interactive RET`.
For the optional org-modern compatibility test, put org-modern and its
dependencies on `load-path`, load `test/org-table-widget-compat-tests.el`, then
run `M-x ert RET org-table-widget-compat- RET`.

Prefer `--batch` when real pixels are unnecessary. On macOS, the Emacs.app
launcher ignores the shell working directory, hence the absolute paths above.
For GUI invocations, use absolute paths for every `-l`, file name in `--eval`,
and log path, or pass `--chdir /absolute/path/to/org-table-widget` before loading scripts.
