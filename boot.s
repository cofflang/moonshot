# boot.s — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# Hand-written (not c0-compiled) Multiboot entry stub.
#
# QEMU's `-kernel` loads this directly per the Multiboot(1) spec, which
# hands control off in 32-bit protected mode with paging disabled. c0/coff
# only ever emits 64-bit long-mode code (rax/rdi/..., 8-byte pushes), so
# this stub's whole job is the classic "get to long mode" dance before
# ever touching anything coff-compiled:
#   1. build a minimal identity-mapped page table for the first 1GB
#      (2MB pages -- one P2 table is enough, no P1 needed)
#   2. enable PAE, set EFER.LME, enable paging (CR0.PG)
#   3. load a 64-bit GDT and far-jump to reload CS with the long-mode
#      code descriptor -- this is the actual mode switch; steps 1-2 alone
#      leave the CPU in a hybrid state still executing the 32-bit segment
#   4. only then set up a real stack and `call main` -- kmain.c0's
#      compiled entry point (c0 requires a function literally named
#      `main`)
#
# Entry symbol is `_boot_start`, deliberately not `_start`: every object
# file coff0 emits already defines its own `_start` (a Linux-syscall
# epilogue that's dead code here, never called) -- a different name avoids
# a duplicate-symbol link error with zero changes to coff itself.

.intel_syntax noprefix

.set MB_MAGIC, 0x1BADB002
# Bit 2 (0x4): request a specific video mode -- GRUB won't set one up
# unprompted, since it's a real hardware mode-set, not passive info like
# mem_lower/mmap (which show up regardless of what's requested here). This
# adds four more header longs (mode_type/width/height/depth) below.
.set MB_FLAGS, 0x4
.set MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)
# mode_type 0 = linear graphics (a real pixel framebuffer), not 1 (EGA
# text -- Moonshot already has that, via VGA's own 0xB8000, with no
# mode-set needed). 1024x768x32 is a broadly-supported VBE mode, but GRUB
# is free to grant something close instead of exactly this -- kmain.c0
# reads back whatever was actually granted rather than assuming it matches.
.set MB_MODE_TYPE, 0
.set MB_WIDTH, 1024
.set MB_HEIGHT, 768
.set MB_DEPTH, 32

# "a" = allocatable. GAS only applies sensible default section flags to
# well-known names (.text/.data/.bss/.rodata/...); an unrecognized name
# like .multiboot otherwise gets NO flags at all -- not SHF_ALLOC, meaning
# it isn't a "real" loaded section as far as the linker's address-space
# bookkeeping is concerned. Without this, `ld` doesn't advance the
# location counter past it before the next (genuinely allocated) output
# section, silently overlapping .multiboot with .text at the same virtual
# address -- found only once the kernel grew enough to make the resulting
# file-offset drift cross the Multiboot spec's 8192-byte header-placement
# limit, at which point GRUB stopped finding the header at all (zero
# serial output, no error -- the same failure shape as every previous
# file-offset bug, different root cause each time).
.section .multiboot, "a"
.balign 4
.long MB_MAGIC
.long MB_FLAGS
.long MB_CHECKSUM
# The Multiboot1 header's fields sit at FIXED offsets regardless of which
# flag bits request them -- flags select which fields are MEANINGFUL, not
# where they live. The five "address fields" (header_addr..entry_addr,
# gated on flags bit 16, unused here since ELF loading already gives GRUB
# everything it needs) still occupy their slots even though bit 16 isn't
# set, so mode_type/width/height/depth land at offset 32, not immediately
# after the checksum. Getting this wrong the first time (omitting these
# five and putting mode_type right after checksum) produced a real,
# instructive failure: GRUB read 4 bytes of unrelated file content as
# mode_type and errored "unsupported graphical mode type 629997584" --
# found via an actual QEMU monitor screendump mid-boot (the only way to
# see GRUB's own text-mode error screen, since -display none/serial-only
# testing shows nothing before the kernel would start).
.long 0 # header_addr (unused, flags bit 16 not set)
.long 0 # load_addr
.long 0 # load_end_addr
.long 0 # bss_end_addr
.long 0 # entry_addr
.long MB_MODE_TYPE
.long MB_WIDTH
.long MB_HEIGHT
.long MB_DEPTH

# Page tables and the boot stack. In .bss so the ELF loader zero-inits
# them (QEMU's multiboot loader honors p_memsz > p_filesz like any other
# ELF loader) -- nothing here needs explicit zeroing code.
.section .bss
.balign 4096
p4_table:
    .skip 4096
p3_table:
    .skip 4096
p2_table:
    .skip 4096
.balign 16
stack_bottom:
    .skip 16384
stack_top:

# 64-bit Task State Segment. In long mode the TSS no longer holds a task
# context (there's no hardware task switching), but it still carries the
# Interrupt Stack Table: up to 7 known-good stack pointers a fault handler can
# be forced onto regardless of the interrupted code's own (possibly corrupt or
# non-canonical) rsp. Only IST1 is used, for #8 (double fault). 104 bytes is
# the architectural minimum; IST1 lives at offset 0x24. Zero-filled by the ELF
# loader (.bss); long_mode_start fills IST1 and builds the GDT descriptor.
.balign 16
.global tss64
tss64:
    .skip 104

# The dedicated stack #8 (double fault) runs on via IST1. A double fault means
# the normal stack may itself be the problem, so the handler MUST NOT try to use
# it -- this separate 4KB page is what makes a #DF catchable (panic + halt)
# instead of a silent triple-fault reboot.
.balign 16
df_stack_bottom:
    .skip 4096
df_stack_top:

.section .text
.code32
.global _boot_start
_boot_start:
    # Per the Multiboot1 spec, GRUB hands off with EBX = the physical
    # address of the Multiboot info structure. Stash it in the .mbinfo slot
    # (linker.ld pins that section's address at exactly 1M/1048576) before
    # touching anything else -- kmain.c0 reads it back from there via a
    # hardcoded literal address, since `main` can't take parameters
    # (coff0.c requires zero) and c0 has no way to reference a linker
    # symbol by name.
    mov dword ptr [0x100000], ebx

    lea esp, [stack_top]

    # P4[0] -> P3_table
    lea eax, [p3_table]
    or eax, 0b11              # present | writable
    lea edi, [p4_table]
    mov [edi], eax

    # P3[0] -> P2_table
    lea eax, [p2_table]
    or eax, 0b11
    lea edi, [p3_table]
    mov [edi], eax

    # P2[0..511] -> 2MB huge pages, identity-mapping the first 1GB
    mov ecx, 0
map_p2:
    mov eax, ecx
    imul eax, eax, 0x200000
    or eax, 0b10000011        # present | writable | huge(PS)
    lea edi, [p2_table]
    mov [edi + ecx*8], eax
    inc ecx
    cmp ecx, 512
    jne map_p2

    lea eax, [p4_table]
    mov cr3, eax

    mov eax, cr4
    or eax, 1 << 5             # PAE
    mov cr4, eax

    mov ecx, 0xC0000080        # EFER
    rdmsr
    or eax, 1 << 8             # LME
    or eax, 1 << 11            # NXE
    wrmsr

    mov eax, cr0
    or eax, 1 << 31            # PG -- IA-32e mode is active after this,
    mov cr0, eax               # but CS is still the 32-bit descriptor
                                # until the far jump below reloads it.

    lgdt [gdt64_pointer]
    jmp 0x08:long_mode_start

.code64
long_mode_start:
    mov ax, 0x10
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    lea rax, [df_stack_top]
    mov [tss64 + 0x24], rax

    lea rax, [tss64]
    mov word ptr [gdt64_tss], 0x67
    mov [gdt64_tss + 2], ax
    shr rax, 16
    mov [gdt64_tss + 4], al
    mov byte ptr [gdt64_tss + 5], 0x89
    mov byte ptr [gdt64_tss + 6], 0x00
    shr rax, 8
    mov [gdt64_tss + 7], al
    lea rax, [tss64]
    shr rax, 32
    mov [gdt64_tss + 8], eax
    mov dword ptr [gdt64_tss + 12], 0

    mov ax, 0x18
    ltr ax

    mov ecx, 0xC0000080
    rdmsr
    or eax, 1
    wrmsr

    mov ecx, 0xC0000081
    mov edx, 0x0020
    mov eax, 0x00080010
    wrmsr

    mov ecx, 0xC0000082
    lea rax, [syscall_entry]
    mov edx, eax
    shr rdx, 32
    wrmsr

    mov ecx, 0xC0000084
    mov eax, 1 << 9
    xor edx, edx
    wrmsr

    # Stash isr_timer_entry's and isr_keyboard_entry's addresses in the
    # .isrinfo hand-off slot (linker.ld pins it at 1048584/0x100008, two
    # consecutive quads) -- kmain.c0 needs these addresses as data values
    # to populate the IDT, but c0 has no way to reference an externally-
    # defined (hand-written-asm) symbol at all, not even via the function-
    # reference feature (that only covers functions declared in the same
    # c0 file). The assembler/linker already know these addresses; `lea`
    # gets them, same "resolve it once in asm, hand off through a fixed
    # memory slot" technique as .mbinfo (EBX), just in the other direction.
    lea rax, [isr_timer_entry]
    mov [0x100008], rax
    lea rax, [isr_keyboard_entry]
    mov [0x100010], rax
    # Same hand-off for the exception trampolines (.excinfo, base 1048624/
    # 0x100030) -- kmain.c0 reads these back to install IDT vectors 14 (#PF),
    # 0 (#DE), 6 (#UD), 13 (#GP). Slots are 8 bytes apart.
    lea rax, [isr_pagefault_entry]
    mov [0x100030], rax
    lea rax, [isr_divide_entry]
    mov [0x100038], rax
    lea rax, [isr_invalidop_entry]
    mov [0x100040], rax
    lea rax, [isr_gpf_entry]
    mov [0x100048], rax
    # Second batch of exception trampolines (.excinfo2, base 1048752/
    # 0x1000B0 -- placed after .sched, not by growing .excinfo, so none of
    # the addresses above shifted -- see linker.ld), for the remaining CPU
    # exception vectors now routed to the generic panic_handler. Slots are
    # 8 bytes apart, in vector order: #1 #2 #3 #4 #5 #7 #10 #11 #12 #16 #17
    # #18 #19.
    lea rax, [isr_debug_entry]
    mov [0x1000B0], rax
    lea rax, [isr_nmi_entry]
    mov [0x1000B8], rax
    lea rax, [isr_breakpoint_entry]
    mov [0x1000C0], rax
    lea rax, [isr_overflow_entry]
    mov [0x1000C8], rax
    lea rax, [isr_boundrange_entry]
    mov [0x1000D0], rax
    lea rax, [isr_devnotavail_entry]
    mov [0x1000D8], rax
    lea rax, [isr_invalidtss_entry]
    mov [0x1000E0], rax
    lea rax, [isr_segnotpresent_entry]
    mov [0x1000E8], rax
    lea rax, [isr_stackfault_entry]
    mov [0x1000F0], rax
    lea rax, [isr_fpuerror_entry]
    mov [0x1000F8], rax
    lea rax, [isr_alignment_entry]
    mov [0x100100], rax
    lea rax, [isr_machinecheck_entry]
    mov [0x100108], rax
    lea rax, [isr_simdfp_entry]
    mov [0x100110], rax
    # #8 double-fault trampoline hand-off (.dfinfo, 0x100338 -- a new section
    # after .sctable, so no earlier fixed address shifted). c0 reads this back
    # to install vector 8's IDT entry (with IST1 selected -- see knekt.c0).
    lea rax, [isr_doublefault_entry]
    mov [0x100338], rax
    # Ring-3 trampoline hand-off (.ring3info, 0x100340) — same pattern as
    # .isrinfo/.excinfo above. c0 reads enter_ring3's address back to call
    # it indirectly when launching a ring-3 binary.
    lea rax, [enter_ring3]
    mov [0x100340], rax
    # Hand sched_launch's address to c0 via the .sched slot (1048728/
    # 0x100098) -- c0 calls it indirectly, exactly once, to transfer control
    # into the first preemptive task (see kmain.c0's sched_launch_call).
    lea rax, [sched_launch]
    mov [0x100098], rax
    # Hand halt_cpu's address to c0 via the .haltinfo slot (0x100130) -- c0
    # calls it indirectly (see kmain.c0's halt()), the same wall/solution as
    # sched_launch above.
    lea rax, [halt_cpu]
    mov [0x100130], rax

    lea rsp, [stack_top]
    call main

    # main() also built a fresh 4-level page table (paging_init) from
    # jenna-allocated frames and left its PML4 physical address in the
    # .cr3info slot (1048616/0x100028). Switch to it now -- `mov cr3` is
    # privileged and c0 can't emit it, same reason lidt/sti are done here.
    # The new tables identity-map all the low memory the kernel runs on
    # (this .text, the stack at rsp, every fixed slot), so this instruction
    # and everything after it stay valid across the TLB flush. Then call
    # back into c0 to prove the switch is live (paging_verify reads a
    # sentinel through a high virtual address only these tables map) --
    # done before `sti` so nothing competes for the serial port.
    mov rax, [0x100028]
    mov cr3, rax
    call paging_verify

    # main() has finished building the IDT/IDTR/PIC/PIT/dispatch-table
    # state in memory (pure c0: memory writes and outb, no new
    # instructions needed) and returned. Loading the IDT and enabling
    # interrupts needs `lidt`/`sti`, which c0 can't execute directly --
    # rather than exposing them as separate asm functions callable from c0
    # (which would need c0 to call an externally-defined symbol, a problem
    # coff0's resolve() has no path for: the only recognized calls are
    # builtins, functions declared in the same c0 file, or indirect calls
    # through a variable -- none of which fit "trust me, this exists in
    # another object file"), boot.s just does them itself right here,
    # reading the IDTR structure from the same fixed address (.idtr,
    # 1048600/0x100018) that kmain.c0 wrote it to. Simpler than adding an
    # extern-declaration concept to c0 for two instructions.
    lidt [0x100018]

    # Run post-init kernel work that depends on a live IDT but must NOT race
    # hardware IRQs on the shared serial scratch buffer: the demand-paging
    # test deliberately faults, and CPU exceptions (#PF) fire regardless of
    # the interrupt flag, so it works with IRQs still masked. sti comes
    # after, once the one-shot fault test is done.
    call kernel_post_init

    # sched_start crafts two tasks' stacks and hands
    # off to sched_launch, which iretqs into task 0 with interrupts already
    # enabled (RFLAGS' IF bit is set in the crafted frame -- see
    # sched_craft_stack) -- there's no explicit `sti` in this path at all,
    # unlike the old cooperative demo. sched_start therefore never returns
    # in normal operation; every subsequent task switch happens transparently
    # inside the timer ISR (isr_common). The hang loop below is unreachable
    # in normal operation -- kept as a trap in case a crafted frame is ever
    # wrong and iretq's return path doesn't behave as expected, rather than
    # falling through into whatever bytes follow in the binary.
    call sched_start
hang:
    hlt
    jmp hang

# Two thin per-vector stubs funneling into one shared trampoline
# (isr_common), rather than a full register-save/restore/iretq per
# handled interrupt: each just pushes its own vector number (plus 8 bytes
# of alignment padding -- see isr_common's comment for why) and jumps into
# the shared body, which reads the vector back off the stack and calls a
# single c0 dispatcher (int_dispatch) that looks the real handler up in a
# function-reference table (dispatch_set()/int_dispatch() in kmain.c0) --
# the actual load-bearing use of the address-of/indirect-call feature (the
# IDT itself didn't end up needing it). Adding a third interrupt means one
# more two-line stub here plus one dispatch_set() call in kmain.c0, not a
# whole new register-save block.
.global isr_timer_entry
isr_timer_entry:
    push 0
    push 32
    jmp isr_common

.global isr_keyboard_entry
isr_keyboard_entry:
    push 0
    push 33
    jmp isr_common

# Page fault (#PF, vector 14) -- a CPU exception, not a hardware IRQ. The
# CPU pushes a real error code before entering here, so unlike the IRQ stubs
# above this one does NOT push a dummy 0: it only pushes the vector, leaving
# the stack in the exact same [vector][error-code][RIP...] shape isr_common
# expects. (Alignment still works out: in 64-bit mode the CPU's own frame is
# 40 bytes -- SS/RSP/RFLAGS/CS/RIP, all 5 pushed unconditionally, see
# isr_common. For IRQs the stub adds a dummy errcode + vector, 16 more; for
# #PF the CPU also pushed a real error code and the stub pushes only the
# vector, 8 more -- both land the same 56 bytes above orig_rsp, so after
# isr_common's 120-byte register save RSP is 16-aligned either way when
# orig_rsp was.)
.global isr_pagefault_entry
isr_pagefault_entry:
    push 14
    jmp isr_common

# Fatal-exception stubs routed to the generic panic_handler (via the
# dispatch table). #DE (0) and #UD (6) push NO CPU error code, so like the
# IRQ stubs they push a dummy 0 first to keep isr_common's uniform
# [vector][error-code] frame; #GP (13) pushes a real error code, so its stub
# (like #PF) pushes only the vector.
.global isr_divide_entry
isr_divide_entry:
    push 0
    push 0
    jmp isr_common

.global isr_invalidop_entry
isr_invalidop_entry:
    push 0
    push 6
    jmp isr_common

.global isr_gpf_entry
isr_gpf_entry:
    push 13
    jmp isr_common

# Double fault (#8) -- like #PF/#GP the CPU pushes a real error code (always 0
# for #DF), so this stub pushes only the vector. What's special about #8 isn't
# the stub (identical shape to the others) but its IDT entry: knekt.c0 sets that
# entry's IST field to 1, so the CPU switches to the dedicated IST1 stack
# (tss64's IST1 -> df_stack_top) on entry, BEFORE running any of this. That is
# the whole point -- a double fault typically means the interrupted stack is
# unusable, so a same-stack handler would just re-fault into a triple fault.
.global isr_doublefault_entry
isr_doublefault_entry:
    push 8
    jmp isr_common

# The remaining CPU exception vectors, all routed to the generic
# panic_handler (see kmain.c0's main, dispatch_set) same as #DE/#UD/#GP
# above -- one two-line stub each, cheap to add in bulk once panic_handler
# existed. Which push a dummy 0 error code vs. only the vector follows the
# same rule as every stub above: CPUs push a real error code for
# #10/#11/#12/#17, nothing for the rest.
.global isr_debug_entry
isr_debug_entry: # #1, no error code
    push 0
    push 1
    jmp isr_common

.global isr_nmi_entry
isr_nmi_entry: # #2, no error code
    push 0
    push 2
    jmp isr_common

.global isr_breakpoint_entry
isr_breakpoint_entry: # #3, no error code
    push 0
    push 3
    jmp isr_common

.global isr_overflow_entry
isr_overflow_entry: # #4, no error code
    push 0
    push 4
    jmp isr_common

.global isr_boundrange_entry
isr_boundrange_entry: # #5, no error code
    push 0
    push 5
    jmp isr_common

.global isr_devnotavail_entry
isr_devnotavail_entry: # #7, no error code
    push 0
    push 7
    jmp isr_common

.global isr_invalidtss_entry
isr_invalidtss_entry: # #10, has a real error code
    push 10
    jmp isr_common

.global isr_segnotpresent_entry
isr_segnotpresent_entry: # #11, has a real error code
    push 11
    jmp isr_common

.global isr_stackfault_entry
isr_stackfault_entry: # #12, has a real error code
    push 12
    jmp isr_common

.global isr_fpuerror_entry
isr_fpuerror_entry: # #16, no error code
    push 0
    push 16
    jmp isr_common

.global isr_alignment_entry
isr_alignment_entry: # #17, has a real error code (always 0)
    push 17
    jmp isr_common

.global isr_machinecheck_entry
isr_machinecheck_entry: # #18, no error code
    push 0
    push 18
    jmp isr_common

.global isr_simdfp_entry
isr_simdfp_entry: # #19, no error code
    push 0
    push 19
    jmp isr_common

# Same-privilege-level interrupt handling throughout (everything runs in
# ring 0; there's no ring 3 yet), so the CPU pushes a 3-qword frame (RIP,
# CS, RFLAGS) -- no RSP/SS push, no stack switch -- and no error code
# (only pushed for certain exceptions, never for external hardware IRQs
# like these).
#
# Interrupts are asynchronous -- unlike an ordinary call, we can't assume
# only caller-saved registers matter, since the interrupted code might
# have been relying on ANY register's value, including the normally
# callee-saved ones. All 15 general-purpose registers (everything but
# rsp, which the CPU/iretq already manage via the frame) are saved and
# restored around the call into int_dispatch(vector), a c0 function that
# looks up and calls the real handler.
#
# Stack alignment: at kernel entry stack_top was aligned to 16 bytes
# (`.balign 16` below), and kmain.c0's main() never touches rsp after
# that (it just busy-loops) -- so RSP at interrupt time is exactly
# stack_top, still 16-aligned. The CPU's 3-qword push (24 bytes) plus the
# per-vector stub's 2-qword push (16 bytes: vector + padding) plus this
# stub's 15-register push (120 bytes) = 160 bytes, a multiple of 16, so
# RSP is correctly 16-aligned right before `call int_dispatch`, satisfying
# the SysV ABI's "16-aligned at the point of CALL" requirement. (The
# padding qword only exists to keep this a multiple of 16 -- without it,
# the vector-number push alone would leave it 8 bytes short.) This is a
# known simplification, not a general solution: it holds because nothing
# currently running before interrupts are enabled ever leaves RSP
# misaligned, not because this stub defensively re-aligns it. Revisit
# (e.g. a dedicated interrupt stack via the IST mechanism, or defensive
# `and rsp, -16`) if that stops being true.
isr_common:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    # A real x86-64 fact this ISR relies on rather than fights: in 64-bit
    # long mode the CPU pushes ALL FIVE qwords (SS/RSP/RFLAGS/CS/RIP, 40
    # bytes) on interrupt entry UNCONDITIONALLY, even with no privilege
    # change -- unlike legacy 32-bit protected mode, which only pushed
    # SS:ESP on a ring change. And `iretq` symmetrically pops those same 5
    # qwords on the way out. So the RSP and SS the interrupted task needs
    # restored are ALREADY on the stack, at the exact right place, with the
    # exact right values -- the CPU put them there.
    #
    # After the 15 register pushes above, rsp = orig_rsp - 176, and the
    # frame reads, relative to rsp: regs @0-112, vector @120, errcode @128,
    # RIP @136, CS @144, RFLAGS @152, RSP @160, SS @168 -- identical in
    # shape AND offsets to what sched_craft_stack (chrone.c0) builds for a
    # freshly-launched task, so isr_epilogue's single pop-then-iretq path
    # serves a real resume and a first launch alike. NOTHING else is needed
    # here: no reserve, no shift, no synthesized RSP/SS.
    #
    # Why this block is this simple, not ~50 lines of sub/shift/synthesize:
    # an earlier version wrongly believed the CPU pushed only 3 qwords on
    # entry (the 32-bit mental model) while iretq popped 5, and tried to
    # manufacture the "missing" RSP/SS itself -- first by writing them
    # above orig_rsp (which clobbered the task's own stack), then by
    # reserving 16 bytes via `sub rsp,16` plus a 20-qword shift and
    # computing RSP as `rsp + 176`. But post-shift rsp was orig_rsp - 192,
    # so rsp + 176 = orig_rsp - 16: each resume landed the task 16 bytes
    # low, and since the next cycle reconstructed from that already-low
    # rsp, the error COMPOUNDED 16 bytes per interrupt -- a slow downward
    # stack drift that eventually walked rsp off the task's page and froze
    # the kernel. Deleting the whole apparatus (the CPU already does the
    # work correctly) is the fix.

    # The vector number sits just above the 15 saved registers (120 bytes),
    # with the error code slot just above that (128) -- see the per-vector
    # stubs. For hardware IRQs the stub pushed a dummy 0 there; for CPU
    # exceptions like #PF the CPU pushed a real error code and the stub only
    # pushed the vector, so the slot holds the real code. Either way the
    # layout (and the `add rsp, 16` cleanup below) is identical. CR2 holds
    # the faulting linear address, meaningful only for #PF -- read here and
    # handed to every handler; the ones that don't need it ignore it.
    mov rdi, [rsp + 120]   # vector
    mov rsi, [rsp + 128]   # error code (real for #PF, dummy 0 for IRQs)
    mov rdx, cr2           # faulting address (CR2)
    mov rcx, [rsp + 136]   # faulting RIP (from CPU-pushed frame)
    call int_dispatch

    # Preemptive switch check. The timer handler
    # (int_dispatch -> timer_tick -> sched_tick, vector 32 only) may have
    # requested a switch by leaving 1 in SCHED_SWITCH_PENDING (1048720/
    # 0x100090); if so, SCHED_SAVE_SLOT_ADDR (1048704/0x100080) holds the
    # address of the outgoing task's saved-rsp slot and SCHED_NEXT_RSP
    # (1048712/0x100088) holds the incoming task's saved rsp. Swapping rsp
    # HERE -- between this stub's own register push above and the pop below
    # -- means the pop+iretq sequence below resumes whichever task is now
    # current: this exact 176-byte frame (15 registers + vector/errcode +
    # RIP/CS/RFLAGS/RSP/SS) is both what gets saved for the outgoing task and what
    # was already saved (or, for a task's first run, crafted by
    # sched_craft_stack) for the incoming one. This is the real difference
    # from the old cooperative context_switch it replaces: that one swapped
    # 6 callee-saved registers at an ordinary call boundary; this swaps the
    # FULL interrupt frame, because the switch happens inside an interrupt
    # handler where any register -- not just callee-saved ones -- may be
    # live in the preempted task.
    mov rax, [0x100090]
    cmp rax, 0
    je .Lno_switch
    mov qword ptr [0x100090], 0
    mov rax, [0x100080]
    mov [rax], rsp
    mov rsp, [0x100088]
.Lno_switch:

# isr_common's epilogue, given its own label so sched_launch (below) can
# jump straight into it -- see sched_launch's comment for why that's exactly
# the point.
isr_epilogue:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    add rsp, 16 # discard the vector number + its alignment padding
    iretq

# Launches the very first preemptive task: called once (indirectly, from
# kmain.c0's sched_start via the SCHED_LAUNCH_ADDR hand-off) with rdi = that
# task's crafted initial rsp (see sched_craft_stack). Just loads rsp and
# falls into isr_common's own epilogue -- from the CPU's point of view this
# is indistinguishable from "resuming from a preemption," which is exactly
# the point: sched_craft_stack builds a stack that LOOKS like a preempted
# task's saved frame, RFLAGS included, so this one epilogue path serves both
# the first launch and every later resume. RFLAGS' IF bit, set in that
# crafted frame, is what actually enables interrupts here -- there's no
# explicit `sti` anywhere in this scheduler; interrupts turn on at the exact
# instant iretq restores it.
.global sched_launch
sched_launch:
    mov rsp, rdi
    jmp isr_epilogue

# Callable from c0 (indirectly, via .haltinfo -- see kmain.c0's halt()),
# same "c0 can't call an externally-defined asm symbol by name" wall as
# sched_launch/context_switch above, solved the same way. Just `hlt`+`ret`
# -- panic_handler loops calling this repeatedly rather than trusting a
# single `hlt` to never wake, since `hlt` only blocks until the NEXT
# interrupt of ANY kind, and a non-maskable interrupt (NMI, vector 2) can
# still fire even with IF cleared by the interrupt gate that got us into
# panic_handler in the first place. Looping ensures panic_handler's "never
# returns" contract holds even if that happens, rather than accidentally
# falling back into isr_common's epilogue and resuming the faulted task.
.global halt_cpu
halt_cpu:
    hlt
    ret

# Test-only: deliberately provoke a #8 double fault, to prove the IST stack
# actually works (a #DF handler that runs and panics, vs. a silent triple-fault
# reboot). Reachable only when test_doublefault.sh temporarily injects a
# `call trigger_doublefault` into the boot path -- nothing calls it in a normal
# boot, exactly like the divide-by-zero test_panic.sh injects is absent from
# normal c0. Mechanism: point rsp at a non-canonical address, then push. The
# push faults (#SS/#GP); delivering THAT fault also has to push onto the same
# bad rsp, which faults again -- the CPU escalates the fault-during-fault to
# #8. Because #8's IDT entry selects IST1, the CPU switches to df_stack_top and
# the handler runs normally. Without the IST it would push onto the bad rsp a
# third time -> triple fault -> CPU reset.
.global trigger_doublefault
trigger_doublefault:
    movabs rsp, 0x8000000000000000
    push rax
    ret

# 64-bit GDT, 7 entries.
.section .data
.balign 16
gdt64:
    .quad 0
    .quad 0x00209A0000000000
    .quad 0x0000920000000000
gdt64_tss:
    .quad 0
    .quad 0
    .quad 0x0000F20000000000
    .quad 0x0020FA0000000000
gdt64_end:
gdt64_pointer:
    .word gdt64_end - gdt64 - 1
    .long gdt64
