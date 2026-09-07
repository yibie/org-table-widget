# Changelog

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
