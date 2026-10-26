# moonshot

moonshot is an operating system I am building from scratch for x86_64. It
boots via Multiboot + GRUB in QEMU, has preemptive multitasking with a
round-robin scheduler, its own pixel framebuffer and font renderer, a tiled
windowing layer, a login screen, an interactive shell with scripts, a REPL
with a JIT compiler, a disk-backed filesystem, a PS/2 mouse driver, a Sound
Blaster 16 driver, and ring-3 userspace: real ELF64 programs with their own
page tables and an allocator that can take memory back, loaded from the
filesystem and given a window of their own. Among them are a text editor, a
pixel editor, a 3D modeller, a file manager, a small game engine, a browser
engine that renders HTML and CSS off the filesystem, a piano roll that plays
what you write, and coff and smed themselves, so moonshot compiles and links
c0 programs on its own. The kernel is written in **c0**, a small systems
language whose compiler, coff, is a separate project in the same stack.

The end goal is an OS with a real graphical interface and its own windowing
system, not a serial-only kernel. Every test runs headless in QEMU and reads
the serial log or the framebuffer; there is also a graphical mode you can sit
in front of.

## What is in the repository

| Path | What it is |
|------|------------|
| `kernel/core/` | `kmain.c0`, the kernel entry point, which `include`s every other subsystem so coff compiles one flat translation unit, and the core: knekt (boot and interrupts), jenna (memory and paging), chrone (the scheduler and the clock), lager (the ring-3 allocator), syscall (ring-3 system calls and the ELF loader), interrupts. Also `boot.s`, the hand-written Multiboot entry stub that gets the CPU into 64-bit long mode, `ring3_handlers.s`, the ring-3 entry and exit trampolines, `linker.ld`, which places the kernel at 1 MiB, and the GRUB menus, `grub.cfg` and `grub_test.cfg` for the test boot. |
| `kernel/drivers/` | ata (disk), keyboard, klick (mouse), oljud (Sound Blaster 16), serial, vga (the text-mode fallback). |
| `kernel/screen/` | punkt (the framebuffer and font) and kakel (windowing). |
| `kernel/files/` | jakel (the filesystem) and `index_html.c0`, the pages utsikt opens and the test pages its scripts and elements are checked on, put on the filesystem at boot like the programs are. |
| `kernel/shell/` | raket (init and the login screen), skalman (the shell) and its scripts, repl (the REPL) and jit (its compiler). |
| `programs/` | The sources of the ring-3 programs the kernel carries. skrift (the text editor), pensel (the pixel editor), form (the 3D modeller), hylla (the file manager), lira (the piano roll) and insyn (a look inside the machine) each have a folder. Infecteria, the game, and djup, the 3D form draws with, come from Gnista. The browser engine is in `programs/utsikt/`, beside a frame-rate probe and the small programs the tests run. `programs/lib/` holds `moon.c0`, the ring-3 library they all include, and lira's noter song format and synth, which Infecteria plays its music with too. See [Programs](#programs). |
| `tests/` | The test scripts, sixty-six of them besides `run_qemu.sh`, and `run_suite.sh`, which runs them all against a snapshot of the tree, several at a time. See [Testing](#testing). |
| `tests/elf/` | Twenty-eight small c0 programs compiled with `coff --elf` and run inside the OS, by `verify_elf_backend.sh` and by the scripts that need a program to drive, so ring-3 code is checked end to end. |
| `tools/` | `gen_programs.sh` and `gen_elf_tests.sh` compile the ring-3 programs and the tests/elf programs into `build/` for the kernel to embed, and `bake.c0` packs the latter into one file. `build.sh` runs them. `screenshot.sh` boots headlessly and saves the screen to `screenshots/` as a PNG. |
| `build.sh` | Verifies the compiler and the assembler, then builds `build/moonshot.elf`. |
| `run_qemu.sh` | The main regression gate. Builds, boots headlessly, and asserts invariants on the serial log. |
| `run_graphical.sh` | Boots the kernel in a real QEMU window you can type and click in. `run_graphical_mac.sh` does the same on macOS. |
| `sync_utsikt.sh` | Pulls a newer utsikt into `programs/utsikt/` from its own repository, or checks that the copy here matches it. See [Programs](#programs). |
| `LICENSE` | GPL-3.0. |

What a build makes goes to `build/`, and what the tests make to `out/`.
Neither is in the repository.

## Building

You need Linux on x86_64, and these packages on Arch (`apt` names vary):

- `qemu-system-x86` — for booting the kernel
- `grub`, `libisoburn`, `mtools` — for `grub-mkrescue` (building the bootable ISO)
- `tcc` or `gcc`, and `as` and `ld` from binutils — for the one-time bootstrap
  of coff and smed only; the kernel itself is assembled and linked by smed
- `python3` — for the QEMU monitor scripts the tests use, and nothing else
- `bash`, `sed`, `awk`, `dd`, `sha256sum`, `timeout` — standard system tools

The kernel is compiled by `coff1`, the self-hosted c0 compiler. That compiler
lives in its own repository, and this one expects to find it at `../c0-coff/`
next to the moonshot directory, together with smed, coff's own assembler and
linker. This release needs coff v0.7.0 or later, the first whose file
builtins work under `--elf`, which coff and smed need to run inside
moonshot, and whose smed writes code and data as separate segments.
No pre-built image is needed.

```sh
# 1. clone both repositories side by side
git clone git@github.com:cofflang/coff.git c0-coff
git clone git@github.com:cofflang/moonshot.git moonshot

# 2. build moonshot
cd moonshot
./build.sh
```

`build.sh` bootstraps `coff1` and `smed` itself if they are missing or older
than their source, using tcc when present and gcc otherwise, and then runs
coff's full bootstrap audit before letting the new tools build anything. If you have
already bootstrapped coff by hand following its README, `build.sh` runs that
audit once and records the result. Either way the first build takes a few
minutes and every build after it is seconds.

## Running

```sh
./run_qemu.sh        # headless: boots, checks the serial log, exits
./run_graphical.sh   # a real QEMU window (needs qemu-ui-gtk and qemu-ui-sdl on Arch)
```

Both create `disk.img` if it does not exist. Log in as `root` with an empty
password; `help` lists the shell commands, `help (command)` explains one.
Some things to try: `start hylla.elf` for the file manager, `start
infecteria.elf` for a game in its own window, `start utsikt.elf` for the
browser (click a link, Backspace goes back), `start lira.elf` for the piano
roll (`h` shows its keys), `start form.elf ship.form` for the modeller,
`start insyn.elf` to see what the machine is doing, `edit notes.txt`, `draw
hero.spr`, `execute hello.c0` to compile and run a program on moonshot
itself, `split` and `Alt+Tab` for more windows, `Alt+M` to fill the screen
with one, `Alt+W` to close a program's window, `Alt+L` to lock the screen,
`eval 6 * 7` for the REPL.

`MOONSHOT_DEBUG=1 ./build.sh` builds a kernel with the shell's debug commands
as well, `chars`, `mouse` and `run3`.

`run_graphical.sh` plays sound through an emulated Sound Blaster 16. QEMU needs
a host audio backend for that, which Arch packages separately
(`sudo pacman -S qemu-audio-pipewire`). Without one the sound is recorded to
`run_graphical.wav`. With sound on, the window is QEMU's SDL one
(`qemu-ui-sdl`), since the GTK window stops passing keys and pointer motion to
the guest while a Sound Blaster is attached. Without SDL, sound is turned off.
`AUDIO=none` turns it off by choice, and `DISPLAY_BACKEND=gtk` or `sdl` picks
the window.

Without sound, `run_graphical.sh` forces QEMU's GTK window through XWayland. Under native
Wayland, GTK delivers clicks to a relative-pointer guest but almost no motion,
which looks exactly like a broken mouse driver and is not one.

## Testing

```sh
./run_qemu.sh                       # the main gate: boot + about 40 serial-log invariants
tests/test_keyboard.sh              # typing, caps lock, tab, alt-tab window switching
tests/test_shell.sh                 # start, kill, task lifecycle
tests/test_shell_help.sh            # help, help (command), Tab completion, debug builds
tests/test_shell_paths.sh           # write, echo --file and remove take paths
tests/test_reclaim.sh               # a program's memory comes back when it ends
tests/test_repl.sh                  # REPL expressions, JIT compilation, interpret
tests/test_disk.sh                  # filesystem write, sync, reload, read-back
tests/test_disk_gap.sh              # a file in a directory survives a reboot after a removal
tests/test_disk_compat.sh           # a disk written by an older jakel still loads
tests/test_panic.sh                 # divide-by-zero panic with correct vector
tests/test_doublefault.sh           # double fault caught on the IST1 stack
tests/test_fb_scroll.sh             # framebuffer scroll correctness
tests/test_kakel_scroll.sh          # window scroll clipping
tests/test_vga_scroll.sh            # VGA text-mode fallback scroll
tests/verify_login.sh               # the login screen, a wrong password, Alt+L
tests/verify_autostart.sh           # the first login opens hylla beside the shell
tests/verify_time_zone.sh           # the clock's offset survives a reboot
tests/verify_scripts.sh             # shell scripts, variables, while and if
tests/verify_shell_text.sh          # a shell window keeps its text through a relayout
tests/verify_elf_backend.sh         # the tests/elf programs run in ring 3, exit codes checked
tests/verify_alloc.sh               # layout + sizeof + alloc() from ring 3
tests/verify_ticks.sh               # ticks() from ring 3
tests/verify_windowed_ring3.sh      # a ring-3 program printing into its own window
tests/verify_crash.sh               # a faulting program ends alone, the system carries on
tests/verify_spawn_kill.sh          # a program stopped before it ran is freed
tests/verify_kill_sleeper.sh        # a program closed with Alt+W stays closed
tests/verify_coff_inside.sh         # coff and smed build a program inside moonshot
tests/verify_tavla.sh               # graphical windows: focus strip, Alt+W, recovery
tests/verify_alt_w.sh               # Alt+W asks an editor with unsaved changes first
tests/verify_maximize.sh            # Alt+M and the title's boxes
tests/verify_resize.sh              # a graphical program surviving a window resize
tests/verify_klick.sh               # the mouse driver, packet decoding, pointer drawing
tests/verify_mouse.sh               # click-to-focus, the mouse and the wheel from ring 3
tests/verify_infecteria.sh          # the game draws its sprites and a cell can be infected
tests/verify_infecteria_scenes.sh   # title, play, end screen, play again, quit
tests/verify_infecteria_heal.sh     # antibacteria heal infected cells
tests/verify_infecteria_win.sh      # taking every cell wins, and the counter reads right
tests/verify_infecteria_sound.sh    # the music and the effects, from the recording
tests/verify_hylla.sh               # the file manager, its shelf and tree, opening a page
tests/verify_hylla_edit.sh          # hylla opens source in skrift and sprites in pensel
tests/verify_skrift.sh              # the text editor, typing, undo, copy, find, save
tests/verify_skrift_run.sh          # skrift's F5 and F6 run what is written
tests/verify_pensel.sh              # drawing a two-frame sprite and saving it
tests/verify_form.sh                # the 3D modeller pulls out and colours a side
tests/verify_form_handles.sh        # form's handles, picking more than one side
tests/verify_form_tools.sh          # form's scale and mirror
tests/verify_form_copy.sh           # form's copy and grid snap
tests/verify_oljud.sh               # the sound driver, checked by recording what it plays
tests/verify_oljud_mix.sh           # two programs sounding at once are heard together
tests/verify_oljud_stereo.sh        # the 16-bit mono and stereo formats
tests/verify_lira_synth.sh          # the synth plays two notes at once at the right pitches
tests/verify_lira.sh                # the piano roll, from the screen and the sound card
tests/verify_lira_help.sh           # lira's help opens and closes
tests/verify_lira_pan.sh            # lira's pan, mute and solo, by listening
tests/verify_utsikt.sh              # the browser renders a page, scrolls, and scrolls back
tests/verify_utsikt_resize.sh       # the browser re-wraps its text when its window resizes
tests/verify_utsikt_links.sh        # clicking a link loads another page, Backspace comes back
tests/verify_utsikt_descendant.sh   # descendant selectors in the cascade
tests/verify_utsikt_address.sh      # the address line says which page is open
tests/verify_utsikt_margins.sh      # adjacent vertical margins collapse
tests/verify_utsikt_table.sh        # a table is laid out as a grid
tests/verify_utsikt_img.sh          # <img> draws a sprite in the line like a word
tests/verify_utsikt_reload.sh       # reloading a page gives its memory back
tests/verify_utsikt_elements.sh     # pre, ol, u and s, h4, mark, a raw script
tests/verify_utsikt_script.sh       # the scripting interface and its test engine
tests/verify_glimt.sh               # glimt, utsikt's scripting language
```

`tests/run_suite.sh` runs all of them against a snapshot of the tree, three
at a time, in about twelve minutes, so the tree can be edited while it runs.
`tests/run_suite.sh verify_form.sh test_shell.sh` runs only the ones named.

Every script boots the kernel in QEMU and passes or fails on what the serial
log or the framebuffer actually contains. The scripts that inject code into
the kernel (panic, double fault, the three scroll tests) restore the original
sources via a trap handler, so the tree is clean after they finish, pass or
fail. Each script makes the disk it needs in `out/`.

## Programs

moonshot has no way to receive a file from the host, so every ring-3 program
it ships is compiled with `coff --elf` into `build/`, embedded in the kernel
with c0's `embed`, and written onto the filesystem at boot. `build.sh` does
this on every build from the sources in `programs/`, with the same `coff1`
and `smed` that build the kernel, so the kernel can never carry an older
build of a program than its source, and there is nothing generated to
commit. `tools/gen_elf_tests.sh` does the same for `tests/elf/`, packing
them into one file with `bake`, which is compiled from `tools/bake.c0` on the
spot, so nothing between the sources and the kernel image is python.

Gnista, the game engine Infecteria is built on, and djup, its 3D, which
form draws with, are their own project; the copies in `programs/` are what
the kernel is built from.

utsikt, the browser engine, has its own repository,
[cofflang/utsikt](https://github.com/cofflang/utsikt), and is carried here in
`programs/utsikt/` as a squashed git subtree, so every update records the
utsikt commit it came from.

```sh
./sync_utsikt.sh --check   # does programs/utsikt/ match utsikt's main?
./sync_utsikt.sh           # pull utsikt's main in and rebuild the kernel
./sync_utsikt.sh <ref>     # the same, for any other branch or tag
```

## Trust

The kernel is compiled by a binary, and a binary is where a Thompson-style
compiler backdoor would live. `build.sh` therefore never trusts `coff1` on a
timestamp: it hashes `coff1` and `smed` on every build against the hashes
recorded when coff's bootstrap audit last passed (`toolchain.sha256`, written
by `build.sh` and by nothing else), and refuses to produce a kernel on a
mismatch. A tool with no recorded hash is audited before it builds anything.
No GNU tool and no python touches the kernel; `as` and `ld` are
needed once, to make the very first `smed`. The details, the threat model and
what is still trusted blind are in coff's `TRUST.md`.

## Contributing

Contributions are welcome. Some things to know before opening a pull
request:

- The kernel is compiled exclusively through `coff1`, the self-hosted c0
  compiler. Any new c0 language feature or builtin needed here must land in
  coff first.
- `./run_qemu.sh` and every test script must stay green.
- Changes to the browser go to [cofflang/utsikt](https://github.com/cofflang/utsikt)
  rather than to `programs/utsikt/` here; its CONTRIBUTING.md says how to
  build and test it against a moonshot checkout. If you did change it here,
  `./sync_utsikt.sh --send <branch>` pushes those commits to a branch of
  utsikt to open a pull request from.
- Keep it minimal. No new dependencies, no third-party code.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

Copyright (C) 2026 tavro
