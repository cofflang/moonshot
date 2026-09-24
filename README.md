# moonshot

moonshot is an operating system I am building from scratch for x86_64. It
boots via Multiboot + GRUB in QEMU, has preemptive multitasking with a
round-robin scheduler, its own pixel framebuffer and font renderer, a tiled
windowing layer, a login gate, an interactive shell with a built-in text
editor and pixel-art editor, a REPL with a JIT compiler, a disk-backed
filesystem, a PS/2 mouse driver, and ring-3 userspace: real ELF64 programs
with their own page tables, loaded from the filesystem and given a window of
their own, among them a small game engine and a browser engine that renders
HTML and CSS off the filesystem. The kernel is written in **c0**, a small systems language whose
compiler, coff, is a separate project in the same stack.

The end goal is an OS with a real graphical interface and its own windowing
system, not a serial-only kernel. Every test runs headless in QEMU and reads
the serial log or the framebuffer; there is also a graphical mode you can sit
in front of.

## What is in the repository

| Path | What it is |
|------|------------|
| `kmain.c0` | The kernel entry point. It `include`s every other `.c0` subsystem file, so coff compiles one flat translation unit. |
| `*.c0` | The kernel subsystems: knekt (core), jenna (memory/paging), chrone (scheduler), jakel (filesystem), kakel (windowing), punkt (framebuffer + font), raket (init and login), skalman (shell), skrift (editor), pensel (pixel-art editor), klick (mouse), jit (JIT compiler), repl (REPL), syscall (ring-3 syscalls and the ELF loader), serial, interrupts, keyboard, vga (text-mode fallback), ata (disk). |
| `*_data.c0` | Generated. The ring-3 programs the kernel seeds onto the filesystem at first boot, as byte arrays. Every one is rebuilt from source by `gen_programs.sh`; see [Baked-in programs](#baked-in-programs). |
| `programs/` | The sources of those programs: two syscall probes, Gnista's engine demo, the Infecteria game, a frame-rate probe and utsikt, the browser engine. Also `gen_sprite.c0`, which writes the demo's sprite. |
| `index_html.c0` | The two pages utsikt opens, seeded onto the filesystem at boot like the programs are. |
| `elf_tests/` | Eleven small c0 programs compiled with `coff --elf` and run inside the OS by `verify_elf_backend.sh`, so ring-3 code is checked end to end. `gen_elf_tests.sh` bakes them into `elf_tests_data.c0`. |
| `boot.s` | The hand-written Multiboot entry stub that gets the CPU into 64-bit long mode before calling into c0-compiled code. |
| `ring3_handlers.s` | Ring-3 entry and exit trampolines (syscall/sysret and iretq). |
| `linker.ld` | The linker script that places the kernel at 1 MiB. |
| `build.sh` | Verifies the compiler and the assembler, then builds `moonshot.elf`. |
| `sync_addrs.sh` | Patches the JIT helper function addresses into `kmain.c0` after linking, reading them from `moonshot.map`. Needed when any code changes size. |
| `bake.c0`, `gen_programs.sh`, `gen_elf_tests.sh` | Turn compiled programs into the `*_data.c0` byte arrays. `bake` is a c0 program, built by the same `coff1` and `smed` as the kernel. |
| `run_qemu.sh` | The main regression gate. Builds, boots headlessly, and asserts invariants on the serial log. |
| `test_*.sh`, `verify_*.sh` | Twenty-seven more test scripts; see [Testing](#testing). |
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
linker. This release needs coff v0.4.0 or later, the first with the linker
script support the kernel build uses. No pre-built image is needed.

```sh
# 1. clone both repositories side by side
git clone git@github.com:cofflang/coff.git c0-coff
git clone git@github.com:cofflang/moonshot.git moonshot

# 2. build moonshot
cd moonshot
./build.sh
./sync_addrs.sh
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
`spawn3 utsikt.elf` for the browser (click a link, Backspace goes back), `split` and
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
./test_panic.sh               # divide-by-zero panic with correct vector
./test_doublefault.sh         # double fault caught on the IST1 stack
./test_fb_scroll.sh           # framebuffer scroll correctness
./test_kakel_scroll.sh        # window scroll clipping
./test_vga_scroll.sh          # VGA text-mode fallback scroll
./verify_elf_backend.sh       # the eleven elf_tests/ programs run in ring 3, exit codes checked
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
./verify_utsikt.sh            # the browser renders a page, scrolls, and scrolls back
./verify_utsikt_resize.sh     # the browser re-wraps its text when its window resizes
./verify_utsikt_links.sh      # clicking a link loads another page, Backspace comes back
./verify_utsikt_descendant.sh # descendant selectors in the cascade
./verify_utsikt_address.sh    # the address line says which page is open
./verify_utsikt_margins.sh    # adjacent vertical margins collapse
./verify_utsikt_table.sh      # a table is laid out as a grid
```

Every script boots the kernel in QEMU and passes or fails on what the serial
log or the framebuffer actually contains. The scripts that inject code into
the kernel (panic, double fault, the three scroll tests) restore the original
sources via a trap handler, so the tree is clean after they finish, pass or
fail. Several tests assume `disk.img` exists; run `run_qemu.sh` first.

## Baked-in programs

moonshot has no way to receive a file from the host, so every ring-3 program
it ships is compiled with `coff --elf`, turned into a c0 function that writes
the bytes into a buffer, and written onto the filesystem at first boot. Those
byte arrays are the `*_data.c0` files, and a byte array nobody can regenerate
is a binary blob with a c0 extension, so their sources are in `programs/` and

```sh
./gen_programs.sh
```

rebuilds all of them with the same `coff1` that builds the kernel. After it
runs, `git diff` on the `*_data.c0` files is empty. If it is not, either a
program changed or the compiler's output did, and either way you want to
know. `gen_elf_tests.sh` does the same for `elf_tests/`. The byte arrays
themselves are written by `bake`, which is compiled from `bake.c0` on the
spot, so nothing between the sources and the kernel image is python.

Gnista, the game engine the demo and Infecteria are built on, and utsikt, the
browser engine, are their own projects; the copies in `programs/` are what
these seeds were built from.

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
- After any change that shifts code size, run `./sync_addrs.sh` before
  booting. The kernel will silently crash at boot with stale JIT helper
  addresses.
- After changing anything in `programs/` or `elf_tests/`, regenerate the
  seeds and commit the result.
- Keep it minimal. No new dependencies, no third-party code.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

Copyright (C) 2026 tavro
