# ring3_handlers.s — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
# ring3_handlers.s — ring-3 entry/exit trampolines.
# Placed in .ring3_text section.

.intel_syntax noprefix

.section .ring3_text, "ax"

# syscall_entry — the kernel-side target of SYSCALL (LSTAR MSR).
# The CPU has already switched to ring 0 and loaded CS/SS from STAR,
# pushed RIP→RCX and RFLAGS→R11, and masked RFLAGS per SFMASK.
# We save registers, marshal arguments into the SysV calling convention,
# call sys_dispatch (c0), restore, and SYSRET back to ring 3.
.global syscall_entry
syscall_entry:
    # Switch to this task's own kernel stack (TSS.RSP0 -- the same field
    # enter_ring3 sets, and isr_common's scheduler-switch path now keeps
    # correct for whichever task is current, see boot.s/chrone.c0) BEFORE
    # touching anything else. SYSCALL, unlike an interrupt gate, does NOT
    # switch stacks automatically -- this handler used to run entirely on
    # the calling process's own user stack (a single 4096-byte page). That
    # was never actually exercised end-to-end until a real interrupt could
    # land mid-handler (see enable_interrupts/syscall.c0's SYS_EXIT fix,
    # which fixed a DIFFERENT bug that had been masking this one): the
    # first timer interrupt to land while still on that tiny user stack
    # produced a #GP on its own IRETQ, from a corrupted interrupt frame.
    #
    # No register is free to hold the old (user) rsp across this switch --
    # every GPR either carries live SYSCALL-ABI data (rax/rdi/rsi/rdx/r10/
    # r8/r9/rcx/r11) or is one of the callee-saved registers this trampoline
    # already promises to preserve for the user program (rbx/rbp/r12-r15) --
    # so the swap goes through a scratch memory slot instead of a register.
    # Safe as a single shared slot even with multiple ring-3 processes:
    # the value is copied onto the NEW (per-task, exclusively-owned) kernel
    # stack in the very next instruction, before interrupts are re-enabled
    # or anything else could possibly run on this single core.
    mov [syscall_saved_user_rsp], rsp
    mov rsp, [tss64 + 4]
    push qword ptr [syscall_saved_user_rsp]

    # Save the user's RCX (old RIP) and R11 (old RFLAGS) — these will
    # be clobbered by SYSRET, so we must preserve them across the handler.
    push r11
    push rcx
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15

    # Marshal: user args arrived in rdi,rsi,rdx,r10,r8,r9 per the SYSCALL
    # ABI. We need them in rdi,rsi,rdx,rcx,r8,r9 for the SysV calling
    # convention. The syscall number is in rax.
    mov r15, r9
    mov r14, r8
    mov r13, r10
    mov r12, rdx
    mov r11, rsi
    mov r10, rdi

    # sys_dispatch(num, a1, a2, a3, a4, a5, a6)
    mov rdi, rax       # arg1: syscall number
    mov rsi, r10       # arg2: user rdi
    mov rdx, r11       # arg3: user rsi
    mov rcx, r12       # arg4: user rdx
    mov r8,  r13       # arg5: user r10
    mov r9,  r14       # arg6: user r8
    push r15           # arg7: user r9 (on stack per SysV ABI)

    call sys_dispatch

    add rsp, 8         # pop arg7

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    pop rcx
    pop r11
    pop rsp            # restore the user's own rsp before returning to it
    sysretq

# enter_ring3(entry_rip, user_rsp, kernel_rsp, cr3) — enter ring 3 for the
# first time. Called from c0 (indirectly via RING3INFO_ADDR).
#
# rdi = entry point (user RIP)
# rsi = user stack top (user RSP)
# rdx = kernel stack top (will be set as TSS RSP0 so future ring0→ring3
#      transitions via iretq have a known-good ring-0 stack)
# rcx = the process's page-table root (physical PML4 address, from
#      pt_create() -- see jenna.c0/syscall.c0's run_ring3_binary). Loading
#      it here is what makes entry_rip/user_rsp resolve against THIS
#      process's private address space (USER_VIRT_BASE and up) rather than
#      whichever tables happened to be live in the calling kernel context.
.global enter_ring3
enter_ring3:
    # Set TSS RSP0 to the kernel stack top. When the CPU transitions
    # from ring 3 → ring 0 (interrupt, exception, or SYSRET's reverse),
    # it loads RSP from this field, giving the handler a known-good stack.
    lea rax, [tss64]
    mov [rax + 4], rdx

    # Switch to the process's own page tables. This both installs the
    # private USER_VIRT_BASE mappings entry_rip/user_rsp depend on AND
    # flushes the TLB of any stale mappings from whatever ran before.
    mov cr3, rcx

    # Build the iretq frame on the kernel stack.
    # iretq pops: RIP, CS, RFLAGS, RSP, SS (in that order, last pushed first).
    push 0x2B          # SS = user data selector (GDT index 5, RPL 3)
    push rsi            # RSP = user stack top
    push 0x202          # RFLAGS (IF=1, reserved bit 1 always set)
    push 0x33           # CS = user code selector (GDT index 6, RPL 3)
    push rdi            # RIP = entry point
    iretq

# Purely internal scratch for syscall_entry's stack-switch above -- never
# touched by c0, so an ordinary local .bss symbol (not one of linker.ld's
# fixed hand-off slots) is enough.
.section .bss
.balign 8
syscall_saved_user_rsp:
    .skip 8
