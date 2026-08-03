# moonshot

moonshot is an operating system I am building from scratch for x86_64. It
boots via Multiboot + GRUB in QEMU, has preemptive multitasking with a
round-robin scheduler, its own pixel framebuffer and font renderer, a tiled
windowing layer, an interactive shell with a built-in editor, a REPL with a
JIT compiler, a disk-backed filesystem, and ring-3 userspace with syscall
support. The kernel is written in **c0**, a small systems language whose
compiler, coff, is a separate project in the same stack.

The end goal is an OS with a real graphical interface and its own windowing
system, not a serial-only kernel. Right now it runs headless in QEMU for
automated testing; there is also a graphical mode you can interact with by
hand.

## What is in the repository

| Path | What it is |
|------|------------|
| `kmain.c0` | The kernel entry point. It `include`s every other `.c0` subsystem file, so coff compiles one flat translation unit. |
| `*.c0` | The kernel subsystems: knekt (core), jenna (memory/paging), chrone (scheduler), jakel (filesystem), kakel (windowing), punkt (framebuffer + font), skalman (shell), skrift (editor), jit (JIT compiler), repl (REPL), serial, interrupts, keyboard, syscall, vga (text-mode fallback), ata (disk). |
| `boot.s` | The hand-written Multiboot entry stub that gets the CPU into 64-bit long mode before calling into c0-compiled code. |
| `ring3_handlers.s` | Ring-3 entry and exit trampolines (syscall/sysret and iretq). |
| `linker.ld` | The linker script that places the kernel at 1 MiB. |
| `build.sh` | Builds `moonshot.elf` from all of the above. |
| `sync_addrs.sh` | Patches the JIT helper function addresses into `kmain.c0` after linking. Needed when any code changes size. |
| `run_qemu.sh` | The main regression gate. Builds, boots headlessly, and asserts invariants on the serial log. |
| `test_*.sh` | Nine test scripts that cover the keyboard, shell, panic, double fault, disk, REPL, and three scroll paths. |
| `grub.cfg` | The GRUB menu entry. |
| `moonshot.iso` | Pre-built bootable ISO. Included temporarily while the released coff lacks the `extern` keyword needed to build from source. |
| `LICENSE` | GPL-3.0. |

## Building

You need Linux on x86_64, and these packages on Arch (`apt` names vary):

- `qemu-system-x86` — for booting the kernel
- `grub`, `libisoburn`, `mtools` — for `grub-mkrescue` (building the bootable ISO)
- `as` and `ld` from binutils
- `python3` — for the QEMU monitor `sendkey` scripts the tests use
- `bash`, `sed`, `awk`, `dd`, `timeout` — standard system tools

The kernel is compiled by `coff1`, the self-hosted c0 compiler. That compiler
lives in its own repository, and this one expects to find it at `../c0-coff/`
next to the moonshot directory.

**Important:** the latest release of coff on GitHub does not yet include the
`extern` keyword that Moonshot needs to resolve linker symbols. Until coff's
next release, you cannot build Moonshot from source using the released coff.
A pre-built `moonshot.iso` is included in this repository so you can boot the
OS right away.

```sh
# 1. clone both repositories side by side
git clone git@github.com:cofflang/coff.git c0-coff
git clone git@github.com:cofflang/moonshot.git moonshot

# 2. bootstrap coff (one-time, needs gcc)
cd c0-coff
gcc -Wall -Wextra -o coff0 coff0.c
./coff0 c0/coff.c0 coff1.s
as coff1.s -o coff1.o
ld coff1.o -o coff1

# 3. build moonshot
cd ../moonshot
./build.sh
./sync_addrs.sh
```

After step 2 you do not need gcc anymore. `build.sh` checks whether
`coff1` is stale and rebuilds it automatically if it is, so you normally
only need `./build.sh && ./sync_addrs.sh`.

## Running

If you cannot build from source yet (see the note above about coff's
`extern` keyword), boot the pre-built ISO directly:

```sh
# headless (serial console only)
qemu-system-x86_64 -cdrom moonshot.iso -display none -no-reboot \
  -serial file:serial.log -m 128 -drive file=disk.img,format=raw,if=ide,index=0,media=disk

# interactive graphical window (needs qemu-ui-gtk on Arch)
qemu-system-x86_64 -cdrom moonshot.iso -display gtk -m 128 \
  -drive file=disk.img,format=raw,if=ide,index=0,media=disk
```

Create the disk image first if it does not exist:

```sh
dd if=/dev/zero of=disk.img bs=512 count=20480
```

Once you have a working coff with `extern`, the full build-and-test flow is:

```sh
# headless boot with invariant checks (the main regression gate)
./run_qemu.sh
```

`run_qemu.sh` builds the kernel, creates a disk image if one does not exist,
makes a bootable ISO with grub-mkrescue, boots it in QEMU headlessly for 5
seconds, and then checks the serial log for about 40 invariants: the boot
banner, memory map, physical page allocator correctness, heap behaviour,
page tables, demand paging, scheduler round-robin fairness, framebuffer
pixel readback, windowing layer layout, ATA detection, filesystem load, and
timer ticks. On any failure it dumps the full serial log and exits non-zero.

## Testing

```sh
./run_qemu.sh          # the main gate: boot + invariant check
./test_keyboard.sh     # typing, caps lock, tab, alt-tab window switching
./test_shell.sh        # spawn, kill, task lifecycle
./test_repl.sh         # REPL expressions, JIT compilation, run-file
./test_disk.sh         # filesystem write, sync, reload, read-back
./test_panic.sh        # divide-by-zero panic with correct vector
./test_doublefault.sh  # double fault caught on the IST1 stack
./test_fb_scroll.sh    # framebuffer scroll correctness
./test_kakel_scroll.sh # window scroll clipping
./test_vga_scroll.sh   # VGA text-mode fallback scroll
```

The test scripts that inject code into the kernel (panic, double fault, and
the three scroll tests) restore the original sources via a trap handler, so
the tree is always clean after they finish, pass or fail.

Several tests assume `disk.img` already exists. Run `run_qemu.sh` or
`test_disk.sh` first to create it.

## Contributing

Contributions are welcome. Some things to know before opening a pull
request:

- The kernel is compiled exclusively through `coff1`, the self-hosted c0
  compiler. Any new c0 language feature or builtin needed here must land in
  coff first (in `coff0.c`, then mirrored into `c0/coff.c0`, differentially
  verified).
- `./run_qemu.sh` and the test scripts must stay green.
- After any change that shifts code size, run `./sync_addrs.sh` before
  booting. The kernel will silently crash at boot with stale JIT helper
  addresses.
- Keep it minimal. No new dependencies, no third-party code.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

Copyright (C) 2026 tavro
