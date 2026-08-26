; ==============================================================================
; MINI-ASM: an x86-64 assembler
; ==============================================================================
; Dialect: Strict subset of NASM/FASM.
; Supports: mov, add, sub, cmp, xor, and, jmp, je, jne, jl, jg, call, ret, syscall, db
; Registers: rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi
;
; REGISTER CONTRACT  (this was the source of most of the original bugs)
;   r11 = pass mode: 0 = sizing pass, 1 = emit pass
;   r13 = input read pointer   <- parsers must NEVER write to this
;   r14 = input end pointer    <- parsers must NEVER write to this
;   rsi = current opcode-table entry, set by parse_instruction
;   r12, r15, rbp = parser scratch
;   Helpers (get_token, is_register, is_number, find_symbol, emit_*) are free to
;   clobber rax, rbx, rcx, rdx, rdi, r8, r9, r10 and nothing else.
;
; Sizes emitted in pass 2 must match the sizes counted in pass 1 exactly, or
; every label address is wrong. Each parser therefore has ONE `add [pc_vaddr]`
; per operand form, shared by both passes.
; ==============================================================================
global _start

section .data
in_path db "selfHosted.asm", 0
out_path db "a.out", 0
err_msg db "Error: ", 10
err_len equ 8
unk_msg db "Error: unknown mnemonic: "
unk_len equ 25
nl_msg db 10
sym_msg db "Error: symbol table full", 10
sym_msg_len equ 25

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
key_buf resb 8 ; 4-char space-padded lookup key built by word_key

section .text

; --- CONSTANTS ---
base_vaddr equ 0x400000
hdr_size equ 120
code_vaddr equ base_vaddr + hdr_size
sym_max equ 170 ; sym_tbl is 4096 bytes at 24 bytes per entry (the original
                ; comment claimed 256, which would have run 2 KB past the table)

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

; A word that is neither a known instruction nor a known directive. Reported
; rather than skipped: silently dropping a line the assembler does not
; understand produces a binary that is quietly missing instructions.
unknown_mnemonic:
    mov rax, 1
    mov rdi, 2
    mov rsi, unk_msg
    mov rdx, unk_len
    syscall
    mov rax, 1
    mov rdi, 2
    mov rsi, key_buf
    mov rdx, 4
    syscall
    mov rax, 1
    mov rdi, 2
    mov rsi, nl_msg
    mov rdx, 1
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
    cmp al, 13
    je .inc_ptr
    cmp al, ';'
    je .skip_to_nl
    cmp al, '%'
    je .skip_to_nl
    ; The original tested a SINGLE character here to skip section/global/extern/
    ; resb, which also threw away every instruction starting with s, g, e or r —
    ; sub, syscall, ret, shl and shr among them. Directives are now recognised by
    ; whole word in parse_instruction instead.
    ; Check for label
    mov rdi, r13
    xor rcx, rcx
.scan_label:
    mov al, byte [rdi + rcx]
    cmp al, ':'
    je .found_label
    cmp al, ' '
    je .is_instr
    cmp al, 9
    je .is_instr
    cmp al, 10
    je .is_instr
    cmp al, 13
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
    ; A parser stops at the end of its operands, not the end of the line. The
    ; original did a bare `inc r13` here, so a trailing comment or space left
    ; the rest of the line to be parsed as another instruction.
    jmp .skip_to_nl

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
    jmp add_symbol              ; tail call

; ------------------------------------------------------------------------------
; add_symbol: record a symbol at the current pc_vaddr.
;   in: rdi = name, rcx = name length
; Entry layout (24 bytes): [0] hash, [8] name length, [16] vaddr. The length is
; stored as well as the hash so that two different names have to collide on BOTH
; before find_symbol confuses them.
; Only defined during pass 1; pass 2 would otherwise append a second copy of
; every symbol and overflow the table.
; ------------------------------------------------------------------------------
add_symbol:
    test r11, r11
    jnz .done                   ; pass 2: symbols are already known
    mov rbx, [sym_cnt]
    cmp rbx, sym_max
    jge sym_overflow
    call hash_str_token
    mov r9, rcx                 ; keep the length
    mov rbx, [sym_cnt]
    push rax
    mov rcx, 24
    mov rax, rbx
    mul rcx
    lea rdi, [sym_tbl + rax]
    pop rax
    mov [rdi], rax
    mov [rdi+8], r9
    mov rax, [pc_vaddr]
    mov [rdi+16], rax
    inc qword [sym_cnt]
.done:
    ret

sym_overflow:
    mov rax, 1
    mov rdi, 2
    mov rsi, sym_msg
    mov rdx, sym_msg_len
    syscall
    mov rax, 60
    mov rdi, 1
    syscall

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

; ------------------------------------------------------------------------------
; word_key: build a 4-character, space-padded lookup key from a word.
;   in : rdi = first character of the word
;   out: eax = the key, rdi advanced past the whole word
; Only rax/rcx/rdi are touched. r13 is deliberately NOT used, so callers can look
; ahead at a second word without disturbing the read pointer.
; ------------------------------------------------------------------------------
word_key:
    xor rcx, rcx
.copy:
    movzx rax, byte [rdi]
    cmp al, 'a'
    jb .fill
    cmp al, 'z'
    ja .fill
    cmp rcx, 4
    jge .skip_rest
    mov byte [key_buf + rcx], al
    inc rcx
    inc rdi
    jmp .copy
.skip_rest:
    inc rdi
    movzx rax, byte [rdi]
    cmp al, 'a'
    jb .fill
    cmp al, 'z'
    ja .fill
    jmp .skip_rest
.fill:
    cmp rcx, 4
    jge .done
    mov byte [key_buf + rcx], ' '
    inc rcx
    jmp .fill
.done:
    mov eax, [key_buf]
    ret

; ------------------------------------------------------------------------------
; is_directive: is eax one of the NASM directives we deliberately ignore?
;   out: rdx = 1 if yes, 0 if no.  eax preserved.
; ------------------------------------------------------------------------------
is_directive:
    lea r8, [directive_table]
.loop:
    cmp dword [r8], eax
    je .yes
    cmp dword [r8], '    '
    je .no
    add r8, 4
    jmp .loop
.yes:
    mov rdx, 1
    ret
.no:
    xor rdx, rdx
    ret

parse_instruction:
    ; Build the mnemonic key WITHOUT moving r13. The original advanced r13 one
    ; byte per letter copied and then did an unconditional `sub r13, 4`, which
    ; for any mnemonic shorter than 4 letters left r13 pointing before the
    ; mnemonic — so the mnemonic was never consumed and came back out of
    ; get_token as the first operand.
    mov rdi, r13
    call word_key
    mov r12, rdi                ; first char after the mnemonic

    lea rsi, [opcode_table]
.find_loop:
    cmp dword [rsi], eax
    je .found
    cmp dword [rsi], '    '
    je .not_found
    add rsi, 8
    jmp .find_loop

.found:
    mov r13, r12                ; consume the mnemonic, exactly once
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
    jmp error_exit              ; table entry with an unknown type

.not_found:
    ; Not an instruction. Either the line is a directive we ignore ("section
    ; .text", "global _start"), or the SECOND word is one ("err_len equ 8",
    ; "in_buf resb 65536"), or it is a data definition ("in_path db ..."), which
    ; declares a label at the current address. Anything else is a genuine typo
    ; and must be reported, not silently swallowed.
    mov dword [mnemonic_buf], eax   ; keep word 1 for the error message
    call is_directive
    cmp rdx, 1
    je .skip

    mov rdi, r12                ; look at the second word
.skip_ws:
    movzx rax, byte [rdi]
    cmp al, ' '
    je .adv
    cmp al, 9
    je .adv
    jmp .second
.adv:
    inc rdi
    jmp .skip_ws
.second:
    call word_key
    mov r12, rdi                ; first char after word 2
    cmp eax, 'db  '
    je .data_label
    call is_directive
    cmp rdx, 1
    je .skip
    mov eax, [mnemonic_buf]
    mov dword [key_buf], eax
    jmp unknown_mnemonic
.skip:
    ret

.data_label:
    ; "name db ..." — define name at the current address, then emit the bytes.
    mov rdi, r13
    xor rcx, rcx
.name_len:
    movzx rax, byte [rdi + rcx]
    cmp al, ' '
    je .got_name
    cmp al, 9
    je .got_name
    cmp al, 0
    je .got_name
    cmp al, 10
    je .got_name
    inc rcx
    jmp .name_len
.got_name:
    call add_symbol
    mov r13, r12                ; consume "name db"
    jmp parse_db

; ==============================================================================
; PARSERS
; ==============================================================================
; ALU reg, reg  ->  REX.W <op> /r   (3 bytes)
parse_alu:
    movzx rbp, byte [rsi + 5]   ; opcode. NOT r14: that is the input end pointer
    call get_token
    call is_register
    cmp rax, -1
    je error_exit
    mov r12, rax                ; destination register index
    call get_token
    call is_register
    cmp rax, -1
    je error_exit
    mov r15, rax                ; source register index. NOT r13: read pointer

    test r11, r11
    jz .skip_emit

    mov rdi, 0x48               ; REX.W. The original wrote a bare `db 0x48`
    call emit_byte              ; here, which sat in the instruction stream and
    mov rdi, rbp                ; executed as a prefix instead of being emitted.
    call emit_byte
    mov rdi, r12
    or rdi, 0xC0
    mov rax, r15
    shl rax, 3
    or rdi, rax
    call emit_byte

.skip_emit:
    add qword [pc_vaddr], 3
    ret

; mov reg, imm32  ->  REX.W C7 /0 id  (7 bytes)
; mov reg, reg    ->  REX.W 89 /r     (3 bytes)
; The two forms are different lengths. The original counted 7 for both, so every
; label defined after a `mov reg, reg` was placed at the wrong address and every
; jump/call displacement computed from it was wrong.
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
    ; Pass 1 tolerates a forward label reference; by pass 2 it must resolve.
    test r11, r11
    jnz error_exit
    xor rax, rax
.got_imm:
    mov r15, rax

    test r11, r11
    jz .size_imm

    mov rdi, 0x48
    call emit_byte
    mov rdi, 0xC7
    call emit_byte
    mov rdi, r12
    or rdi, 0xC0
    call emit_byte
    mov rdi, r15
    call emit_dword
.size_imm:
    add qword [pc_vaddr], 7
    ret

.mov_reg_reg:
    mov r15, rax
    test r11, r11
    jz .size_reg

    mov rdi, 0x48
    call emit_byte
    mov rdi, 0x89
    call emit_byte
    mov rdi, r12
    or rdi, 0xC0
    mov rax, r15
    shl rax, 3
    or rdi, rax
    call emit_byte
.size_reg:
    add qword [pc_vaddr], 3
    ret

; jmp rel32  ->  E9 cd  (5 bytes)
parse_jmp:
    movzx rbp, byte [rsi + 5]
    call get_token
    call find_symbol
    cmp rax, 0
    jne .got_target
    test r11, r11
    jnz error_exit
.got_target:
    mov rbx, [pc_vaddr]
    add rbx, 5                  ; rel32 is relative to the END of the instruction
    sub rax, rbx

    test r11, r11
    jz .skip_emit

    mov rdi, rbp
    call emit_byte
    mov rdi, rax
    call emit_dword

.skip_emit:
    add qword [pc_vaddr], 5
    ret

; jcc rel32  ->  0F 8x cd  (6 bytes)
parse_jcc:
    movzx rbp, byte [rsi + 5]
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

    mov rdi, 0x0F
    call emit_byte
    mov rdi, rbp
    call emit_byte
    mov rdi, rax
    call emit_dword

.skip_emit:
    add qword [pc_vaddr], 6
    ret

; call rel32  ->  E8 cd  (5 bytes)
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

    mov rdi, 0xE8
    call emit_byte
    mov rdi, rax
    call emit_dword

.skip_emit:
    add qword [pc_vaddr], 5
    ret

parse_ret:
    test r11, r11
    jz .skip_emit
    mov rdi, 0xC3
    call emit_byte
.skip_emit:
    add qword [pc_vaddr], 1
    ret

parse_sys:
    test r11, r11
    jz .skip_emit
    mov rdi, 0x0F
    call emit_byte
    mov rdi, 0x05
    call emit_byte
.skip_emit:
    add qword [pc_vaddr], 2
    ret

; db: a comma-separated list of byte values and/or "strings".
; get_token splits on spaces and commas, so it cannot carry a string containing
; either; the string case is therefore scanned straight off the read pointer.
parse_db:
.db_loop:
    movzx rax, byte [r13]
    cmp al, ' '
    je .adv
    cmp al, 9
    je .adv
    cmp al, ','
    je .adv
    cmp al, 13
    je .adv
    cmp al, 10
    je .db_done
    cmp al, 0
    je .db_done
    cmp al, ';'
    je .db_done
    cmp al, '"'
    je .string
    call get_token
    cmp rcx, 0
    je .db_done
    call is_number
    cmp rdx, 1
    jne error_exit
    mov rdi, rax
    call emit_byte              ; emit_byte is a no-op during the sizing pass
    add qword [pc_vaddr], 1
    jmp .db_loop
.adv:
    inc r13
    jmp .db_loop
.string:
    inc r13                     ; past the opening quote
.str_loop:
    movzx rax, byte [r13]
    cmp al, '"'
    je .str_end
    cmp al, 0
    je error_exit               ; unterminated string
    cmp al, 10
    je error_exit
    mov rdi, rax
    call emit_byte
    add qword [pc_vaddr], 1
    inc r13
    jmp .str_loop
.str_end:
    inc r13
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
; Every one of these used to read `.rN: mov eax, N ; ret` — the semicolon made
; the ret a comment, so .r0 fell through .r1 .. .r7 and out of the function into
; is_number. All eight register names resolved to the same value.
.r0: mov eax, 0
    ret
.r1: mov eax, 1
    ret
.r2: mov eax, 2
    ret
.r3: mov eax, 3
    ret
.r4: mov eax, 4
    ret
.r5: mov eax, 5
    ret
.r6: mov eax, 6
    ret
.r7: mov eax, 7
    ret

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

; find_symbol must leave rdi and rcx (the token) intact, because parse_mov calls
; is_number straight afterwards when the lookup misses. The original used rcx as
; its loop scratch, so the token length was destroyed on the way through.
find_symbol:
    call hash_str_token
    mov rbx, [sym_cnt]
    xor r9, r9
.sym_loop:
    cmp r9, rbx
    jge .not_found
    mov r10, r9
    imul r10, 24
    lea r8, [sym_tbl + r10]
    mov r10, [r8]
    cmp r10, rax
    jne .next_sym
    mov r10, [r8 + 8]           ; hashes match; the lengths must too
    cmp r10, rcx
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

; NASM directives that are recognised and ignored, matched as whole words. Four
; bytes each, space padded, same key format as the opcode table.
align 4
directive_table:
    db "sect"          ; section
    db "glob"          ; global
    db "extr"          ; extern
    db "alig"          ; align
    db "bits"
    db "org "
    db "equ "
    db "resb"
    db "resw"
    db "resd"
    db "resq"
    db "dw  "
    db "dd  "
    db "dq  "
    db "time"          ; times
    db "    "          ; terminator

; --- DEMO PROGRAM (This block is assembled by the tool itself) ---
demo_start:
    mov rax, 60
    xor rdi, rdi
    syscall