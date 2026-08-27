; golden5.asm -- the data directives dw / dd / dq.
;
; These used to sit in the "recognised but ignored" table: `pp: dq msg` emitted
; NOTHING and did not advance the program counter, so the label silently
; aliased whatever came next and every address after it was wrong. Nothing
; reported an error. This test byte-compares the emitted data against GNU as,
; which is the only way that class of bug shows up.
;
; Exits 42.

section .text
global _start

_start:
    ; a pointer stored with dq, read back and used
    mov rsi, [pp]
    mov rdx, 4
    mov rax, 1
    mov rdi, 1
    syscall

    ; dq list, second element
    mov rax, [nums + 8]
    cmp rax, 7
    jne fail

    ; dd, zero-extended out of a qword slot
    mov rax, [dwords]
    shl rax, 32                 ; mask to 32 bits without a big immediate,
    shr rax, 32                 ; which GNU as will not take on a 64-bit op
    cmp rax, 66051              ; 0x00010203
    jne fail

    ; dw, masked to 16 bits
    mov rax, [words]
    shl rax, 48
    shr rax, 48
    cmp rax, 258                ; 0x0102
    jne fail

    ; forward reference resolved in pass 2
    mov rax, [fwd]
    mov rcx, later
    cmp rax, rcx
    jne fail

    mov rax, [nums]
    mov rdi, rax                ; 42
    mov rax, 60
    syscall

fail:
    mov rdi, 1
    mov rax, 60
    syscall

; Data at the end of .text: one flat segment, so anything before the last
; instruction would be executed rather than read.
pp      dq msg
nums    dq 42, 7
dwords  dd 66051, 1
words   dw 258, 65535
fwd     dq later
msg     db "abc", 10
later   db 0
