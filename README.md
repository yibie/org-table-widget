# org-table-widget

Display Org tables as responsive, pixel-aligned widgets inside ordinary
Org buffers.

Org aligns tables with padding characters, which only works when every
character has the same width.  CJK text, emoji, inline code and a
`fixed-pitch` face that differs from `default` all break that
assumption, and a long cell pushes the whole row off the window edge.
`org-table-widget-mode` lays each table out in pixels instead:

- columns stay aligned across Chinese, Japanese, Korean, Latin text,
  emoji (including flags and ZWJ sequences) and inline code;
- long cells wrap inside their column; column widths come from each
  column's longest unbreakable token, so a short label keeps its width
  beside a paragraph-sized cell;
- the table reflows when the window width or text scale changes,
  debounced so dragging a frame edge triggers one relayout;
- `|---|` rules inside the table become group separators, alignment
  cookies (`<l>`, `<c>`, `<r>`) set column alignment, and cookie rows are
  hidden;
- links, emphasis and code inside cells keep the faces Org gives them.

The buffer text is never touched.  Each table is covered by an overlay
whose `before-string` holds the laid-out widget, so `org-element`,
export, `#+TBLFM` evaluation and Babel keep seeing the original table.
Moving point into a table reveals its source for ordinary `org-table`
editing; moving point out lays it out again.

Layout is provided by [TextUI](https://github.com/yibie/textui), which
lays out block widgets inside ordinary Emacs buffers.

## Requirements

- Emacs 29.1 or newer, running on a graphical display (pixel
  measurement needs `window-text-pixel-size`).
- Org 9.6 or newer.
- TextUI 0.8.0 or newer.

## Installation

```elisp
(use-package org-table-widget
  :straight (:type git :host github :repo "yibie/org-table-widget")
  :hook (org-mode . org-table-widget-mode))
```

Or add the directory to `load-path`, `(require 'org-table-widget)` and
run `M-x org-table-widget-mode` in an Org buffer.

## Commands

| Command | Purpose |
|---|---|
| `org-table-widget-mode` | Toggle widgets for every table in the buffer |
| `org-table-widget-refresh` | Lay every table out again |
| `org-table-widget-toggle` | Show or hide the widget for the table at point |

## Options

| Option | Default | Purpose |
|---|---|---|
| `org-table-widget-use-unicode-borders` | `t` | Box-drawing borders; `nil` uses ASCII |
| `org-table-widget-zebra-stripe` | `t` | Alternate data-row backgrounds |
| `org-table-widget-wrap-columns` | `t` | Wrap cells to fit the window; `nil` uses natural widths |
| `org-table-widget-max-width-fraction` | `1.0` | Fraction of the window width a table may use |
| `org-table-widget-relayout-delay` | `0.15` | Idle seconds after a resize before relaying out; `0` relays out immediately |
| `org-table-widget-reveal-on-point` | `t` | Show the source while point is inside a table |
| `org-table-widget-cell-properties` | faces, `invisible`, … | Text properties copied from the buffer into cells |

Faces: `org-table-widget-header`, `org-table-widget-border`,
`org-table-widget-zebra`.

## Fonts

Widgets are measured with the `fixed-pitch` face.  If your
configuration sets only the `default` font and leaves `fixed-pitch` on
its stock family, the two have different character widths; the widget
still fits the window, but keeping both on the same family gives the
best result:

```elisp
(set-face-attribute 'default nil :family "Iosevka")
(set-face-attribute 'fixed-pitch nil :family "Iosevka")
```

## Development

```sh
emacs -Q --batch -L . -L ../textui -L test -l org-table-widget.el \
  -l test/org-table-widget-tests.el -l test/org-table-widget-demo-tests.el \
  -f ert-run-tests-batch-and-exit
```

`demo.org` holds a multilingual table for trying the mode interactively.
The [scenario report](demos/REPORT.md) documents the `demos/` fixtures,
known failing assertions, GUI benchmarks, and pixel checks. The expanded
suite deliberately reports the known scenario failures; see the report
before interpreting a nonzero test exit status.

## Relation to md-mode

The pixel layout engine is shared in spirit with
[md-mode](https://github.com/yibie/md-mode)'s rendered tables, which
introduced the widget approach for Markdown.  The code is kept
separate so each package can follow its own format's rules.
