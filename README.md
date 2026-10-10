# moonshot

moonshot is an operating system I am building from scratch for x86_64. It
boots via Multiboot + GRUB in QEMU, has preemptive multitasking with a
round-robin scheduler, its own pixel framebuffer and font renderer, a tiled
windowing layer, a login gate, an interactive shell with a built-in text
editor and pixel-art editor, a REPL with a JIT compiler, a disk-backed
filesystem, a PS/2 mouse driver, a Sound Blaster 16 driver, and ring-3
userspace: real ELF64 programs with their own page tables and an allocator
that can take memory back, loaded from the filesystem and given a window of
their own, among them a small game engine, a browser engine that renders HTML
and CSS off the filesystem, and a piano roll that plays what you write. The kernel is written in **c0**, a small systems language whose
compiler, coff, is a separate project in the same stack.

The end goal is an OS with a real graphical interface and its own windowing
system, not a serial-only kernel. Every test runs headless in QEMU and reads
the serial log or the framebuffer; there is also a graphical mode you can sit
in front of.

## What is in the repository

| Path | What it is |
|------|------------|
| `kmain.c0` | The kernel entry point. It `include`s every other `.c0` subsystem file, so coff compiles one flat translation unit. |
| `*.c0` | The kernel subsystems: knekt (core), jenna (memory/paging), chrone (scheduler), jakel (filesystem), kakel (windowing), punkt (framebuffer + font), raket (init and login), skalman (shell), skrift (editor), pensel (pixel-art editor), klick (mouse), oljud (Sound Blaster 16), lager (the ring-3 allocator), jit (JIT compiler), repl (REPL), syscall (ring-3 syscalls and the ELF loader), serial, interrupts, keyboard, vga (text-mode fallback), ata (disk). |
| `programs/` | The sources of the ring-3 programs the kernel carries: two syscall probes, Gnista's engine demo, the Infecteria game, a frame-rate probe, lira (the piano roll, with its noter song format and synth) in `programs/lira/`, and in `programs/utsikt/` the browser engine. `programs/lib/moon.c0` is the ring-3 library they include. Also `gen_sprite.c0`, which writes the demo's sprite. See [Programs](#programs). |
| `index_html.c0` | The two pages utsikt opens, seeded onto the filesystem at boot like the programs are. |
| `elf_tests/` | Sixteen small c0 programs compiled with `coff --elf` and run inside the OS by `verify_elf_backend.sh`, so ring-3 code is checked end to end. `gen_elf_tests.sh` packs them into one file the kernel embeds. |
| `boot.s` | The hand-written Multiboot entry stub that gets the CPU into 64-bit long mode before calling into c0-compiled code. |
| `ring3_handlers.s` | Ring-3 entry and exit trampolines (syscall/sysret and iretq). |
| `linker.ld` | The linker script that places the kernel at 1 MiB. |
| `build.sh` | Verifies the compiler and the assembler, then builds `moonshot.elf`. |
| `sync_utsikt.sh` | Pulls a newer utsikt into `programs/utsikt/` from its own repository, or checks that the copy here matches it. See [Programs](#programs). |
| `gen_programs.sh`, `gen_elf_tests.sh`, `bake.c0` | Compile the ring-3 programs into `build/`, and pack the elf_tests into one file there, for the kernel to embed. `build.sh` runs them. `bake` is a c0 program, built by the same `coff1` and `smed` as the kernel. |
| `run_qemu.sh` | The main regression gate. Builds, boots headlessly, and asserts invariants on the serial log. |
| `test_*.sh`, `verify_*.sh` | Thirty-seven more test scripts; see [Testing](#testing). |
| `run_suite.sh` | Runs every test script against a snapshot of the tree, several at a time. |
| `run_graphical.sh` | Boots the kernel in a real QEMU window you can type and click in. |
| `screenshot.sh` | Boots headlessly and dumps the framebuffer to `screenshots/` as a PNG. |
| `grub.cfg` | The GRUB menu entry. |
| `LICENSE` | GPL-3.0. |

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
linker. This release needs coff v0.5.0 or later, the first with `%`, the
bitwise operators, `embed`, `-I` and the syscalls lager, oljud and lira use.
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
./run_graphical.sh   # a real QEMU window (needs qemu-ui-gtk on Arch)
```

Both create `disk.img` if it does not exist. Log in as `root` with an empty
password; `help` lists the shell commands, `help (command)` explains one.
Some things to try: `edit notes.txt`, `draw hero.spr`, `spawn3 gnista.elf`
or `spawn3 infecteria.elf` for a graphical program in its own window,
`spawn3 utsikt.elf` for the browser (click a link, Backspace goes back),
`spawn3 lira.elf` for the piano roll (click to place a note, Space plays), `split` and
`Alt+Tab` for more windows, `Alt+W` to close a program's window, `mouse` to
watch the pointer, `eval 6 * 7` for the REPL.

`run_graphical.sh` forces QEMU's GTK window through XWayland. Under native
Wayland, GTK delivers clicks to a relative-pointer guest but almost no motion,
which looks exactly like a broken mouse driver and is not one.

## Testing

```sh
./run_qemu.sh                 # the main gate: boot + about 40 serial-log invariants
./test_keyboard.sh            # typing, caps lock, tab, alt-tab window switching
./test_shell.sh               # spawn, kill, task lifecycle
./test_repl.sh                # REPL expressions, JIT compilation, run-file
./test_disk.sh                # filesystem write, sync, reload, read-back
./test_disk_gap.sh            # a file in a directory survives a reboot after a removal
./test_disk_compat.sh         # a disk written by an older jakel still loads
./test_shell_paths.sh         # write, echo --file and remove take paths
./test_panic.sh               # divide-by-zero panic with correct vector
./test_doublefault.sh         # double fault caught on the IST1 stack
./test_fb_scroll.sh           # framebuffer scroll correctness
./test_kakel_scroll.sh        # window scroll clipping
./test_vga_scroll.sh          # VGA text-mode fallback scroll
./verify_elf_backend.sh       # the sixteen elf_tests/ programs run in ring 3, exit codes checked
./verify_alloc.sh             # layout + sizeof + alloc() from ring 3
./verify_ticks.sh             # ticks() from ring 3
./verify_windowed_ring3.sh    # a ring-3 program printing into its own window
./verify_gnista.sh            # the engine demo drawing real pixels
./verify_tavla.sh             # graphical windows: focus strip, Alt+W, recovery
./verify_resize.sh            # a graphical program surviving a window resize
./verify_klick.sh             # the mouse driver, packet decoding, pointer drawing
./verify_login_reset.sh       # a fresh window never inherits a login
./verify_mouse.sh             # click-to-focus, and the mouse syscall from ring 3
./verify_infecteria.sh        # the game draws its sprites and a cell can be infected
./verify_infecteria_scenes.sh # title, play, end screen, play again, quit
./verify_pensel.sh            # drawing a two-frame sprite and saving it
./verify_oljud.sh             # the sound driver, checked by recording what it plays
./verify_lira_synth.sh        # the synth plays two notes at once at the right pitches
./verify_lira.sh              # the piano roll, from the screen and the sound card
./verify_utsikt.sh            # the browser renders a page, scrolls, and scrolls back
./verify_utsikt_resize.sh     # the browser re-wraps its text when its window resizes
./verify_utsikt_links.sh      # clicking a link loads another page, Backspace comes back
./verify_utsikt_descendant.sh # descendant selectors in the cascade
./verify_utsikt_address.sh    # the address line says which page is open
./verify_utsikt_margins.sh    # adjacent vertical margins collapse
./verify_utsikt_table.sh      # a table is laid out as a grid
./verify_utsikt_img.sh        # <img> draws a sprite in the line like a word
./verify_utsikt_reload.sh     # reloading a page gives its memory back
```

`./run_suite.sh` runs all of them against a snapshot of the tree, three at a
time, in about five minutes, so the tree can be edited while it runs.

Every script boots the kernel in QEMU and passes or fails on what the serial
log or the framebuffer actually contains. The scripts that inject code into
the kernel (panic, double fault, the three scroll tests) restore the original
sources via a trap handler, so the tree is clean after they finish, pass or
fail. Several tests assume `disk.img` exists; run `run_qemu.sh` first.

## Programs

moonshot has no way to receive a file from the host, so every ring-3 program
it ships is compiled with `coff --elf` into `build/`, embedded in the kernel
with c0's `embed`, and written onto the filesystem at boot. `build.sh` does
this on every build from the sources in `programs/`, with the same `coff1`
and `smed` that build the kernel, so the kernel can never carry an older
build of a program than its source, and there is nothing generated to
commit. `gen_elf_tests.sh` does the same for `elf_tests/`, packing them into
one file with `bake`, which is compiled from `bake.c0` on the spot, so
nothing between the sources and the kernel image is python.

Gnista, the game engine the demo and Infecteria are built on, is its own
project; the copies in `programs/` are what the kernel is built from.

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
No GNU tool and no python touches the kernel any more; `as` and `ld` are
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
