; subset.asm -- every rewrite proposed in README section 9, exercised for real.
;
; This program is written WITHOUT inc, dec, test, lea, push, pop, movzx, imul,
; mul or rep -- i.e. entirely inside the subset the assembler accepts today.
; If it assembles and exits 42, the rewrite column of the section 9 table is
; sound and self-hosting is a source-rewriting job, not an encoder job.

section .text
global _start

_start:
    ; --- `lea rsi, [msg]` -> a bare symbol assembles as its own address -------
    mov rsi, msg
    mov rdx, 6
    mov rax, 1
    mov rdi, 1
    syscall

    ; --- `inc rbx` -> `add rbx, 1` -------------------------------------------
    mov rbx, 0
    add rbx, 1
    add rbx, 1                  ; rbx = 2

    ; --- `dec rbx` -> `sub rbx, 1` -------------------------------------------
    sub rbx, 1                  ; rbx = 1

    ; --- `test rbx, rbx` -> `cmp rbx, 0` -------------------------------------
    cmp rbx, 0
    je fail                     ; must not take: rbx is 1

    ; --- `push rbx` / `pop rcx` -> explicit rsp arithmetic --------------------
    sub rsp, 8
    mov [rsp], rbx
    mov rcx, 0
    mov rcx, [rsp]
    add rsp, 8
    cmp rcx, 1
    jne fail

    ; --- `movzx rax, byte [chr]` -> byte load + mask -------------------------
    mov al, [chr]
    and rax, 255
    cmp rax, 7
    jne fail

    ; --- `[rdi + rcx]` (SIB) -> fold the index into the base ------------------
    mov rdi, tbl
    mov rcx, 2
    add rdi, rcx
    mov al, [rdi]
    and rax, 255
    cmp rax, 30                 ; tbl[2]
    jne fail

    ; --- `imul rax, 10` -> shift-add: x*10 == (x<<3) + (x<<1) -----------------
    mov rax, 4
    mov rbx, rax
    shl rax, 3                  ; 32
    shl rbx, 1                  ; 8
    add rax, rbx                ; 40
    cmp rax, 40
    jne fail

    ; --- `rep movsb` -> an explicit byte loop ---------------------------------
    mov rsi, tbl
    mov rdi, dst
    mov rcx, 0
copy_loop:
    cmp rcx, 3
    jge copy_done
    mov al, [rsi]
    mov [rdi], al
    add rsi, 1
    add rdi, 1
    add rcx, 1
    jmp copy_loop
copy_done:
    mov al, [dst]
    and rax, 255
    cmp rax, 10
    jne fail

    ; 40 + tbl[0](10) - 8 = 42
    mov rax, 40
    add rax, 10
    sub rax, 8

    mov rdi, rax
    mov rax, 60
    syscall

fail:
    mov rdi, 1
    mov rax, 60
    syscall

; Data lives at the end of .text: there is one flat segment, so anything
; placed before the last instruction would be executed rather than read.
msg db "subset", 10
chr db 7
tbl db 10, 20, 30
dst db 0, 0, 0, 0
