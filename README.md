# utsikt

utsikt is a browser engine I am writing from scratch in **c0**, for
[moonshot](https://github.com/cofflang/moonshot), my operating system. It
reads an HTML file off the filesystem, builds a DOM, applies a subset of CSS,
lays the document out as blocks, lines and tables, and paints it into a
window. Links are followed with the mouse and Backspace goes back.

"utsikt" is Swedish for view, or outlook.

There is no networking, on purpose. moonshot's network stack is the last
subsystem it will get, so for a long while a page is a file. Everything that
fetches bytes goes through one function, `load_document()` in `utsikt.c0`, so
the day there is a network stack, one function changes.

utsikt ships inside every moonshot release, so you do not need this
repository to use it. This is where it is developed.

## What works

- **HTML**: a tokenizer and tree builder in one pass. Character references,
  comments, doctype, void elements, `<style>` blocks, whitespace collapsing,
  the common implied end tags (`<p>`, `<li>`, `<td>`, `<tr>`), stray end tags
  dropped, unknown tags treated as inline. Kept attributes are `class` and
  `href`.
- **CSS**: type, class, `tag.class` and descendant (`div p`) selectors in
  comma-separated lists, with real specificity. `color`, `background`,
  `background-color`, `font-size`, `font-weight`, `display`, `margin`,
  `padding`, `text-align`. Colours as `#rgb`, `#rrggbb` and fifteen names.
  The default stylesheet is written in CSS and goes through the same parser
  as a page's own.
- **Layout**: block boxes, inline content broken into lines at spaces,
  collapsing vertical margins between siblings, lists with drawn markers,
  `<hr>`, and tables as a grid of equal-width columns.
- **Interaction**: scrolling by arrow keys, PageUp, PageDown, Home and End;
  links by mouse click; Backspace for back; `r` to reload; an address line
  saying which file is open; re-wrapping when the window is resized.

The font is the kernel's, fetched glyph by glyph with a syscall, so a page
and the shell beside it are set in the same face.

## Getting it running

utsikt only runs inside moonshot, and moonshot is built by coff, so you need
all three side by side.

```sh
git clone git@github.com:cofflang/coff.git c0-coff
git clone git@github.com:cofflang/moonshot.git moonshot
git clone git@github.com:cofflang/utsikt.git utsikt

cd utsikt
./dev.sh run
```

The first build bootstraps coff and takes a few minutes; moonshot's README
lists the packages it needs. When the QEMU window comes up, log in as
`root` with an empty password and type `spawn3 utsikt.elf`.

`./dev.sh` builds the utsikt in this checkout into the kernel, so an edit
here is what you see after the next `./dev.sh run`. `./dev.sh test` runs
the browser's tests. See [CONTRIBUTING.md](CONTRIBUTING.md) for the rest.

## What is in the repository

| File | What it is |
|------|------------|
| `utsikt.c0` | The program: window setup, loading a document, the load, parse, style and lay out pipeline, the key and mouse loop, navigation. It `include`s the four below, in this order. |
| `paint.c0` | The frame buffer, rectangles, the font cache and text drawing, and the string helpers. |
| `dom.c0` | HTML bytes in, a tree of nodes out. |
| `style.c0` | The stylesheet parser and the cascade that gives every node a computed style. |
| `flow.c0` | Normal flow. The tree becomes boxes and lines, measured in one pass and painted in a second, so a background is painted before the text on it. |
| `dev.sh` | Builds this checkout into a moonshot checkout next to it, and boots it or tests it. |

c0's `include` is textual, so the five files are one translation unit and
the include order is the order the compiler reads them in.

## How it gets into moonshot

moonshot carries a copy of this repository in `programs/utsikt/`, added
with `git subtree`, so a moonshot clone builds on its own and every byte
of the browser the kernel bakes in has its source right there. Each copy
records the utsikt commit it came from. On the moonshot side,
`./sync_utsikt.sh` pulls a newer utsikt in, and `./sync_utsikt.sh --check`
says whether its copy matches this repository.

Changes go to this repository first. A fix made inside moonshot's
`programs/utsikt/` is sent back here before anything else.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

Copyright (C) 2026 tavro
