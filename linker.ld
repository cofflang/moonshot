/* linker.ld — part of the moonshot operating system.
 *
 * Copyright (C) 2026 tavro
 *
 * This file is part of moonshot, an operating system built from scratch.
 * moonshot is free software, distributed under the GNU General Public
 * License version 3 or (at your option) any later version, WITHOUT ANY
 * WARRANTY; see the LICENSE file for the full text.
 */

/* Places the kernel at 1MiB, the conventional Multiboot load address.
 * ENTRY(_boot_start) sets the ELF entry point QEMU's multiboot loader
 * jumps to -- see boot.s for why it is not `_start` (coff-compiled object
 * files always define their own unused one).
 *
 * Section order below is deliberate: all PROGBITS (real file content)
 * sections first, all NOBITS (.bss-style, zero-fill-at-load, no file
 * space) sections last. Interleaving them makes the linker pad the FILE
 * to preserve the address-vs-offset relationship across each NOBITS gap,
 * which silently reinflates file offsets even though NOBITS sections are
 * supposed to be free. That can push .multiboot's file offset past the
 * Multiboot spec's 8192-byte limit, and GRUB then silently fails to find
 * the header, with zero serial output and no error. */
ENTRY(_boot_start)

SECTIONS
{
    . = 1M;

    /* Fixed hand-off slot, pinned as its own section so its address (1M,
     * decimal 1048576) never shifts regardless of any other section's
     * size. boot.s writes the Multiboot info pointer (from EBX at kernel
     * entry) here as its very first instruction; kmain.c0 reads it back
     * via that hardcoded literal address, since `main` cannot take
     * parameters (coff0.c requires zero) -- see kmain.c0. */
    .mbinfo :
    {
        LONG(0)
        LONG(0)
    }

    /* RESERVED, unused. The space is kept so the data slots after it stay
     * where boot.s's literal addresses expect them. */
    .isrinfo :
    {
        LONG(0)
        LONG(0)
        LONG(0)
        LONG(0)
    }

    /* The IDTR pseudo-descriptor (2-byte limit + 8-byte base -- 16 bytes
     * reserved for alignment, only 10 used). kmain.c0 builds it here (its
     * own address is a hardcoded literal, same as every other fixed slot),
     * boot.s's `lidt [addr]` reads it after main() returns. A dedicated
     * section rather than reusing a scratch buffer, since serial_print_int
     * uses one, and if anything printed *after* this got built
     * but *before* boot.s's lidt ran, it would silently overwrite the
     * IDTR's bytes out from under it -- a real hazard worth a whole
     * section to avoid rather than a "just do not print after this point"
     * convention someone could violate accidentally. */
    .idtr :
    {
        LONG(0)
        LONG(0)
        LONG(0)
        LONG(0)
    }

    /* Fixed hand-off slot for the physical address of the page tables
     * kmain.c0 builds (paging_init). Same problem/solution as .idtr, in the
     * same direction: c0 constructs the PML4 hierarchy in memory and writes
     * its root address here; boot.s reads it back and does the actual
     * `mov cr3` (c0 cannot execute that instruction) after main() returns.
     * One quad (8 bytes) -- only the PML4 physical address. */
    .cr3info :
    {
        LONG(0)
        LONG(0)
    }

    /* RESERVED, unused. The space is kept so the data slots after it stay
     * where boot.s's literal addresses expect them. */
    .excinfo :
    {
        . = . + 64;
    }

    /* chrone (scheduler) state for preemptive scheduling, 64 bytes, 8
     * slots of 8 bytes. [0], [1] and [5] are unused and kept so nothing
     * after them moves. [2] SCHED_SAVE_SLOT_ADDR is the address
     * isr_common should save the outgoing task's rsp into, written by
     * sched_tick (c0) before it requests a switch. [3] SCHED_NEXT_RSP is
     * the incoming task's saved rsp, for isr_common to load. [4]
     * SCHED_SWITCH_PENDING is 1 when a switch is requested, cleared by
     * isr_common once performed. [6] SCHED_NEXT_CR3 is the incoming task's
     * saved CR3, loaded by isr_common right after the rsp swap (see
     * chrone.c0's task_cr3_base), and [7] SCHED_NEXT_RSP0 is the incoming
     * task's kernel-stack top, loaded into TSS.RSP0 (see chrone.c0's
     * task_stack_base and ring3_handlers.s). These live at fixed addresses
     * rather than as c0 globals because isr_common (asm) reads and writes
     * them by a literal address. `sched_current` (which task is running)
     * is pure c0-side bookkeeping asm never touches, so it is an ordinary
     * c0 global instead. */
    .sched :
    {
        . = . + 64;
    }

    /* RESERVED, unused. The space is kept so the data slots after it stay
     * where boot.s's literal addresses expect them. */
    .excinfo2 :
    {
        . = . + 128;
    }

    /* RESERVED, unused. The space is kept so the data slots after it stay
     * where boot.s's literal addresses expect them. */
    .haltinfo :
    {
        . = . + 8;
    }

    /* Scancode-to-ASCII lookup tables (PS/2 scancode set 1, US QWERTY),
     * populated once at boot by keyboard.c0's scancode_init(), which finds
     * them through the sctable_start symbol. Two flat
     * 256-byte byte arrays, unshifted then shifted (index = make code, 0 =
     * "no printable character" for keys that are not letters/digits/
     * punctuation) -- a genuine fixed-address buffer, not a scratch reuse
     * or alloc(), for the same reason every other kernel-side buffer here
     * is. alloc() is syscall-backed and unusable in ring 0, and c0 has no
     * array-literal syntax to build this at compile time, only store8 calls
     * at runtime against a real address. 512 bytes total (2 x 256). */
    .sctable :
    {
        sctable_start = .;
        . = . + 512;
    }

    .multiboot :
    {
        *(.multiboot)
    }

    .text :
    {
        *(.text)
    }

    .ring3_text :
    {
        *(.ring3_text)
    }

    .rodata :
    {
        *(.rodata)
    }

    .data :
    {
        *(.data)
    }

    .bss :
    {
        *(.bss)
        *(COMMON)
    }

    /* Fixed scratch buffer for kernel code that needs a byte buffer
     * without calling alloc(). Placed AFTER .bss so these NOBITS
     * sections land in LOAD segment 1 instead of LOAD segment 0,
     * isolating their addresses from .text size changes. */
    .scratch :
    {
        /* One fixed buffer per user, each named and sized, so no caller can
         * overwrite another's bytes, as callers sharing one buffer at
         * hand-picked offsets can (a path built in it overwritten by the
         * code reading that path, or the shell's user table one long
         * `echo --file` away from being overwritten). Fixed rather than kmalloc'd
         * because serial output runs before the heap exists and inside
         * interrupt handlers, where the heap must not be touched. */
        serial_scratch = .;     . = . + 64;    /* serial.c0 -- number digits */
        punkt_scratch = .;      . = . + 64;    /* punkt.c0 -- number digits */
        kakel_scratch = .;      . = . + 64;    /* kakel.c0 -- number digits */
        skrift_scratch = .;     . = . + 64;    /* skrift.c0 -- "// => N" and digits */
        jakel_name_scratch = .; . = . + 64;    /* jakel_open -- one path component */
        jakel_path_scratch = .; . = . + 1024;  /* jakel_where -- a whole path */
        repl_scratch = .;       . = . + 16;    /* repl.c0 -- token count out-parameter */
        shell_scratch = .;      . = . + 1040;  /* skalman.c0 -- digits, names, completion, echo --file */
        shell_users = .;        . = . + 128;   /* skalman.c0 -- the user table (persistent) */
        shell_mirror = .;       . = . + 256;   /* skalman.c0 -- the line being mirrored to serial */
        elf_scratch = .;        . = . + 256;   /* syscall.c0 -- built-in test binaries */
    }

    .idt :
    {
        idt_start = .;
        . = . + 4096;
    }

    .dispatch :
    {
        dispatch_start = .;
        . = . + 2048;
    }

    _kernel_end = .;
}
