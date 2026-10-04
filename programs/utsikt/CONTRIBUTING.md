# Contributing to utsikt

Contributions are welcome, from a one-line fix to a new piece of CSS. This
file is everything you need to know before opening a pull request.

## The loop

Set up the three repositories side by side as the README shows, then:

```sh
./dev.sh build        # bake your utsikt into the kernel and build it
./dev.sh run          # the same, then a QEMU window to try it in
./dev.sh test         # the same, then every utsikt test
./dev.sh test table   # only verify_utsikt_table.sh
```

Every build bakes the sources in this checkout into moonshot's
`utsikt_data.c0`, so the moonshot checkout will show a diff afterwards. That
is expected, and nothing in it belongs in your pull request here.

If the first build stops with a bare `CODEGENERROR`, that is coff1 refusing
something without saying what. Compiling the same file with `coff0` (in
`c0-coff/`) prints the real message.

## Where the tests are

The tests are `verify_utsikt*.sh` in moonshot, not in this repository,
because every one of them boots the kernel in QEMU, drives it over the
monitor and measures the framebuffer. They also share moonshot's harness
and the two pages the kernel seeds, `index.html` and `about.html`, which are
written in moonshot's `index_html.c0`.

So a change that needs a new test, or a new page to test against, is two
pull requests, one here and one to moonshot. Say in each which one it goes
with. I will merge them together.

## What I look for in a pull request

- **A test for anything a reader can see.** A new property, selector, tag
  or layout rule comes with a `verify_utsikt_*.sh` that fails without it.
- **A test you have watched fail.** Before you call a test done, break the
  thing it checks (delete the line that implements it, or make it return
  the wrong value) and confirm the test goes red. Say in the pull request
  what you broke and what the test reported. A test that has never failed
  proves nothing, and almost any bug in a renderer still puts pixels on the
  screen.
- **Measure, do not eyeball.** The existing tests count pixels of a known
  colour inside the window rather than comparing screenshots, so they say
  what is wrong and not just that something is. Pick colours for your test
  page that appear nowhere else on screen.
- **Drop what is not supported rather than guess.** An unsupported selector
  is skipped whole, never applied as the part of it that parsed. A wrong
  rendering is worse than a missing one.
- **Every allocation counts.** `alloc()` has no free. Anything that grows per
  frame leaks the heap, so per-frame tables are fixed size and rebuilt.
- **No new dependencies.** utsikt talks to the kernel through syscalls and
  nothing else, and it carries no third-party code.

## Style

Read a file or two before writing; the style is easy to match.

- Every file starts with the GPL header the existing ones carry. A new file
  gets the same header with its own name and a line saying what it is for.
- Comments explain why, not what, and they are written as full sentences.
  When there was a simpler approach that does not work, say so and say why,
  because that is what the next person would otherwise try.
- No contractions in comments or documentation. Write "does not", not
  "doesn't".
- Commit messages are a short summary line and then prose paragraphs, not
  bullet lists. Say what changed and why it had to.

## Things to work on

These are known gaps, smallest first:

- **Right alignment, `<br>` and `display: none`** are implemented but no
  test exercises them. A test for each is a good first pull request.
- **The child combinator** (`div > p`) and **descendant selectors with more
  than two parts** (`div p span`). Both are dropped today. The second needs
  a rule to hold a list of ancestors rather than one.
- **Parent and child margin collapsing.** Adjacent siblings collapse;
  a parent's margin does not collapse with its first or last child's yet.
- **Content-sized table columns.** Columns are equal width now. Sizing them
  by content needs a measuring pass per cell before any cell is placed.

Two bigger ones need a decision from me before code, so please open an
issue to talk them through first:

- **Images.** These need an image format on moonshot's filesystem, and
  whether decoding lives in the kernel or in utsikt.
- **A real allocator.** Every page load and every reload costs a fresh
  document's worth of heap that is never returned.

## License

By contributing you agree that your contribution is licensed under
GPL-3.0-or-later, the same as the rest of utsikt.
