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
 * jumps to -- see boot.s for why it's not `_start` (coff-compiled object
 * files always define their own unused one).
 *
 * Section order below is deliberate: all PROGBITS (real file content)
 * sections first, all NOBITS (.bss-style, zero-fill-at-load, no file
 * space) sections last. Interleaving them -- as an earlier version of
 * this file did -- makes the linker pad the FILE to preserve the
 * address-vs-offset relationship across each NOBITS gap, which silently
 * reinflates file offsets even though NOBITS sections are supposed to be
 * free. That's exactly what pushed .multiboot's file offset past the
 * Multiboot spec's 8192-byte limit a second time (the first time was a
 * plain `. = ` jump creating a gap; this was the same symptom from a
 * different cause) -- GRUB silently failed to find the header, zero
 * serial output, no error either time. */
ENTRY(_boot_start)

SECTIONS
{
    . = 1M;

    /* Fixed hand-off slot, pinned as its own section so its address (1M,
     * decimal 1048576) never shifts regardless of any other section's
     * size. boot.s writes the Multiboot info pointer (from EBX at kernel
     * entry) here as its very first instruction; kmain.c0 reads it back
     * via that hardcoded literal address, since c0 has no way to
     * reference a linker-defined symbol by name and `main` can't take
     * parameters (coff0.c requires zero) -- see kmain.c0. */
    .mbinfo :
    {
        LONG(0)
        LONG(0)
    }

    /* Fixed hand-off slot for the ISR trampoline entry addresses (see
     * boot.s's isr_timer_entry/isr_keyboard_entry): same problem .mbinfo
     * solves, in reverse -- kmain.c0 needs these addresses as data VALUES
     * (to write into the IDT), but c0 has no way to reference an
     * externally-defined (hand-written-asm) symbol at all, not even via
     * the function-reference feature (that only covers functions declared
     * in the same c0 file). boot.s resolves each symbol via `lea` (the
     * assembler/linker already know their addresses) and stashes them
     * here; kmain.c0 reads them back via hardcoded literals, same pattern
     * as .mbinfo. Two quads: [0] isr_timer_entry, [8] isr_keyboard_entry. */
    .isrinfo :
    {
        LONG(0)
        LONG(0)
        LONG(0)
        LONG(0)
    }

    /* The IDTR pseudo-descriptor (2-byte limit + 8-byte base -- 16 bytes
     * reserved for alignment, only 10 used): kmain.c0 builds it here (its
     * own address is a hardcoded literal, same as every other fixed slot),
     * boot.s's `lidt [addr]` reads it after main() returns. A dedicated
     * section rather than reusing .kscratch's buffer: serial_print_int
     * also uses .kscratch, and if anything printed *after* this got built
     * but *before* boot.s's lidt ran, it would silently overwrite the
     * IDTR's bytes out from under it -- a real hazard worth a whole
     * section to avoid rather than a "just don't print after this point"
     * convention someone could violate accidentally later. */
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
     * `mov cr3` (c0 can't execute that instruction) after main() returns.
     * One quad (8 bytes) -- only the PML4 physical address. */
    .cr3info :
    {
        LONG(0)
        LONG(0)
    }

    /* Fixed hand-off slots for the addresses of the CPU-exception ISR
     * trampolines that live in boot.s. Same problem/solution as .isrinfo --
     * kmain.c0 needs each hand-written-asm stub's address as a data value to
     * write into the IDT, but c0 can't reference an externally-defined
     * symbol; boot.s `lea`s each and stashes it here, kmain.c0 reads them
     * back via hardcoded literals. Slots (8 bytes each): [0]
     * isr_pagefault_entry, [1] isr_divide_entry, [2] isr_invalidop_entry,
     * [3] isr_gpf_entry. 64 bytes (8 slots) leaves headroom for more. */
    .excinfo :
    {
        . = . + 64;
    }

    /* chrone (scheduler) hand-off + state for preemptive scheduling.
     * Slots (8 bytes each): [0] task 0's saved full-interrupt-frame rsp;
     * [1] task 1's saved full-interrupt-frame rsp; [2] SCHED_SAVE_SLOT_ADDR
     * -- the address isr_common should save the outgoing task's rsp into,
     * written by sched_tick (c0) before it requests a switch; [3]
     * SCHED_NEXT_RSP -- the incoming task's saved rsp, for isr_common to
     * load; [4] SCHED_SWITCH_PENDING -- 1 when a switch is requested,
     * cleared by isr_common once performed; [5] the address of boot.s's
     * `sched_launch` routine (c0 can't call an externally-defined asm
     * symbol by name, only indirectly through a value -- same wall as
     * lidt/sti -- so boot.s `lea`s it here and c0 calls through it once, to
     * launch the first task). These live at fixed addresses rather than as
     * c0 globals because isr_common (asm) needs to read/write them by a
     * literal address, and c0 has no address-of for variables -- same
     * reasoning as every other hand-off here. `sched_current` (which task
     * is running) is pure c0-side bookkeeping asm never touches, so it's an
     * ordinary c0 global instead, not a slot here. 64 bytes (8 slots)
     * leaves 2 free for more tasks later. */
    .sched :
    {
        . = . + 64;
    }

    /* Second batch of exception-trampoline hand-off slots (same
     * problem/solution as .excinfo above), added when the remaining CPU
     * exception vectors got pointed at the generic panic_handler. Placed as
     * a NEW section *after* .sched rather than by growing .excinfo in place
     * -- growing .excinfo would have shifted .sched (and every hardcoded
     * SCHED_* literal in kmain.c0/boot.s along with it), touching the
     * scheduler's preemption code for no real reason; appending here
     * instead means .mbinfo/.isrinfo/.idtr/.cr3info/.excinfo/.sched all
     * keep their exact existing addresses. Slots (8 bytes each), in vector
     * order: [0] #1 Debug, [1] #2 NMI, [2] #3 Breakpoint, [3] #4 Overflow,
     * [4] #5 Bound Range, [5] #7 Device Not Available, [6] #10 Invalid TSS,
     * [7] #11 Segment Not Present, [8] #12 Stack-Segment Fault, [9] #16 x87
     * FPU Error, [10] #17 Alignment Check, [11] #18 Machine Check, [12] #19
     * SIMD FP Exception. 128 bytes (16 slots) leaves 3 free -- #8 (double
     * fault, needs a dedicated IST stack, deliberately not installed yet),
     * #9 and #15 are reserved/obsolete vectors Intel says not to use, so
     * there's nothing left in 0-31 to add here. */
    .excinfo2 :
    {
        . = . + 128;
    }

    /* Fixed hand-off slot for boot.s's `halt_cpu` (hlt; ret) routine's
     * address -- same "c0 can't call an externally-defined asm symbol by
     * name" wall as .sched's sched_launch/context_switch slots, solved the
     * same way: boot.s `lea`s it here, kmain.c0 reads it back and calls it
     * indirectly (see kmain.c0's halt()). Lets panic_handler genuinely idle
     * the CPU instead of busy-spinning while intentionally frozen. One quad
     * (8 bytes) -- there's only ever the one halt routine. */
    .haltinfo :
    {
        . = . + 8;
    }

    /* Scancode-to-ASCII lookup tables (PS/2 scancode set 1, US QWERTY),
     * populated once at boot by kmain.c0's scancode_init(). Two flat
     * 256-byte byte arrays, unshifted then shifted (index = make code, 0 =
     * "no printable character" for keys that aren't letters/digits/
     * punctuation) -- a genuine fixed-address buffer, not a .kscratch reuse
     * or alloc(), for the same reason every other kernel-side buffer here
     * is: alloc() is syscall-backed and unusable in ring 0, and c0 has no
     * array-literal syntax to build this at compile time, only store8 calls
     * at runtime against a real address. 512 bytes total (2 x 256). */
    .sctable :
    {
        . = . + 512;
    }

    /* Fixed hand-off slot for boot.s's isr_doublefault_entry (#8 double-fault)
     * trampoline address -- same problem/solution as .excinfo/.excinfo2. Placed
     * AFTER .sctable (the last fixed-slot section) specifically so no address
     * before it shifts, in particular the hand-maintained
     * SCANCODE_TABLE_ADDR/SCANCODE_SHIFT_TABLE_ADDR literals in kmain.c0 (which
     * sync_addrs.sh does NOT cover). One quad. */
    .dfinfo :
    {
        . = . + 8;
    }

    /* Fixed hand-off slot for the ring-3 trampoline addresses.
     * boot.s stashes enter_ring3's address here; kmain.c0 reads it back
     * via hardcoded literal (same pattern as .isrinfo/.excinfo).
     * Two quads: [0] enter_ring3, [8] syscall_entry (future use). */
    .ring3info :
    {
        . = . + 16;
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
    .kscratch :
    {
        kscratch_start = .;
        . = . + 2048;
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
