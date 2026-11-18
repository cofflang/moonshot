# Changelog

Every release of utsikt, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

utsikt has no version numbers of its own. It ships inside Moonshot, which
carries this repository as a subtree, so each entry is named after the
Moonshot release that carried it.

## Moonshot 0.7.0 "Lucky Lillan" - 2026-11-18

Needs coff v0.8.0 and the `moon.c0` that Moonshot 0.7.0 ships.

### Added

- Pages of another user open without their scripts. utsikt reads a page with
  `readfile_owned`, and when the kernel says that another user owns the file,
  the page is read the ordinary way, shown, and given no script engine, so
  its `<script>` blocks and `onclick` attributes stay text. The rule looks at
  the owner of the page file and at nothing else, so the folders above it and
  the stylesheets it links are not checked. The page that opens first prints
  a note about this before its first frame. No note is printed after the
  first frame, since a windowed program's text would be drawn over the page.
- `<link rel="stylesheet" href="...">`. A linked sheet is applied in document
  order together with the `<style>` blocks, so the order a page writes them
  in decides which rule wins. A page loads at most 16 linked sheets, each at
  most 64 KiB, and imports are not followed. A sheet that is missing or
  too large is skipped. `rel` is kept on every element, and any
  of its words may be `stylesheet`.
- Links, pictures and sheets are looked up from the folder of the page that
  names them, so a page in `/site/notes/` finds `pic.spr` next to it. A name
  that starts with `/` is still taken from the root.
- `color: transparent` and `background: transparent`. A transparent
  background clears the colour a default style gave, and a transparent text
  colour paints nothing unless the text is clipped to a gradient.
- `background: linear-gradient(...)` with `background-clip: text`, also
  written `-webkit-background-clip: text`. The text is filled with a
  gradient that runs left to right across the line. The direction is `to
  right` or an angle up to 360 degrees, drawn left to right either way. There
  are two to eight colour stops, each with an optional position in percent,
  and a stop with none is placed evenly between its neighbours. Anything
  that does not parse is left out and the text keeps its colour.
- Swedish letters, the accented e and four punctuation marks, the en dash,
  the ellipsis and the two curly double quotes. They are read from UTF-8 text
  and from numeric character references, and each takes one cell of the
  font. The font cache holds 256 glyphs instead of 128.

### Changed

- `margin` and `padding` take one to four lengths in pixels, and a value is
  used only when every side is the same. `margin: 4px 8px` used to take 4 and
  is now ignored, so a page with two different sides has to say each side on
  its own.
- A byte that is not valid UTF-8, and a character the font does not have,
  paint as `?`.
- A `<style>` block and a linked sheet keep the order they have in the
  document.
- `load_document`, `load_document_foreign` and `load_document_limit` are the
  places a page's bytes enter the engine, and `img_load` is the place for
  pictures.

### Fixed

- A sprite whose header named more frames than its file holds could make the
  size check wrap and be accepted. The check is now made by division, and the
  picture is refused.

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
