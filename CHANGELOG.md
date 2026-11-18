# Changelog

Every release of Moonshot, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are
[semantic versions](https://semver.org/), and each release also has a name.
Each release says which coff it needs, since the two are released separately.

## [0.7.0] "Lucky Lillan" - 2026-11-18

Needs coff v0.8.0.

### Security

Users were not kept apart in 0.6.0 and 0.6.1. `login` with no password
switched to any account, `passwd`, `own`, `mode`, `remove` and `rename` did
not ask who was asking, a write that was refused could still change the size
of the file, the rights of a program followed the shell window it was started
from instead of the program, new files belonged to root, and passwords were
typed on the command line, shown on the screen and kept in the history. If you
rely on 0.6.0 or 0.6.1 to keep one user away from another, do not.

This release fixes that. Users are kept apart only for the length of one boot,
because users, passwords, owners and modes are not saved. Every item below
holds within one boot and not across boots.

- Users within one boot. After a reboot every file belongs to root and every
  other user can read it, locked files included, and root has no password
  until `passwd` is run again. Run `passwd` first thing after every boot.
- Every program carries the user it was started as. A shell window that
  switches to root does not give root rights to programs already running as a
  guest. Programs and shell windows that a program starts keep its user.
- The filesystem is told who is acting on every call. Only root or the owner
  of a file may change it, including its mode, its name and its contents. A
  locked file refuses reads by other users. A refused write leaves the file as
  it was. New files belong to the user who made them.
- `login (name)` and `passwd [user]` ask for passwords at a masked prompt. A
  password is never part of a command line, never shown, never stored in the
  history and never printed on the serial line. It is at most 64 bytes.
  `passwd` needs the old password, or root. `adduser` and `own` need root. An
  account made by `adduser` has no password until root runs `passwd` for it.
- Command history is kept per user. Up in one user's window shows only that
  user's commands.
- Trusted path. A user starts programs and scripts, runs `interpret` and
  builds with `execute` only from files that user or root owns, in folders
  that user or root owns. Root therefore runs only root's own files. To run
  another user's program, take it over with `own` first. Copying another
  user's text into a file of your own, including running a selection with F5
  or F6 in skrift, is running it. hylla says so when it refuses to start
  another user's program.
- Other users' files are data. Opening another user's song, model, picture,
  text or page reads it with your rights, and another user's page opens
  without its scripts. A file another user made can also become hylla's
  background, through `/hylla.bg`.
- coff and smed read only files that the user who started them or root owns,
  in folders that the user or root owns, however they are started. A build
  therefore never takes in another user's include file. Root has to `own`
  another user's library before building with it.
- utsikt runs the scripts of a page only when the page belongs to the user who
  opened it or to root. Other users' pages open without their scripts.
- Shared folders. In a folder where others may add files, the root folder
  among them, nobody, root included, can overwrite or empty a file that
  someone else made there. Remove it first. Anyone may make files in the root
  folder and only root may make folders there. The kernel takes back
  `tid.zone` if another user made it first.
- Kill. Only root, or the user a task runs as, can stop it.
- The keyboard is trusted. Anyone at the keyboard can use, type into or close
  every open window, root's included. Lock the screen with Alt+L before
  leaving it. A program cannot move the keyboard focus away from a window it
  does not own.
- A folder that goes away. When the folder a window or program is working in
  is removed, the window goes back to `/` and says so, and a program started
  from there is refused.
- Saving during sync. A file that changes while `sync` runs may be saved half
  old and half new. Other files are not affected.
- `eval`, `eval -c` and `interpret` run inside the kernel and need root.
  `execute` builds a program that runs in ring 3 with the identity of whoever
  ran it.

### Added

- `zone` shows the local time and its offset from UTC, `14:05, UTC+1`, and
  sets the offset. `zone +1`, `zone -3:30` and `zone 5:45` take hours from -24
  to +24, with minutes if needed, and the offset is saved in `tid.zone`. Any
  logged in user may set it. There is no summer time.
- `besikta` prints the memory map, the disk, the framebuffer and the processor
  the machine reports.
- F12 shows the boot log on the screen and F12 again hides it, so a machine
  that boots to a blank or odd screen can say what happened.
- `dvala [on | off | seconds]` turns on a screen saver, a field of stars that
  starts after the machine has been idle. It is off at boot, `dvala on` waits
  five minutes and `dvala 90` waits ninety seconds.
- fanfar, a short sound at sign-in, and a soft cue when a window opens and
  closes. The `tyst` word on the kernel command line in GRUB turns the cues
  off.
- tapet (`start tapet.elf picture.spr 7 64 48`) writes a picture of a diagonal
  weave from a seed, a width and a height. `write hylla.bg picture.spr` makes
  it hylla's background. The same arguments give the same pixels.
- The shell line takes Home and End, and Ctrl+A and Ctrl+E for the same, Ctrl+W
  to delete the word before the cursor, Ctrl+K to delete to the end of the line
  and Ctrl+U to delete to the start.
- `sync create` makes a Moonshot disk out of a disk that has none, and only
  after you have typed the confirmation it asks for.
- `kraft`, a checker for the ACPI tables firmware leaves in memory. Given a
  buffer that holds the tables, it checks the RSDP, the XSDT, every table
  length and checksum, and finds the FADT, and it refuses anything that does
  not add up. It reads only from the buffer, never from a physical address,
  and touches no device. It is built into the kernel and nothing calls it yet,
  so it changes nothing you can see.
- `make_usb.sh --iso FILE` makes the same boot image, saves it as `FILE`,
  prints its sha256 and stops without writing to any disk.
- `build.sh` can write `build/site-disk.img`, a second disk with a folder of
  your own pages and pictures, when `~/.config/moonshot/site-root` and
  `site-files` name them. Without them it says it skips `/site`, builds the
  kernel as before and leaves that disk empty. See the README.
- utsikt draws Swedish letters and the accented e in the font's own cells, and
  follows `rel` and linked sheets in document order, up to 16 sheets of 64 KiB
  each. The utsikt CHANGELOG has the full list.

### Changed

- `sync` writes only to a disk that carries the Moonshot magic. Every disk
  write returns a status, a timeout and an error are told apart and reported,
  and `sync` says so when a write failed instead of saying it saved. A disk it
  does not recognise is left untouched. The filesystem is not safe against a
  power cut, so a failure during `sync` can leave the disk incomplete.
- `login` and `passwd` no longer take a password on the command line, see
  Security.
- The kernel takes the serial line one whole log line at a time, so a timer
  tick no longer lands in the middle of a line. Interrupts stay off for at
  most 128 bytes at a time. What a program prints also reaches the serial
  line as whole lines, held for each program until its newline, 256 bytes or
  its next call, so a program such as coff that writes a message a word at a
  time is no longer cut in two by the kernel's lines or by another program's.
  The screen still gets every byte at once.
- The kernel started through GRUB asks for 1024 by 768 at 32 bits and falls
  back to any mode the firmware offers.
- The kernel refuses to start a program with a segment that can be both
  written and run.
- `make_usb.sh` puts the kernel's own `kernel/core/grub.cfg` on the stick, so
  GRUB starts Moonshot at once instead of after a three second menu, and the
  script stops if that file loses the video settings UEFI machines need.
- `run_qemu.sh` boots from a new disk made for each run and no longer makes
  or reuses `disk.img`.

### Fixed

- When a program started from the shell split the screen before the shell
  had printed its prompt, the shell window showed no prompt, and a plain
  `split` always lost the prompt in the window that ran it. The shell now
  prompts the window whose line it just finished.
- A write that failed on the disk, or timed out, was reported as saved, and
  some files were missing or wrong on the disk afterwards. `sync` now checks every write.
- A request for a range of memory that wrapped around, or was negative, could
  get past the checks of a system call, and a fault while the kernel copied a
  program's memory could stop the kernel. A program that does this is now
  stopped and the kernel goes on. `SYSCALL` now clears the flags a program
  could use to single step the kernel, and the kernel has its own stacks for
  the debug exception, the non-maskable interrupt and the machine check.
## [0.6.1] "Busy Bertil" - 2026-11-02

Needs coff v0.7.0. Fixes for real UEFI machines, first booted on a Lenovo
IdeaPad 1i. Nothing changes under QEMU's BIOS boot.

### Added

- `make_usb.sh` writes a bootable USB stick for real hardware. It installs
  what is missing, builds the kernel, makes an image that boots on UEFI and
  BIOS and only writes to a USB disk you name, then reads it back. See
  Running on real hardware in the README.

### Fixed

- jenna took the first free memory region past the kernel, which UEFI
  firmware leaves a few MB long, so memory ran out during boot. It now takes
  the largest one.
- The kernel crashed during boot on UEFI machines with a general protection
  fault (vector 13) in `fb_get_pixel`. QEMU's BIOS boot gives zeroed RAM and
  real firmware does not, and the window tables kakel allocates were read
  back as garbage sizes. Memory jenna hands out for the first time is now
  zeroed.
- The machine froze as the shell and the file manager started on UEFI
  machines whose firmware puts the framebuffer at 2GB, where every program's
  memory starts. The framebuffer is now mapped at its own address, 8GB, which
  no program uses.

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
