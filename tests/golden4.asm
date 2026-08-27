; Golden test 4 - encoding coverage. Exits 0 immediately; everything after that
; is never executed, it exists only to be byte-compared against binutils.
_start:
    mov rdi, 0
    mov rax, 60
    syscall

coverage:
    mov rax, rax
    mov rax, rax
    mov rcx, rax
    mov rax, rcx
    mov rdx, rax
    mov rax, rdx
    mov rbx, rax
    mov rax, rbx
    mov rsp, rax
    mov rax, rsp
    mov rbp, rax
    mov rax, rbp
    mov rsi, rax
    mov rax, rsi
    mov rdi, rax
    mov rax, rdi
    mov r8, rax
    mov rax, r8
    mov r9, rax
    mov rax, r9
    mov r10, rax
    mov rax, r10
    mov r11, rax
    mov rax, r11
    mov r12, rax
    mov rax, r12
    mov r13, rax
    mov rax, r13
    mov r14, rax
    mov rax, r14
    mov r15, rax
    mov rax, r15
    mov rcx, [rax]
    mov [rax], rcx
    mov rcx, [rcx]
    mov [rcx], rcx
    mov rcx, [rdx]
    mov [rdx], rcx
    mov rcx, [rbx]
    mov [rbx], rcx
    mov rcx, [rsp]
    mov [rsp], rcx
    mov rcx, [rbp]
    mov [rbp], rcx
    mov rcx, [rsi]
    mov [rsi], rcx
    mov rcx, [rdi]
    mov [rdi], rcx
    mov rcx, [r8]
    mov [r8], rcx
    mov rcx, [r9]
    mov [r9], rcx
    mov rcx, [r10]
    mov [r10], rcx
    mov rcx, [r11]
    mov [r11], rcx
    mov rcx, [r12]
    mov [r12], rcx
    mov rcx, [r13]
    mov [r13], rcx
    mov rcx, [r14]
    mov [r14], rcx
    mov rcx, [r15]
    mov [r15], rcx
    mov rax, [rbp + 8]
    mov [rsp + 8], rax
    mov r9, [r12 + 8]
    mov [r13 + 8], r10
    mov rax, [rbp - 8]
    mov [rsp - 8], rax
    mov r9, [r12 - 8]
    mov [r13 - 8], r10
    mov rax, [rbp + 127]
    mov [rsp + 127], rax
    mov r9, [r12 + 127]
    mov [r13 + 127], r10
    mov rax, [rbp - 128]
    mov [rsp - 128], rax
    mov r9, [r12 - 128]
    mov [r13 - 128], r10
    mov rax, [rbp + 128]
    mov [rsp + 128], rax
    mov r9, [r12 + 128]
    mov [r13 + 128], r10
    mov rax, [rbp - 129]
    mov [rsp - 129], rax
    mov r9, [r12 - 129]
    mov [r13 - 129], r10
    mov rax, [rbp + 100000]
    mov [rsp + 100000], rax
    mov r9, [r12 + 100000]
    mov [r13 + 100000], r10
    mov rax, [rbp - 100000]
    mov [rsp - 100000], rax
    mov r9, [r12 - 100000]
    mov [r13 - 100000], r10
    add rax, rcx
    add r8, r15
    add rax, [rbp - 16]
    add [rbp - 16], rax
    add r9, [r12 + 32]
    add [r13 - 32], r10
    add rax, 5
    add rax, 100000
    add rcx, 5
    add rcx, 100000
    add r11, 7
    or rax, rcx
    or r8, r15
    or rax, [rbp - 16]
    or [rbp - 16], rax
    or r9, [r12 + 32]
    or [r13 - 32], r10
    or rax, 5
    or rax, 100000
    or rcx, 5
    or rcx, 100000
    or r11, 7
    and rax, rcx
    and r8, r15
    and rax, [rbp - 16]
    and [rbp - 16], rax
    and r9, [r12 + 32]
    and [r13 - 32], r10
    and rax, 5
    and rax, 100000
    and rcx, 5
    and rcx, 100000
    and r11, 7
    sub rax, rcx
    sub r8, r15
    sub rax, [rbp - 16]
    sub [rbp - 16], rax
    sub r9, [r12 + 32]
    sub [r13 - 32], r10
    sub rax, 5
    sub rax, 100000
    sub rcx, 5
    sub rcx, 100000
    sub r11, 7
    xor rax, rcx
    xor r8, r15
    xor rax, [rbp - 16]
    xor [rbp - 16], rax
    xor r9, [r12 + 32]
    xor [r13 - 32], r10
    xor rax, 5
    xor rax, 100000
    xor rcx, 5
    xor rcx, 100000
    xor r11, 7
    cmp rax, rcx
    cmp r8, r15
    cmp rax, [rbp - 16]
    cmp [rbp - 16], rax
    cmp r9, [r12 + 32]
    cmp [r13 - 32], r10
    cmp rax, 5
    cmp rax, 100000
    cmp rcx, 5
    cmp rcx, 100000
    cmp r11, 7
    shl rax, 1
    shl rax, 5
    shl rax, cl
    shl rcx, 1
    shl rcx, 5
    shl rcx, cl
    shl r9, 1
    shl r9, 5
    shl r9, cl
    shl r13, 1
    shl r13, 5
    shl r13, cl
    shr rax, 1
    shr rax, 5
    shr rax, cl
    shr rcx, 1
    shr rcx, 5
    shr rcx, cl
    shr r9, 1
    shr r9, 5
    shr r9, cl
    shr r13, 1
    shr r13, 5
    shr r13, cl
    sar rax, 1
    sar rax, 5
    sar rax, cl
    sar rcx, 1
    sar rcx, 5
    sar rcx, cl
    sar r9, 1
    sar r9, 5
    sar r9, cl
    sar r13, 1
    sar r13, 5
    sar r13, cl
    jmp coverage
    je coverage
    jne coverage
    jl coverage
    jg coverage
    jz coverage
    jnz coverage
    jle coverage
    jge coverage
    jb coverage
    jae coverage
    jbe coverage
    ja coverage
    js coverage
    jns coverage
    mov al, [rax]
    mov cl, [rbp - 8]
    mov dl, [rsp]
    mov bl, [rcx + 100000]
    mov [rcx], al
    mov [rbp - 8], cl
    mov [rsp], dl
    mov [rdx + 16], bl
    mov al, [r12]
    mov [r13 - 8], cl
    mov al, [rip + gdata]
    mov [rip + gdata], al
    mov rax, -1
    xor rax, -1
    add rax, -5
    sub rcx, -100000
    cmp r9, -1
    mov r11, -2147483648
    mov rax, [rip + gdata]
    mov [rip + gdata], rax
    add rax, [rip + gdata]
    ret

gdata db 1, 2, 3, 4, 5, 6, 7, 8
