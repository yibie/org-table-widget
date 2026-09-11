# Changelog

## Unreleased

- Stop revealing a table's source whenever point passes through it. Point now
  stops on the widget as on a single character, with the cursor on its top-left
  corner, and steps past it on the next motion. Press `e`
  (`org-table-widget-edit`, bound in the new `org-table-widget-map`) to edit
  the source, which is laid out again when point leaves. Searches landing inside
  a table still reveal it. `org-table-widget-reveal-on-point` now defaults to
  nil; set it to `t` for the previous behavior.

- Leave out the column Emacs keeps for the continuation glyph when a window
  lacks a fringe or `overflow-newline-into-fringe` is nil, so full-width tables
  no longer push their right border onto the next screen line.

- Support `display-line-numbers-mode`: measure cells without the line-number
  area, which had inflated every width and broke borders; leave room for the
  widest line numbers scrolling can bring into view; and lay tables out again
  when the mode is toggled.

- Settle short columns at their natural width before sharing space among
  columns that wrap anyway, so values such as `0.6296 %` or `773.8 m` are no
  longer split while a long text column wraps (#2); spread rounding pixels
  instead of giving them all to the last column.

- Prevent duplicate table previews after `revert-buffer` reinitializes Org mode;
  release owned overlays, markers and pending relayout before major-mode changes.

- Subtract effective line and wrap prefix widths from table layout budgets,
  including Org indentation, and invalidate cached layouts when they change.

## 0.1.0 — First public release

### Features

- Pixel-aligned Org table overlays powered by [TextUI](https://github.com/yibie/textui),
  supporting mixed scripts, emoji, inline faces and links.
- Wrapped cells, Unicode or ASCII borders, header styling, alternating row
  backgrounds and explicit left/center/right alignment cookies.
- Responsive layout after window resizing or text scaling, with debounced updates.
- Reveal source at point, toggle individual tables and refresh rendered tables,
  while preserving source for ordinary Org editing, export and formulas.

### Fixes and performance

- Preserve pixel padding in overlay before-strings.
- Omit Org column-group declaration and alignment rows; normalize outer and
  duplicate horizontal rules.
- Cache measured strings with their text properties and defer garbage collection
  during layout.
- Reuse unchanged table renderings across refresh and reveal transitions, with
  layout-sensitive cache invalidation.
- Preserve source text and editing state when pixel measurement moves point or fails.
- Add scenario demos, GUI performance and visual-check scripts, and a 42-test ERT suite.

### Requirements and limitations

Requires Emacs 29.1+, Org 9.6+, TextUI 0.8.0+, and a graphical frame for rendered
widgets. Terminal automatic rendering is skipped; tables remain Org source.

This is an early release: width cookies are ignored, very wide tables may
overflow the window, numeric columns need `<r>` for right alignment, and
coexistence with `org-modern` and `valign` is untested.
