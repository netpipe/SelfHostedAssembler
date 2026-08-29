; ==== TARGET BEGIN ====
; ==============================================================================
; TARGET: NANO-OS
; ==============================================================================
; The same assembler, talking to nano-os instead of Linux. `tools/retarget.py`
; substitutes this block for the one between the TARGET markers in
; fixed/selfContained.asm; everything below those markers is shared, unchanged,
; and is the reason this is a target block rather than a second assembler.
;
; What differs from the Linux block, and nothing else does:
;
;   * the trap. `int 0x80` rather than `syscall`, and nano-os's own numbers
;     (kernel/nano-proc.h): exit 0, write 1, read 2, open 3, close 4.
;   * argc and argv. Linux puts them on the stack at _start; nano-os builds an
;     interrupt frame with argc in rdi and argv in rsi and drops into _start
;     with `iretq`, so they are already in registers.
;   * read() loops. The RAM disk answers a read from one inode at a time and
;     may hand back less than was asked for; taking the first return as the
;     whole file would silently assemble a prefix of it.
;   * def_base. A binary assembled ON nano-os is presumably FOR nano-os, and
;     user memory there starts at 512 GiB. Assembling for Linux from here is
;     still possible -- pass -b 0x400000.
;
; The open() flags are the same numbers on both, because nano-os deliberately
; adopted Linux's values rather than inventing its own.
;
; The four routines and their contracts, identical to the Linux block's:
;   os_read_input   rdi = path                  -> rax = bytes read into in_buf,
;                                                  or negative if unreadable
;   os_write_output rdi = path, rsi = buf,
;                   rdx = length                -> rax = 0, or negative
;   os_err          rsi = buf, rdx = length     -> writes to the console
;   os_exit         rdi = status                -> does not return
; ==============================================================================

def_base equ 0x8000000000       ; nano-os user space: PML4 entry 1, 512 GiB

_start:
    ; No stack walk here: nano-os put argc and argv in registers before the
    ; iretq that landed on this instruction.
    mov [g_argc], rdi
    mov [g_argv], rsi
    jmp main_flow

os_read_input:
    mov [t_path], rdi
    mov rax, 3                  ; SYS_OPEN
    mov rdi, [t_path]
    xor rsi, rsi                ; O_RDONLY
    xor rdx, rdx
    int 0x80
    cmp rax, 0
    jl .fail
    mov [t_fd], rax
    mov qword [t_n], 0
.loop:
    ; Keep reading until the file stops giving. A single read that returns
    ; less than the whole file is normal here, and treating the first answer
    ; as the last one would assemble a prefix and report success.
    mov rdx, buf_size
    sub rdx, [t_n]
    cmp rdx, 0
    jle .close
    mov rax, 2                  ; SYS_READ
    mov rdi, [t_fd]
    lea rsi, [rip + in_buf]
    add rsi, [t_n]
    int 0x80
    cmp rax, 0
    jle .close
    add [t_n], rax
    jmp .loop
.close:
    mov rax, 4                  ; SYS_CLOSE
    mov rdi, [t_fd]
    int 0x80
    mov rax, [t_n]
    ret
.fail:
    mov rax, -1
    ret

os_write_output:
    mov [t_path], rdi
    mov [t_buf], rsi
    mov [t_n], rdx
    mov rax, 3                  ; SYS_OPEN
    mov rdi, [t_path]
    mov rsi, 577                ; O_WRONLY | O_CREAT | O_TRUNC
    xor rdx, rdx
    int 0x80
    cmp rax, 0
    jl .fail
    mov [t_fd], rax
    mov rax, 1                  ; SYS_WRITE
    mov rdi, [t_fd]
    mov rsi, [t_buf]
    mov rdx, [t_n]
    int 0x80
    mov [t_res], rax
    mov rax, 4                  ; SYS_CLOSE
    mov rdi, [t_fd]
    int 0x80
    ; A short write is a failure. The file system has a maximum file size and
    ; a finite disk, and both of those show up here as "wrote fewer bytes than
    ; asked" -- which, reported as success, is a truncated binary that looks
    ; like a good one.
    mov rax, [t_res]
    cmp rax, [t_n]
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, -1
    ret

os_err:
    mov rax, 1                  ; SYS_WRITE
    mov rdi, 2                  ; the console
    int 0x80
    ret

os_exit:
    mov rax, 0                  ; SYS_EXIT
    int 0x80
; ==== TARGET END ====
