# Changelog

Every release of Moonshot, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are
[semantic versions](https://semver.org/), and each release also has a name.
Each release says which coff it needs, since the two are released separately.

## [0.6.0] "Busy Bertil" - 2026-10-26

Needs coff v0.7.0.

### Added

- Moonshot builds programs on its own. It carries coff and smed as
  `coff.elf` and `smed.elf`, built from the same sources as the coff and
  smed on the host, and a `hello.c0` to try them on. The `hello.s` coff
  writes on Moonshot is the same, byte for byte, as on Linux.
- `execute file.c0` in the shell compiles a program with coff, links it with
  smed and starts it. The program stays next to its source as `file.elf`.
- `SYS_OPEN` (23), `SYS_READ` (24), `SYS_WRITE` (25) and `SYS_CLOSE` (26),
  ordinary files for ring-3 programs, eight open at a time per program. A
  path starts from the folder the program was started in.
- Alt+M makes the focused window fill the screen and gives it back, with
  every other window where it was. A tavla's title strip has a box, `[+]`
  and `[-]`, that does the same on a click. Windows behind keep running and
  draw nothing, and a program whose window comes back is made to draw again.
- `SYS_CLOSE_KEY` (32), `close_key()` in `moon.c0`. A program can take Alt+W
  as a key instead of being stopped by it. skrift, pensel and form do, so
  Alt+W asks about unsaved changes, and a second Alt+W quits without
  saving. A program that asks and then stops reading keys is stopped by the
  next Alt+W a second later.
- The kernel reads the real-time clock at boot, as UTC, and the status bar
  shows the day, the date and the time. One offset, the minutes to add to
  UTC, written by hand in `tid.zone` in the root, sets the local time. `SYS_CLOCK` (33), `clock()` in `moon.c0`.
- insyn, a look inside the machine (`start insyn.elf`), with the
  processes, memory, the last two minutes as graphs and the hardware on
  one screen. It only looks. `SYS_INFO` (34), `sysinfo()` in
  `moon.c0`, copies the kernel's counters out. smed knows `cpuid`.
- A login screen. With windows, boot goes straight to a screen that covers
  everything, a username and a password (Tab, the arrows or a click move
  between them), and a correct pair shows the windows, every one of them
  the user's, with the shell on the left and hylla on the right. Alt+L
  locks the screen with everything running behind it, and only the same
  user's password opens it. The prompt starts with the user's name.
- Scripts, files ending in `.sk`, run with `run name.sk args` or a click in
  hylla. Lines of shell commands with variables, `$1` and the other
  arguments, `while` and `if`/`else if`/`else` blocks in braces, whole-number
  arithmetic and string comparison. `name = value` and `$name` also work at
  the prompt.
- `SYS_WAIT` takes a time limit, and `SYS_KILL` (35), `kill()` in
  `moon.c0`, stops a task the caller started itself. skrift's F6 stops code
  that has not answered after three seconds instead of waiting forever.
- form, a 3D modeller (`start form.elf name.form`), and djup, gnista's 3D,
  which draws form's meshes with flat shading and a depth buffer in fixed
  point. A model starts as a cube and grows by pulling sides out, moving
  corners and colouring sides, with undo. Several sides can be picked at
  once, or single triangles, and handles along the three axes drag them.
  The edges and corners are drawn where they can be seen, and the wheel
  zooms. hylla opens `.form` files in form.
- The mouse wheel, for programs, `SYS_WHEEL` (37), `wheel()` in `moon.c0`,
  and pointer shapes a program can ask for over its window, `SYS_POINTER`
  (36), `pointer()` in `moon.c0`.
- A tavla's title strip has a close box, `[x]`, beside `[+]`, and shows the
  window's number. The name of a program's window leaves out `.elf`.
- hylla has a tree of every folder beside its shelf of icons, `t` or a click
  switches. Long names wrap onto more lines, and names leave out their
  endings.
- lira is played with the mouse. The left button puts a note in and a drag
  makes it longer, the right button takes it away, a note's ends drag
  shorter or longer, and its middle drags up and down for loudness and
  sideways for where it sits between the speakers. The instruments are
  buttons along the bottom.
- skrift's F5 runs only the selected text when there is any.
- lira, pensel and form open a new file with no name when started without
  one, and ask for a name the first time it is saved.
- A shell window keeps its text when the layout changes, a program opening
  beside it, a window filling the screen and giving it back, the screen
  locking and opening, where it used to come back blank with a new prompt.
- Stereo sound. oljud plays 16-bit stereo, and `SYS_SOUND_FORMAT` (31),
  `sound_format()` in `moon.c0`, lets a program hand it 16-bit mono or 16-bit
  stereo instead of 8-bit mono. Programs that never ask sound as before.
- lira mutes (m) and solos (o) an instrument and pans it (p and P, nine
  steps). It plays in 16-bit stereo, and the pans are saved with the song.
- noter format version 4, with a pan for each instrument and one for each
  note. Older versions still load, everything in the middle.
- `SYS_EXIT_CLOSE` (27), `SYS_SHELL` (28), `SYS_WAIT` (29) and
  `SYS_REMOVE` (30), and two flags for `SYS_SPAWN`, one to run a program in
  the background with no window and one to find names from the caller's
  folder. `moon.c0` has `exit_close`, `shell`, `wait`, `remove`,
  `spawn_with` and `key_char` for them.
- form scales what is picked around its middle (`=` and `-`) and mirrors
  the picked sides, or the whole model, across x = 0 (`m`), with the
  corners on x = 0 shared so the halves stay joined. `d` copies the picked
  sides half a unit to the right, and `g` puts corners back on the 1/16
  grid.

### Changed

- The repository is sorted into folders by role. The kernel is in
  `kernel/`, split into `core`, `drivers`, `screen`, `files` and `shell`,
  the generators are in `tools/`, the test scripts in `tests/` and the
  ring-3 test programs in `tests/elf/`. `build.sh`, the launchers and the
  README stay at the top. What a build makes goes to `build/`, and what the
  tests make to `out/`.
- A task with nothing to do, sleeping or waiting, gives the CPU to the next
  one at once instead of holding it, idle, until the next timer tick. With
  two programs open and waiting, a third one drawing whole frames draws
  about four times as many.
- The status bar no longer shows the number of tasks.
- `count` counts a last line with no newline after it, and names what it
  prints, as in `3 lines, 12 words, 61 bytes`.
- The test programs in `/test` are only put there when the kernel is booted
  for the test scripts (`test` on its command line). Any other boot takes
  them away again.
- skrift, the text editor, is a ring-3 program and works differently. There
  are no modes. Typing types, the keys for everything else are shown along
  the bottom of the window, and they change with what can be done. F2 saves,
  F3 finds, F4 goes to a line, F5 runs the file with `execute`, F6 shows the
  value of a c0 expression and Alt+W quits. Ctrl+C, Ctrl+X and Ctrl+V copy, cut
  and paste, and Ctrl+Z and Ctrl+Y undo and redo as far back as the file was
  opened. A file can be any size, where it was 8KB, and a click places the
  cursor. `edit` and hylla open it, and paths start from the shell's folder.
- pensel, the pixel editor, is a ring-3 program too. F2 saves, Alt+W quits
  and asks first about unsaved changes, Ctrl+Z and Ctrl+Y undo and redo a
  stroke at a time, left and right step through frames. The grid grows to
  fill the window, and a fast drag paints every cell it crosses. `draw` and
  hylla open it.
- The REPL's compiled code saves and restores `rbx`, which coff now keeps a
  local variable in.
- A ring-3 program's heap is 32MB instead of 8MB.
- lager keeps each program's table of blocks in that program's own address
  space, on pages only the kernel can reach, instead of in the kernel heap.
  A program can hold about 174,000 blocks at once instead of 16,384.
- A ring-3 program's heap and stack can no longer be run as code, only a
  page `SYS_PROTECT` made runnable (and read-only) can. A program that
  jumps into its heap stops with a page fault. Its own code can be run but
  not written, and its data written but not run, since smed writes the two
  as separate segments and the kernel maps each as it says.

### Removed

- The login prompt in each window when windows are on. A window opened after
  the login, or after the last one is closed, belongs to the user logged in.
- The kernel's own text editor and pixel editor, which ran inside the
  keyboard and mouse interrupts.

### Fixed

- Starting a program kept a copy of its whole file in the kernel heap, so
  after a few dozen starts no program would start at all.
- The letter of Alt+W and the Tab of Alt+Tab also reached the program in
  the focused window as ordinary keys. kakel's chords are now its own.
- `echo --file` printed only the first 1008 bytes of a file and dropped the
  rest without a word. It now prints the whole file.
- A program stopped with `kill` while it was still starting kept its file
  in the kernel heap for good. What a program is given to start with now
  stays with its task until it is used, and the reaper frees what is left.
- A file that begins like a program but is not one was refused, and its
  task then went on running somewhere past the end of its stack. It now
  ends there.
- A number printed on serial could come out wrong when an interrupt
  printed a number of its own in the middle of it, since both wrote their
  digits into one buffer (10000 came out as 10156 next to a key's
  scancode). The serial printers keep no digits in memory now.
- A program closed with Alt+W while it was running could come back. It
  ran on until the next tick, and its next sleep made it runnable again,
  so it stayed in the task list, was never freed and held its slot. A
  program that has been closed now does nothing more when it calls the
  system.

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

[0.6.0]: https://github.com/cofflang/moonshot/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/cofflang/moonshot/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/cofflang/moonshot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/cofflang/moonshot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/cofflang/moonshot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/cofflang/moonshot/releases/tag/v0.1.0
