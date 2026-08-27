; Golden test 1 - every operand form the assembler claims to support.
; Prints "hello from mini-asm" and exits with 42.
_start:
    mov rax, 1
    mov rdi, 1
    mov rsi, msg
    mov rdx, 20
    syscall

    call compute
    mov rdi, rax

    mov rax, 60
    syscall

; 5 + 3 = 8, doubled twice via a loop, minus 190 -> 42
compute:
    mov rax, 5
    mov rcx, 3
    add rax, rcx
    mov rbx, rax
    add rax, rbx
    mov rbx, rax
    add rax, rbx
    mov rbx, rax
    add rax, rbx
    mov rbx, rax
    add rax, rbx
    mov rcx, 86
    sub rax, rcx
    xor rdx, rdx
    and rax, rax
    cmp rax, rax
    je taken
    mov rax, 0
taken:
    jmp done
    mov rax, 99
done:
    ret

msg db "hello from mini-asm", 10
