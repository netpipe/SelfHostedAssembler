; Golden test 3 - A2: memory operands, r8-r15, ALU immediates, shifts.
; Exits with 42.
_start:
    mov rbp, rsp
    sub rsp, 256

    ; locals through [rbp - N]  (disp8, and rbp cannot use the mod=00 form)
    mov rax, 7
    mov [rbp - 8], rax
    mov rcx, 3
    mov [rbp - 16], rcx
    mov rax, [rbp - 8]
    add rax, [rbp - 16]         ; reg <- mem, opcode+2 direction   = 10
    mov [rbp - 24], rax

    ; plain [reg]
    mov rbx, rbp
    sub rbx, 8
    mov rdx, [rbx]              ; = 7
    add rax, rdx                ; = 17

    ; [rsp] needs a SIB byte
    sub rsp, 8
    mov [rsp], rax
    mov r8, [rsp]               ; = 17
    add rsp, 8

    ; extended registers: REX.R and REX.B
    mov r9, 5
    add r8, r9                  ; = 22
    mov r10, r8
    sub r10, 2                  ; = 20

    ; shifts: by one (short form), by immediate, and by cl
    mov rax, r10
    shl rax, 1                  ; = 40
    mov rcx, 2
    shr rax, cl                 ; = 10
    sar rax, 1                  ; = 5

    ; RIP-relative load of a global
    mov rbx, [rip + gval]       ; = 37
    add rax, rbx                ; = 42

    ; ALU immediates: imm8 and imm32 forms
    add rax, 100                ; = 142
    sub rax, 100                ; = 42
    and rax, 255
    or rax, 0
    cmp rax, 42
    jne bad

    ; mem <- reg then reg <- mem, one more time, with a 32-bit displacement
    mov [rbp - 200], rax
    mov rdi, [rbp - 200]
    mov rax, 60
    syscall

bad:
    mov rdi, 1
    mov rax, 60
    syscall

; 37 as a little-endian 64-bit value
gval db 37, 0, 0, 0, 0, 0, 0, 0
