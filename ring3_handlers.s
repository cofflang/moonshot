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
    sysretq

# enter_ring3(entry_rip, user_rsp, kernel_rsp) — enter ring 3 for the
# first time. Called from c0 (indirectly via RING3INFO_ADDR).
#
# rdi = entry point (user RIP)
# rsi = user stack top (user RSP)
# rdx = kernel stack top (will be set as TSS RSP0 so future ring0→ring3
#      transitions via iretq have a known-good ring-0 stack)
.global enter_ring3
enter_ring3:
    # Set TSS RSP0 to the kernel stack top. When the CPU transitions
    # from ring 3 → ring 0 (interrupt, exception, or SYSRET's reverse),
    # it loads RSP from this field, giving the handler a known-good stack.
    lea rax, [tss64]
    mov [rax + 4], rdx

    # Flush TLB via CR3 reload. This ensures any stale user-page
    # mappings are cleared before entering ring 3.
    mov rax, cr3
    mov cr3, rax

    # Build the iretq frame on the kernel stack.
    # iretq pops: RIP, CS, RFLAGS, RSP, SS (in that order, last pushed first).
    push 0x2B          # SS = user data selector (GDT index 5, RPL 3)
    push rsi            # RSP = user stack top
    push 0x202          # RFLAGS (IF=1, reserved bit 1 always set)
    push 0x33           # CS = user code selector (GDT index 6, RPL 3)
    push rdi            # RIP = entry point
    iretq
