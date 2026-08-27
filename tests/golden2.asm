; Golden test 2 - backward jumps, every conditional, all eight registers,
; nested calls, mixed db. Sums 1..10 and exits with 55.
;
; Note: mini-asm labels are global. NASM's ".local" scoping is not implemented,
; so every label here has a unique name.
_start:
    call setup
    call sum_loop
    mov rdi, rax
    mov rax, 60
    syscall

setup:
    mov rax, 0
    mov rcx, 1
    ret

; is_register used to resolve every name to the same index, so each of the
; eight encodable registers is touched at least once here.
sum_loop:
    mov rbx, rsp        ; index 4, read only
    mov rbp, 0          ; index 5
    mov rsi, 0          ; index 6
    mov rdi, 0          ; index 7
    mov rdx, 0          ; index 2
loop_top:
    add rax, rcx
    mov rbx, 1
    add rcx, rbx
    mov rbx, 11
    cmp rcx, rbx
    jl loop_top

    mov rbx, 55
    cmp rax, rbx
    je check_ne
    mov rax, 1
    ret
check_ne:
    cmp rax, rbx
    jne bad
    cmp rbx, rax
    jg bad
    ret
bad:
    mov rax, 2
    ret

pad db 0, 1, "two", 3, "four", 255, 10
