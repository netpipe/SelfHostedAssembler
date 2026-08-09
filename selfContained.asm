; ==============================================================================
; MINI-ASM: A Self-Hosting x86-64 Assembler
; ==============================================================================
; Dialect: Strict subset of NASM/FASM.
; Supports: mov, add, sub, cmp, xor, and, jmp, je, jne, jl, jg, call, ret, syscall, db
; Registers: rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi
; ==============================================================================
global _start

section .data
in_path db "selfHosted.asm", 0
out_path db "a.out", 0
err_msg db "Error: ", 10
err_len equ 8

section .bss
in_buf resb 65536 ; 64KB input buffer
out_buf resb 65536 ; 64KB output buffer
sym_tbl resb 4096 ; Symbol table (max 256 labels)
in_fd resq 1
out_fd resq 1
in_size resq 1
out_ptr resq 1
pc_vaddr resq 1 ; Virtual Program Counter
sym_cnt resq 1 ; Number of symbols
mnemonic_buf resb 8 ; Buffer for safe mnemonic parsing

section .text

; --- CONSTANTS ---
base_vaddr equ 0x400000
hdr_size equ 120
code_vaddr equ base_vaddr + hdr_size

; --- ELF64 HEADER (120 Bytes) ---
elf_hdr:
db 0x7f, "ELF", 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
dw 2 ; e_type = ET_EXEC
dw 0x3e ; e_machine = EM_X86_64
dd 1 ; e_version
dq code_vaddr ; e_entry
dq 64 ; e_phoff
dq 0 ; e_shoff
dd 0 ; e_flags
dw 64 ; e_ehsize
dw 56 ; e_phentsize
dw 1 ; e_phnum
dw 0 ; e_shentsize
dw 0 ; e_shnum
dw 0 ; e_shstrndx
phdr:
dd 1 ; p_type = PT_LOAD
dd 5 ; p_flags = PF_R | PF_X
dq 0 ; p_offset
dq base_vaddr ; p_vaddr
dq base_vaddr ; p_paddr
dq 0 ; p_filesz (PATCHED LATER)
dq 0 ; p_memsz (PATCHED LATER)
dq 0x1000 ; p_align

_start:
    ; 1. Open Input File
    mov rax, 2 ; sys_open
    mov rdi, in_path
    xor rsi, rsi ; O_RDONLY
    syscall
    test rax, rax
    js error_exit
    mov [in_fd], rax

    ; 2. Read Input File
    mov rax, 0 ; sys_read
    mov rdi, [in_fd]
    mov rsi, in_buf
    mov rdx, 65536
    syscall
    mov [in_size], rax
    mov rax, 3 ; sys_close
    mov rdi, [in_fd]
    syscall

    ; 3. Initialize Output Buffer with ELF Header
    lea rsi, [elf_hdr]
    lea rdi, [out_buf]
    mov rcx, hdr_size
    rep movsb

    ; 4. Pass 1: Scan Labels & Calculate Sizes
    mov qword [sym_cnt], 0
    mov qword [pc_vaddr], code_vaddr
    mov qword [out_ptr], hdr_size
    xor r11, r11 ; r11 = 0 (Pass 1 mode)
    call process_file

    ; 5. Pass 2: Generate Machine Code
    mov qword [pc_vaddr], code_vaddr
    mov qword [out_ptr], hdr_size
    mov r11, 1 ; r11 = 1 (Pass 2 mode)
    call process_file

    ; 6. Patch ELF Header (p_filesz and p_memsz)
    mov rax, [out_ptr]
    mov rdi, out_buf
    mov [rdi+96], rax ; p_filesz offset in phdr
    mov [rdi+104], rax ; p_memsz offset in phdr

    ; 7. Write Output File
    mov rax, 2 ; sys_open
    mov rdi, out_path
    mov rsi, 577 ; O_WRONLY | O_CREAT | O_TRUNC
    mov rdx, 420 ; 0644 octal
    syscall
    test rax, rax
    js error_exit
    mov [out_fd], rax

    mov rax, 1 ; sys_write
    mov rdi, [out_fd]
    mov rsi, out_buf
    mov rdx, [out_ptr]
    syscall

    mov rax, 3 ; sys_close
    mov rdi, [out_fd]
    syscall

    ; 8. Exit
    mov rax, 60
    xor rdi, rdi
    syscall

error_exit:
    mov rax, 1
    mov rdi, 2 ; stderr
    mov rsi, err_msg
    mov rdx, err_len
    syscall
    mov rax, 60
    mov rdi, 1
    syscall

; ==============================================================================
; CORE LOGIC
; ==============================================================================
process_file:
    lea r13, [in_buf] ; Current read pointer
    mov r14, [in_size]
    add r14, r13 ; End pointer
.loop:
    cmp r13, r14
    jge .done
    call process_line
    jmp .loop
.done:
    ret

process_line:
.skip_ws:
    mov al, byte [r13]
    cmp al, 0
    je .done
    cmp al, 10
    je .next_line
    cmp al, 32
    je .inc_ptr
    cmp al, 9
    je .inc_ptr
    cmp al, ';'
    je .skip_to_nl
    cmp al, '%'
    je .skip_to_nl
    cmp al, 's' ; section
    je .skip_to_nl
    cmp al, 'g' ; global
    je .skip_to_nl
    cmp al, 'e' ; extern/equ
    je .skip_to_nl
    cmp al, 'r' ; resb/resq
    je .skip_to_nl
    ; Check for label
    mov rdi, r13
    xor rcx, rcx
.scan_label:
    mov al, byte [rdi + rcx]
    cmp al, ':'
    je .found_label
    cmp al, ' '
    je .is_instr
    cmp al, 10
    je .is_instr
    cmp al, 0
    je .is_instr
    inc rcx
    jmp .scan_label
    
.found_label:
    call process_label
    jmp .skip_past_label

.is_instr:
    call parse_instruction
    jmp .next_line

.inc_ptr:
    inc r13
    jmp .skip_ws

.skip_to_nl:
    mov al, byte [r13]
    cmp al, 10
    je .next_line
    cmp al, 0
    je .done
    inc r13
    jmp .skip_to_nl

.skip_past_label:
    mov al, byte [r13]
    cmp al, ':'
    je .skip_colon
    inc r13
    jmp .skip_past_label
.skip_colon:
    inc r13
    jmp .skip_ws

.next_line:
    inc r13
.done:
    ret

process_label:
    xor rcx, rcx
.len_loop:
    mov al, byte [r13 + rcx]
    cmp al, ':'
    je .got_len
    inc rcx
    jmp .len_loop
.got_len:
    mov rdi, r13
    call hash_str_token
    mov rbx, [sym_cnt]
    push rax
    mov rcx, 24
    mov rax, rbx
    mul rcx
    lea rdi, [sym_tbl + rax]
    pop rax
    mov [rdi], rax
    mov rax, [pc_vaddr]
    mov [rdi+16], rax
    inc qword [sym_cnt]
    ret

hash_str_token:
    mov rax, 5381
    mov r9, rcx
    xor r8, r8
.loop:
    cmp r8, r9
    jge .done
    movzx rbx, byte [rdi + r8]
    mov r10, rax
    shl rax, 5
    add rax, r10
    add rax, rbx
    inc r8
    jmp .loop
.done:
    ret

parse_instruction:
    ; Safely copy mnemonic to buffer padded with spaces to handle line endings correctly
    xor rax, rax
    mov rcx, 4
    lea rdi, [mnemonic_buf]
.copy_loop:
    mov al, byte [r13]
    cmp al, 'a'
    jb .pad_char
    cmp al, 'z'
    ja .pad_char
    mov byte [rdi], al
    inc rdi
    inc r13
    dec rcx
    jnz .copy_loop
    jmp .done_copy
.pad_char:
    mov byte [rdi], ' '
    inc rdi
    dec rcx
    jnz .pad_char
.done_copy:
    sub r13, 4 ; Restore r13 to the start of the mnemonic
    
    mov eax, [mnemonic_buf]
    lea rsi, [opcode_table]
.find_loop:
    cmp dword [rsi], eax
    je .found
    cmp dword [rsi], '    '
    je .not_found
    add rsi, 8
    jmp .find_loop
.found:
    .skip_mnem:
        mov al, byte [r13]
        cmp al, 'a'
        jb .end_mnem
        cmp al, 'z'
        ja .end_mnem
        inc r13
        jmp .skip_mnem
    .end_mnem:
        movzx r15, byte [rsi + 4]
        cmp r15, 0
        je parse_alu
        cmp r15, 1
        je parse_mov
        cmp r15, 2
        je parse_jmp
        cmp r15, 3
        je parse_jcc
        cmp r15, 4
        je parse_call
        cmp r15, 5
        je parse_ret
        cmp r15, 6
        je parse_sys
        cmp r15, 7
        je parse_db
        ret
.not_found:
    ret

; ==============================================================================
; PARSERS
; ==============================================================================
parse_alu:
    movzx r14, byte [rsi + 5]
    call get_token
    call is_register
    cmp rax, -1
    je error_exit
    mov r12, rax
    call get_token
    call is_register
    cmp rax, -1
    je error_exit
    mov r13, rax
    
    test r11, r11
    jz .skip_emit
    
    call emit_byte
    db 0x48
    mov rdi, r14
    call emit_byte
    mov rdi, r12
    or rdi, 0xC0
    mov rax, r13
    shl rax, 3
    or rdi, rax
    call emit_byte
    
.skip_emit:
    add qword [pc_vaddr], 3
    ret

parse_mov:
    call get_token
    call is_register
    cmp rax, -1
    je error_exit
    mov r12, rax
    
    call get_token
    call is_register
    cmp rax, -1
    jne .mov_reg_reg
    
    call find_symbol
    cmp rax, 0
    jne .got_imm
    call is_number
    cmp rdx, 1
    jne .check_pass
    jmp .got_imm
.check_pass:
    test r11, r11
    jnz error_exit
    xor rax, rax
.got_imm:
    mov r13, rax
    
.mov_reg_imm:
    test r11, r11
    jz .skip_emit
    
    call emit_byte
    db 0x48
    call emit_byte
    db 0xC7
    mov rdi, r12
    or rdi, 0xC0
    call emit_byte
    mov rdi, r13
    call emit_dword
    
    add qword [pc_vaddr], 7
    ret

.mov_reg_reg:
    mov r13, rax
    test r11, r11
    jz .skip_emit
    
    call emit_byte
    db 0x48
    call emit_byte
    db 0x89
    mov rdi, r12
    or rdi, 0xC0
    mov rax, r13
    shl rax, 3
    or rdi, rax
    call emit_byte
    
.skip_emit:
    add qword [pc_vaddr], 7
    ret

parse_jmp:
    movzx r14, byte [rsi + 5]
    call get_token
    call find_symbol
    cmp rax, 0
    jne .got_target
    test r11, r11
    jnz error_exit
.got_target:
    mov rbx, [pc_vaddr]
    add rbx, 5
    sub rax, rbx
    
    test r11, r11
    jz .skip_emit
    
    mov rdi, r14
    call emit_byte
    mov rdi, rax
    call emit_dword
    
.skip_emit:
    add qword [pc_vaddr], 5
    ret

parse_jcc:
    movzx r14, byte [rsi + 5]
    call get_token
    call find_symbol
    cmp rax, 0
    jne .got_target
    test r11, r11
    jnz error_exit
.got_target:
    mov rbx, [pc_vaddr]
    add rbx, 6
    sub rax, rbx
    
    test r11, r11
    jz .skip_emit
    
    call emit_byte
    db 0x0F
    mov rdi, r14
    call emit_byte
    mov rdi, rax
    call emit_dword
    
.skip_emit:
    add qword [pc_vaddr], 6
    ret

parse_call:
    call get_token
    call find_symbol
    cmp rax, 0
    jne .got_target
    test r11, r11
    jnz error_exit
.got_target:
    mov rbx, [pc_vaddr]
    add rbx, 5
    sub rax, rbx
    
    test r11, r11
    jz .skip_emit
    
    call emit_byte
    db 0xE8
    mov rdi, rax
    call emit_dword
    
.skip_emit:
    add qword [pc_vaddr], 5
    ret

parse_ret:
    test r11, r11
    jz .skip_emit
    call emit_byte
    db 0xC3
.skip_emit:
    add qword [pc_vaddr], 1
    ret

parse_sys:
    test r11, r11
    jz .skip_emit
    call emit_byte
    db 0x0F
    call emit_byte
    db 0x05
.skip_emit:
    add qword [pc_vaddr], 2
    ret

parse_db:
.db_loop:
    call get_token
    cmp rcx, 0
    je .db_done
    call is_number
    cmp rdx, 1
    jne .db_done
    test r11, r11
    jz .skip_emit
    mov rdi, rax
    call emit_byte
.skip_emit:
    add qword [pc_vaddr], 1
    jmp .db_loop
.db_done:
    ret

; ==============================================================================
; HELPERS
; ==============================================================================
get_token:
.skip_ws:
    mov al, byte [r13]
    cmp al, 0
    je .eos
    cmp al, 10
    je .eol
    cmp al, 32
    je .inc
    cmp al, 9
    je .inc
    cmp al, ','
    je .inc
    cmp al, ';'
    je .eol
    mov rdi, r13
    xor rcx, rcx
.scan_token:
    mov al, byte [r13 + rcx]
    cmp al, 32
    je .end_token
    cmp al, 10
    je .end_token
    cmp al, 13
    je .end_token
    cmp al, 9
    je .end_token
    cmp al, ','
    je .end_token
    cmp al, 0
    je .end_token
    inc rcx
    jmp .scan_token
.end_token:
    add r13, rcx
    ret
.inc:
    inc r13
    jmp .skip_ws
.eol:
    xor rcx, rcx
    mov rdi, 0
    ret
.eos:
    xor rcx, rcx
    mov rdi, 0
    ret

is_register:
    cmp rcx, 3
    jne .no_reg
    mov eax, [rdi]
    and eax, 0x00FFFFFF
    cmp eax, 'rax'
    je .r0
    cmp eax, 'rcx'
    je .r1
    cmp eax, 'rdx'
    je .r2
    cmp eax, 'rbx'
    je .r3
    cmp eax, 'rsp'
    je .r4
    cmp eax, 'rbp'
    je .r5
    cmp eax, 'rsi'
    je .r6
    cmp eax, 'rdi'
    je .r7
.no_reg:
    mov rax, -1
    ret
.r0: mov eax, 0 ; ret
.r1: mov eax, 1 ; ret
.r2: mov eax, 2 ; ret
.r3: mov eax, 3 ; ret
.r4: mov eax, 4 ; ret
.r5: mov eax, 5 ; ret
.r6: mov eax, 6 ; ret
.r7: mov eax, 7 ; ret

is_number:
    xor rax, rax
    xor rdx, rdx
    cmp rcx, 0
    je .done
    cmp rcx, 2
    jl .dec
    cmp word [rdi], '0x'
    je .hex
.dec:
    mov r9, rdi
    add r9, rcx
.dec_loop:
    cmp rdi, r9
    jge .done
    movzx rbx, byte [rdi]
    sub rbx, '0'
    cmp rbx, 9
    ja .invalid
    imul rax, 10
    add rax, rbx
    inc rdi
    jmp .dec_loop
.hex:
    add rdi, 2
    sub rcx, 2
    mov r9, rdi
    add r9, rcx
.hex_loop:
    cmp rdi, r9
    jge .done
    movzx rbx, byte [rdi]
    cmp bl, '0'
    jb .invalid
    cmp bl, '9'
    jbe .is_digit
    or bl, 32
    cmp bl, 'a'
    jb .invalid
    cmp bl, 'f'
    ja .invalid
    sub bl, 'a' - 10
    jmp .hex_add
.is_digit:
    sub bl, '0'
.hex_add:
    imul rax, 16
    add rax, rbx
    inc rdi
    jmp .hex_loop
.done:
    mov rdx, 1
    ret
.invalid:
    mov rdx, 0
    ret

find_symbol:
    call hash_str_token
    mov rbx, [sym_cnt]
    xor r9, r9
.sym_loop:
    cmp r9, rbx
    jge .not_found
    mov rcx, r9
    imul rcx, 24
    lea r8, [sym_tbl + rcx]
    mov r10, [r8]
    cmp r10, rax
    jne .next_sym
    mov rax, [r8 + 16]
    ret
.next_sym:
    inc r9
    jmp .sym_loop
.not_found:
    xor rax, rax
    ret

emit_byte:
    test r11, r11
    jz .skip
    mov rbx, [out_ptr]
    mov byte [out_buf + rbx], dil
    inc qword [out_ptr]
.skip:
    ret

emit_dword:
    test r11, r11
    jz .skip
    mov rbx, [out_ptr]
    mov dword [out_buf + rbx], edi
    add qword [out_ptr], 4
.skip:
    ret

; ==============================================================================
; OPCODE TABLE
; ==============================================================================
align 8
opcode_table:
    db "mov ", 1, 0x89, 0xB8, 0
    db "add ", 0, 0x01, 0, 0
    db "sub ", 0, 0x29, 0, 0
    db "cmp ", 0, 0x39, 0, 0
    db "xor ", 0, 0x31, 0, 0
    db "and ", 0, 0x21, 0, 0
    db "jmp ", 2, 0xE9, 0, 0
    db "je  ", 3, 0x84, 0, 0
    db "jne ", 3, 0x85, 0, 0
    db "jl  ", 3, 0x8C, 0, 0
    db "jg  ", 3, 0x8F, 0, 0
    db "call", 4, 0xE8, 0, 0
    db "ret ", 5, 0xC3, 0, 0
    db "sysc", 6, 0x0F, 0x05, 0
    db "sys ", 6, 0x0F, 0x05, 0
    db "db  ", 7, 0, 0, 0
    db "    ", 0, 0, 0, 0 ; terminator

; --- DEMO PROGRAM (This block is assembled by the tool itself) ---
demo_start:
    mov rax, 60
    xor rdi, rdi
    syscall