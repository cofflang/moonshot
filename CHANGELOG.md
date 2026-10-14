# Changelog

Every release of Moonshot, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are
[semantic versions](https://semver.org/), and each release also has a name.
Each release says which coff it needs, since the two are released separately.

## [0.5.0] "Kind Goran" - 2026-10-14

Needs coff v0.6.0.

### Added

- hylla, a file manager. It shows a folder as a grid of icons and opens what is
  clicked, a folder by entering it, a program by starting it, a page in utsikt,
  a song in lira, a sprite in pensel and a `.c0` or `.txt` file in skrift. The
  background comes from `hylla.bg`, a colour or a sprite.
- `SYS_LISTDIR` (19) and `SYS_SPAWN` (20), so a ring-3 program can list a
  directory and start another program. `moon.c0` wraps them as `listdir` and
  `spawn`.
- `SYS_EDIT` (22), which opens a file in pensel or skrift in a new window.
  `moon.c0` wraps it as `edit`.
- Debug builds. `MOONSHOT_DEBUG=1 ./build.sh` adds the shell's debug commands,
  `chars`, `mouse` and `run3`. An ordinary build leaves their code out.
- lira shows its keys and a short how-to over the grid when `h` is pressed.
- `run_graphical.sh` adds a Sound Blaster 16 and plays it through the first
  QEMU audio backend it finds, or records it to `run_graphical.wav`. With
  sound on it opens QEMU's SDL window, since the GTK window stops passing
  input to the guest while a Sound Blaster is attached.
  `run_graphical_mac.sh` plays it through CoreAudio.
- `SYS_PROTECT` (21), which switches pages of a program's own heap between
  writable and executable, never both. `moon.c0` wraps it as `protect`.
- glimt, utsikt's scripting language, compiled to machine code inside the
  browser. See utsikt's own changelog.
- oljud plays 16-bit audio, every program has its own queue
  and the queues are mixed in the interrupt handler, so two programs can sound
  at once. lira has four instruments, square, triangle, saw and drum, chosen
  per note, and its song format moves to version 2, with old songs upgraded on
  load.
- lira opens and saves the file it is started with.
- Infecteria has music and sound effects, a win condition with a counter, and
  antibacteria that heal infected cells when the player is far away.
- The serial port is set up properly, with a loopback self-test at boot, so
  serial output works on real hardware and not only under QEMU.
- Boot self-checks for filling, glyph drawing and sprite blitting, each
  compared pixel for pixel with a model.
- Tests for reclaiming memory, mixed sound, hylla, glimt, utsikt's new
  elements and its scripting interface, and Infecteria's healing.

### Changed

- Everything is faster. Boot takes 57 ms instead of 420 ms between GRUB and the
  scheduler. Three demo threads that spun forever at boot now stop, which
  alone made graphical programs several times faster. Memory copies, fills,
  glyphs, blits and scrolling work in whole words, and the mouse pointer is
  only lifted out of the way when drawing actually overlaps it. A glyph draws
  about fourteen times faster than before.
- A program's whole address space, its code, stack, heap and page tables, is
  given back when it exits. utsikt alone left about 3 MB behind on every run.
- Files grow in place when written past their end.
- Every ring-3 program gets a 64 KB stack, with an unmapped page between the
  stack and the program. It used to be a single 4 KB page right on top of the
  program's own data.
- The kernel and every program use coff v0.6.0's `for`, `+=`, `!`, `defer`
  and `load32`/`store32`, and the kernel is a fifth smaller from its code
  generation.
- The kernel's JIT flushes stale translations after it changes its code page's
  permissions.
- Gnista's demo is gone. `test/mouse.elf` takes its place in the mouse tests.
- lira's song format and synth live in `programs/lib/`, since Infecteria plays
  its music through them too.
- `run_suite.sh` cleans up its copies when it is interrupted.
- The shell's `spawn3` is now `start` and `run` is now `interpret`. `spawn`,
  which started a kernel demo thread, is gone, and `run3` is a debug command.
  `start` refuses a file that is not an ELF program.
- `help`, `help (command)` and Tab completion read one command table, so every
  command is listed, explained and completed.
- The status bar shows how full the disk is, in megabytes of files out of the
  8 MB that can be saved, and the memory in use, each with a meter.

### Fixed

- A CPU exception in a ring-3 program, such as a division by zero or a bad
  address, ends that program alone. Its memory is freed and its window is
  marked as exited, and everything else carries on. Before, any such fault
  halted the whole system. `verify_crash.sh` covers four kinds of fault.
- Closing a window whose program was asleep could bring the kernel down,
  because the dead program woke up again on a stack that had been freed.
- `SYS_FILL` drew rectangles that started left of or above the window too
  wide or too tall.
- `help (command)` said several commands did not exist.
- The status bar counted only freed memory pages as free, and left out every
  page never handed out.
- skrift and pensel saved a file named by a path, such as `edit dir/file.c0`,
  as a new file instead of the one they opened.
- `count` printed `wc` in its usage line.

## [0.4.0] "Calm Ruffs" - 2026-10-10

Needs coff v0.5.0.

### Added

- lager, the allocator behind `alloc()`, so a program gives memory back with
  `dealloc()`. Its block table lives in the kernel, out of the program's reach.
- oljud, a Sound Blaster 16 driver, with `sound()` to queue audio.
- lira, a piano roll. Notes go on a grid with the mouse, a small synth plays
  them and a song is saved in the noter format with `writefile()`.
- utsikt draws images, pensel sprites that sit in a line like a word.
- pensel draws animation frames and Gnista plays them.
- Infecteria has a title screen and an end screen to play again from.
- `run_suite.sh`, which runs the whole test suite three scripts at a time.

### Changed

- Every ring-3 program is compiled into `build/` on every build and embedded
  in the kernel with c0's `embed`. The generated `*_data.c0` byte arrays are
  gone.
- Code in `boot.s` is reached by name, so `sync_addrs.sh` is gone.
- utsikt gives a page's memory back once the next page has loaded.

## [0.3.0] "Honest Pluto" - 2026-09-24

Needs coff v0.4.0.

### Added

- utsikt, a browser engine. It reads an HTML file off the disk, applies a
  subset of CSS including descendant selectors, lays the page out as blocks,
  lines and tables with collapsing margins and paints it into its window.
  Links are followed with the mouse and Backspace goes back. There is no
  networking, by decision.
- Ring-3 programs can ask where the pointer is and which buttons are down, in
  their own window's coordinates.
- `SYS_GLYPH`, which hands the kernel's font to ring 3.
- Drawn sprites for Infecteria, which pensel can replace.
- bake, the c0 program that writes the data the kernel carries.

### Changed

- The kernel is assembled and linked by smed, from the same linker script GNU
  ld used to read. No python is left in the build.
- `build.sh` refuses to build unless both the compiler and the assembler match
  the hashes recorded when coff's audit last passed.
- Ring-3 programs are built by coff's ordinary assembly backend, the one its
  differential tests check.
- A click on a window only focuses it, so the next click is the program's.
- pensel works with a real mouse.

### Fixed

- A double free in the REPL that could corrupt the kernel heap. The allocator
  also refuses a pointer it never handed out.
- A graphical window was painted over by the kernel after its program had
  drawn into it.

## [0.2.0] "Gentle Vinki" - 2026-09-16

Needs coff v0.3.1.

### Added

- Ring-3 programs as ELF64 executables, loaded from the filesystem into page
  tables of their own and, with `spawn3`, given a window of their own. Ten
  system calls stand between them and the kernel.
- Gnista, a game engine, and Infecteria, a game built on it.
- raket, a login gate before every shell session.
- tavla, a kind of window for graphical programs, with a title strip that shows
  focus, Alt+W to close it and a resize the program can notice.
- klick, a PS/2 mouse driver with a drawn pointer.
- pensel, a pixel-art editor shaped like the text editor.

### Changed

- Moonshot builds from source with the released coff, so there is no
  pre-built image any more.
- `build.sh` checks the compiler's hash on every build against the hash
  recorded when coff's audit last passed, and refuses to build on a mismatch.
- tcc replaces gcc as the seed compiler.
- Every byte array the kernel bakes in has its source in `programs/` and is
  rebuilt from it.

## [0.1.0] "Quiet Boye" - 2026-08-03

### Added

- The first release. Moonshot boots through Multiboot and GRUB, with
  preemptive multitasking on a round-robin scheduler, its own framebuffer and
  font renderer, a tiled windowing layer, a shell with tab completion and
  history, a text editor with syntax highlighting, a c0 REPL with a JIT
  compiler, a disk-backed filesystem with permissions and ring-3 userspace.
  It ships with a pre-built image.

[0.5.0]: https://github.com/cofflang/moonshot/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/cofflang/moonshot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/cofflang/moonshot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/cofflang/moonshot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/cofflang/moonshot/releases/tag/v0.1.0
