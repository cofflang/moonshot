# Changelog

Every release of utsikt, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

utsikt has no version numbers of its own. It ships inside Moonshot, which
carries this repository as a subtree, so each entry is named after the
Moonshot release that carried it.

## Moonshot 0.5.0 "Kind Goran" - 2026-10-14

Needs coff v0.6.0.

### Added

- glimt, utsikt's scripting language, run for
  `<script type="text/x-glimt">` and the `onclick` attributes of a page whose
  scripts are glimt. It is a small part of c0, every value an int, with
  functions, `if`, `while`, `for`, `break`, `continue`, `return` and c0's
  operators. Each script is compiled to x86-64 machine code once and kept for
  as long as the page is on screen. A script reaches the page through ten
  builtins and nothing else, and elements and strings are checked handles, never
  pointers, so a script cannot reach the browser's memory. Division by zero
  gives 0, loops run on a budget and functions check their stack, so a runaway
  script is stopped and the rest of the page goes on. The code is never
  writable and executable at once.
- A scripting interface in `script.c0`. An engine registers the
  `<script type>` it runs and gets a page's scripts in document order, before
  the first frame, plus the page's `onclick` attributes. A script no engine
  claims, JavaScript among them, is left alone.
- `engine_test.c0`, a one-command test engine that exercises the interface on
  its own.
- `<pre>`, which keeps its whitespace, and `<script>`, whose text is read raw.
- End tags close the element they name. Block elements close an open `<p>`,
  and `<dt>` and `<dd>` close each other.
- The CSS properties `text-decoration`, `white-space: pre` and
  `list-style-type`. An ordered list numbers its items.
- Default styles for `h4` to `h6`, `section`, `article`, `header`, `footer`,
  `nav`, `main`, `aside`, `blockquote`, `pre`, `ol`, `dl`, `dt`, `dd`,
  `figure`, `u`, `s`, `del`, `ins`, `mark`, `small`, `kbd` and `abbr`.
- `id`, `type` and `onclick` are kept on every element.
- `start utsikt.elf PAGE` opens the page it is given.

### Changed

- Text paints about twice as fast, through a direct path for glyphs that sit
  wholly inside the view.
- A page builds in under 2 ms instead of about 80, since small pieces of a
  document are cut from 16 KB chunks rather than each asked of the kernel.
- The sources use c0's `for`, `+=`, `!` and `load32`/`store32`.

### Fixed

- Memory a script or a click allocated after a page had loaded was recorded
  with the next page instead of the current one. It leaked, and if the next
  page failed to load it was freed while the current page still used it.

## Moonshot 0.4.0 "Calm Ruffs" - 2026-10-10

Needs coff v0.5.0.

### Added

- utsikt is its own repository, carried by Moonshot as a subtree, with
  `README.md`, `CONTRIBUTING.md`, a GPL-3.0-or-later `LICENSE` and `dev.sh`,
  which builds this checkout into a Moonshot checkout next to it and then boots
  it or runs the browser's tests.
- `<img>`, drawing a pensel sprite in the line like a word.

### Changed

- Everything a document allocates is recorded and given back in one sweep once
  the next page has built. If the next page fails to build, the page on screen
  stays.
- Page names are owned copies, and the history gives back the names it drops.
- `dev.sh` builds through Moonshot's `build.sh`.

### Fixed

- Reloading a page or following a link cost a whole document of memory that
  was never given back.
- A table's row array leaked on every new layout.

## Moonshot 0.3.0 "Honest Pluto" - 2026-09-24

### Added

- The first release. utsikt reads an HTML file off Moonshot's filesystem with
  a forgiving parser, applies a subset of CSS with type, class and descendant
  selectors and a cascade by specificity, lays the page out as blocks, lines
  and tables with collapsing margins and paints it into its window with the
  kernel's font.
- Links, followed with the mouse, with Backspace to go back and an address
  line that shows which page is open.
- The page re-wraps when its window is resized.
- Two pages ship with it.
