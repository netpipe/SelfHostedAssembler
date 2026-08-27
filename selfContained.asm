; ==============================================================================
; MINI-ASM: an x86-64 assembler
; ==============================================================================
; Dialect: Strict subset of NASM/FASM.
;
; Instructions: mov, add, or, and, sub, xor, cmp, shl, shr, sar,
;               jmp, je/jz, jne/jnz, jl, jle, jg, jge, jb, jbe, ja, jae, js, jns,
;               call, ret, syscall, db
; Registers:    rax rcx rdx rbx rsp rbp rsi rdi r8..r15, and al cl dl bl
; Operands:     reg · imm32 · label
;               [reg] · [reg + N] · [reg - N] · [rip + label] · [label]
; Byte access:  mov al, [mem] and mov [mem], al (also cl, dl, bl). Required:
;               a 1-byte store cannot be synthesised from 8-byte operations
;               without touching memory the program may not own.
; Not supported: [base + index], scaled indexes, 16/32-bit operand sizes,
;               ah/ch/dh/bh, and an immediate written to memory.
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
big_msg db "Error: input larger than the buffer", 10
big_len equ 36

section .bss
in_buf resb 1048576 ; 1MB input buffer
out_buf resb 1048576 ; 1MB output buffer
sym_tbl resb 65536 ; symbol table
in_fd resq 1
out_fd resq 1
in_size resq 1
out_ptr resq 1
pc_vaddr resq 1 ; Virtual Program Counter
sym_cnt resq 1 ; Number of symbols
mnemonic_buf resb 8 ; Buffer for safe mnemonic parsing
key_buf resb 8 ; 4-char space-padded lookup key built by word_key
; Two parsed-operand slots. Layout, 32 bytes each:
;   +0  kind: 0 = register, 1 = memory, 2 = immediate
;   +8  register index 0-15 (kind 0), or the memory base register (kind 1)
;   +16 displacement (kind 1) or immediate value (kind 2)
;   +24 1 if the memory operand is RIP-relative
;   +32 operand size in bytes: 8 (default) or 1 (al/cl/dl/bl)
opA resb 40
opB resb 40
alu_digit resq 1 ; ModRM /digit for the immediate and shift forms
reg_size resq 1  ; size of the register is_register last recognised
rex_w resq 1     ; 1 = emit REX.W, 0 = 8-bit operand, REX only if needed
data_size resq 1 ; element width for dw/dd/dq: 2, 4 or 8 (0 selects db)

section .text

; --- CONSTANTS ---
base_vaddr equ 0x400000
hdr_size equ 120
code_vaddr equ base_vaddr + hdr_size
sym_max equ 2730 ; sym_tbl is 65536 bytes at 24 bytes per entry. The original
                 ; reserved 4096 bytes and claimed 256 entries, which would have
                 ; run 2 KB past the end of the table.
buf_size equ 1048576

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
dd 7 ; p_flags = PF_R | PF_W | PF_X  (data lives in the same segment,
     ; so without PF_W any write to a global faults)
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
    mov rdx, buf_size
    syscall
    mov [in_size], rax
    ; A short buffer would silently assemble the first N bytes and drop the
    ; rest, which is far worse than refusing.
    cmp rax, buf_size
    jge input_too_big
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

input_too_big:
    mov rax, 1
    mov rdi, 2
    mov rsi, big_msg
    mov rdx, big_len
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
    cmp r15, 8
    je parse_shift
    cmp r15, 9
    je .data_dir
    jmp error_exit              ; table entry with an unknown type

.data_dir:
    movzx rax, byte [rsi + 6]   ; element width, 2 / 4 / 8
    mov qword [data_size], rax
    jmp parse_data

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
    mov qword [data_size], 0    ; 0 selects parse_db (bytes, strings allowed)
    cmp eax, 'db  '
    je .data_label
    mov qword [data_size], 2
    cmp eax, 'dw  '
    je .data_label
    mov qword [data_size], 4
    cmp eax, 'dd  '
    je .data_label
    mov qword [data_size], 8
    cmp eax, 'dq  '
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
    mov r13, r12                ; consume "name db" / "name dq" / ...
    cmp qword [data_size], 0
    je parse_db
    jmp parse_data

; ==============================================================================
; PARSERS
; ==============================================================================
;
; A2: operands are parsed into the opA / opB slots by parse_operand, and encoded
; by encode_rm, which is shared by mov and all six ALU ops. Supported forms:
;
;   reg                      rax..rdi, r8..r15
;   imm / label
;   [reg]                    [rax] [rsp] [rbp] ...
;   [reg + N]  [reg - N]     [rbp - 8]
;   [rip + label]  [label]   RIP-relative, always disp32
;
; Not supported, and documented as such: [base + index], scaled indexes,
; 8/16/32-bit operand sizes, and memory destinations for an immediate.

; ------------------------------------------------------------------------------
; mem_token: read one word of a memory operand off r13.
;   out: rdi = start, rcx = length, r13 advanced past it
; Stops on space, tab, '+', '-' and ']' — get_token cannot be used here because
; it splits on commas and would swallow the bracket.
; ------------------------------------------------------------------------------
mem_token:
.skip:
    movzx rax, byte [r13]
    cmp al, ' '
    je .adv
    cmp al, 9
    je .adv
    jmp .start
.adv:
    inc r13
    jmp .skip
.start:
    mov rdi, r13
    xor rcx, rcx
.scan:
    movzx rax, byte [r13 + rcx]
    cmp al, ' '
    je .done
    cmp al, 9
    je .done
    cmp al, '+'
    je .done
    cmp al, '-'
    je .done
    cmp al, ']'
    je .done
    cmp al, 0
    je .done
    cmp al, 10
    je .done
    inc rcx
    jmp .scan
.done:
    add r13, rcx
    ret

; ------------------------------------------------------------------------------
; parse_operand: parse one operand at r13 into the slot whose base is in rdi.
; ------------------------------------------------------------------------------
parse_operand:
    mov r15, rdi
    mov qword [r15], 0
    mov qword [r15 + 8], 0
    mov qword [r15 + 16], 0
    mov qword [r15 + 24], 0
    mov qword [r15 + 32], 8
.skip:
    movzx rax, byte [r13]
    cmp al, ' '
    je .adv
    cmp al, 9
    je .adv
    cmp al, ','
    je .adv
    jmp .start
.adv:
    inc r13
    jmp .skip
.start:
    cmp al, '['
    je .mem

    call get_token
    call is_register
    cmp rax, -1
    je .not_reg
    mov qword [r15], 0          ; kind = register
    mov [r15 + 8], rax
    mov rax, [reg_size]
    mov [r15 + 32], rax
    ret
.not_reg:
    call find_symbol
    cmp rax, 0
    jne .imm
    call is_number
    cmp rdx, 1
    je .imm
    ; A label not yet defined. Tolerated in pass 1, an error by pass 2.
    test r11, r11
    jnz error_exit
    xor rax, rax
.imm:
    mov qword [r15], 2          ; kind = immediate
    mov [r15 + 16], rax
    ret

.mem:
    inc r13                     ; past '['
    mov qword [r15], 1          ; kind = memory
    call mem_token
    cmp rcx, 3
    jne .base_sym
    mov eax, [rdi]
    and eax, 0x00FFFFFF
    cmp eax, 'rip'
    je .rip_form
.base_sym:
    call is_register
    cmp rax, -1
    je .label_form
    mov [r15 + 8], rax          ; base register
    jmp .disp

.rip_form:
    mov qword [r15 + 24], 1
    ; expect "+ label"
.rip_skip:
    movzx rax, byte [r13]
    cmp al, ' '
    je .rip_adv
    cmp al, 9
    je .rip_adv
    cmp al, '+'
    je .rip_adv
    jmp .rip_word
.rip_adv:
    inc r13
    jmp .rip_skip
.rip_word:
    call mem_token
    call find_symbol
    cmp rax, 0
    jne .rip_got
    test r11, r11
    jnz error_exit
    xor rax, rax
.rip_got:
    mov [r15 + 16], rax         ; absolute target address
    jmp .label_disp

.label_form:
    ; [label] - treated as RIP-relative, same as [rip + label]
    mov qword [r15 + 24], 1
    call find_symbol
    cmp rax, 0
    jne .label_got
    test r11, r11
    jnz error_exit
    xor rax, rax
.label_got:
    mov [r15 + 16], rax
    ; fall through: a label may carry a displacement too

; An optional +N / -N after a label, as in [nums + 8]. This used to jump
; straight to .close, so the displacement was parsed by nobody and silently
; dropped -- [nums + 8] assembled as [nums]. It produced a working binary that
; read the wrong field, which is why only the byte comparison caught it.
.label_disp:
    movzx rax, byte [r13]
    cmp al, ' '
    je .label_disp_adv
    cmp al, 9
    je .label_disp_adv
    cmp al, '+'
    je .label_disp_plus
    cmp al, '-'
    je .label_disp_minus
    jmp .close
.label_disp_adv:
    inc r13
    jmp .label_disp
.label_disp_plus:
    inc r13
    call mem_token
    call is_number
    cmp rdx, 1
    jne error_exit
    add [r15 + 16], rax
    jmp .close
.label_disp_minus:
    inc r13
    call mem_token
    call is_number
    cmp rdx, 1
    jne error_exit
    sub [r15 + 16], rax
    jmp .close

.disp:
    movzx rax, byte [r13]
    cmp al, ' '
    je .disp_adv
    cmp al, 9
    je .disp_adv
    cmp al, ']'
    je .close
    cmp al, '+'
    je .disp_plus
    cmp al, '-'
    je .disp_minus
    jmp error_exit
.disp_adv:
    inc r13
    jmp .disp
.disp_plus:
    inc r13
    call mem_token
    call is_number
    cmp rdx, 1
    jne error_exit
    mov [r15 + 16], rax
    jmp .close
.disp_minus:
    inc r13
    call mem_token
    call is_number
    cmp rdx, 1
    jne error_exit
    mov rbx, 0
    sub rbx, rax
    mov [r15 + 16], rbx
    jmp .close

.close:
    movzx rax, byte [r13]
    cmp al, ']'
    je .close_done
    cmp al, 0
    je error_exit
    cmp al, 10
    je error_exit
    inc r13
    jmp .close
.close_done:
    inc r13
    ret

; ------------------------------------------------------------------------------
; encode_rm: emit  REX.W <opcode> ModRM [SIB] [disp]
;   rbp = opcode byte
;   r12 = the "reg" field (a register index 0-15)
;   r15 = slot base of the r/m operand (register or memory)
; Advances pc_vaddr by the exact size. Sizes depend only on operand shape and on
; displacement literals, both of which are known in pass 1, so the two passes
; always agree.
; ------------------------------------------------------------------------------
encode_rm:
    ; ---- REX ----
    ; For a 64-bit operand REX.W is mandatory. For an 8-bit operand there is no
    ; REX at all unless an extended register forces one.
    xor r10, r10
    cmp qword [rex_w], 0
    je .rex_optional
    mov r10, 0x48
.rex_optional:
    mov rax, r12
    cmp rax, 8
    jl .no_rex_r
    or r10, 0x44                ; REX.R (with the 0x40 base)
.no_rex_r:
    mov rax, [r15 + 8]
    cmp qword [r15 + 24], 1
    je .no_rex_b                ; RIP-relative has no base register
    cmp rax, 8
    jl .no_rex_b
    or r10, 0x41                ; REX.B
.no_rex_b:
    cmp r10, 0
    je .no_rex
    mov rdi, r10
    call emit_byte
    add qword [pc_vaddr], 1
.no_rex:
    mov rdi, rbp
    call emit_byte
    add qword [pc_vaddr], 1

    mov r9, r12
    and r9, 7
    shl r9, 3                   ; reg field, already shifted into place

    cmp qword [r15], 1
    je .mem
    ; ---- register direct: mod = 11 ----
    mov rax, [r15 + 8]
    and rax, 7
    or rax, r9
    or rax, 0xC0
    mov rdi, rax
    call emit_byte
    add qword [pc_vaddr], 1
    ret

.mem:
    cmp qword [r15 + 24], 1
    je .rip

    mov rbx, [r15 + 8]          ; base register
    mov r8, rbx
    and r8, 7                   ; low 3 bits = rm field
    mov rdx, [r15 + 16]         ; displacement

    ; mod selection. rbp and r13 (rm == 5) cannot use mod=00: that encoding
    ; means RIP-relative in 64-bit mode, so they always carry a displacement.
    test rdx, rdx
    jnz .need_disp
    cmp r8, 5
    je .need_disp
    xor rcx, rcx                ; mod = 00
    jmp .emit_modrm
.need_disp:
    mov rax, rdx
    cmp rax, 127
    jg .disp32
    cmp rax, -128
    jl .disp32
    mov rcx, 0x40               ; mod = 01, disp8
    jmp .emit_modrm
.disp32:
    mov rcx, 0x80               ; mod = 10, disp32

.emit_modrm:
    mov rax, r8
    or rax, r9
    or rax, rcx
    mov rdi, rax
    call emit_byte
    add qword [pc_vaddr], 1

    ; rsp and r12 (rm == 4) need a SIB byte selecting "base, no index"
    cmp r8, 4
    jne .no_sib
    mov rdi, 0x24
    call emit_byte
    add qword [pc_vaddr], 1
.no_sib:
    cmp rcx, 0x40
    je .emit_d8
    cmp rcx, 0x80
    je .emit_d32
    ret
.emit_d8:
    mov rdi, rdx
    call emit_byte
    add qword [pc_vaddr], 1
    ret
.emit_d32:
    mov rdi, rdx
    call emit_dword
    add qword [pc_vaddr], 4
    ret

.rip:
    ; mod = 00, rm = 101, disp32 relative to the end of the instruction
    mov rax, 5
    or rax, r9
    mov rdi, rax
    call emit_byte
    add qword [pc_vaddr], 1
    mov rax, [r15 + 16]
    mov rbx, [pc_vaddr]
    add rbx, 4                  ; the disp32 itself
    sub rax, rbx
    mov rdi, rax
    call emit_dword
    add qword [pc_vaddr], 4
    ret

; ------------------------------------------------------------------------------
; ALU: add / or / and / sub / xor / cmp
;   reg, reg     REX.W <op>   /r
;   mem, reg     REX.W <op>   /r
;   reg, mem     REX.W <op+2> /r
;   reg, imm8    REX.W 83 /d ib
;   reg, imm32   REX.W 81 /d id
; ------------------------------------------------------------------------------
parse_alu:
    mov qword [rex_w], 1
    movzx rbp, byte [rsi + 5]   ; base opcode
    movzx rax, byte [rsi + 6]   ; /digit for the immediate forms
    mov [alu_digit], rax        ; NOT r14: that is the input end pointer
    mov rdi, opA
    call parse_operand
    mov rdi, opB
    call parse_operand

    cmp qword [opB], 2
    je .imm_form

    cmp qword [opA], 1
    je .mem_dst
    cmp qword [opB], 1
    je .mem_src

    ; reg, reg
    mov r12, [opB + 8]
    mov r15, opA
    jmp encode_rm

.mem_dst:                       ; mem, reg
    mov r12, [opB + 8]
    mov r15, opA
    jmp encode_rm

.mem_src:                       ; reg, mem  ->  opcode + 2
    add rbp, 2
    mov r12, [opA + 8]
    mov r15, opB
    jmp encode_rm

.imm_form:
    mov rdx, [opB + 16]
    mov r10, rbp                ; keep the base opcode for the accumulator form
    mov r12, [alu_digit]        ; the /digit goes in the reg field
    mov rax, rdx
    cmp rax, 127
    jg .imm32
    cmp rax, -128
    jl .imm32
    mov rbp, 0x83
    mov r15, opA
    push rdx
    call encode_rm
    pop rdx
    mov rdi, rdx
    call emit_byte
    add qword [pc_vaddr], 1
    ret

.imm32:
    ; "<op> rax, imm32" has a one-byte-shorter accumulator form with no ModRM
    ; byte (opcode base + 4). binutils uses it, so match it.
    cmp qword [opA], 0
    jne .imm32_general
    cmp qword [opA + 8], 0
    jne .imm32_general
    mov rdi, 0x48
    call emit_byte
    mov rax, r10
    add rax, 4
    mov rdi, rax
    call emit_byte
    add qword [pc_vaddr], 2
    mov rdi, rdx
    call emit_dword
    add qword [pc_vaddr], 4
    ret

.imm32_general:
    mov rbp, 0x81
    mov r15, opA
    push rdx
    call encode_rm
    pop rdx
    mov rdi, rdx
    call emit_dword
    add qword [pc_vaddr], 4
    ret

; ------------------------------------------------------------------------------
; mov
;   reg, imm32   REX.W C7 /0 id
;   reg, reg     REX.W 89 /r
;   mem, reg     REX.W 89 /r
;   reg, mem     REX.W 8B /r
; ------------------------------------------------------------------------------
parse_mov:
    mov qword [rex_w], 1
    mov rdi, opA
    call parse_operand
    mov rdi, opB
    call parse_operand

    ; A byte-sized register on either side selects the 8-bit opcodes and drops
    ; REX.W. Needed for char loads and stores: a 1-byte store cannot be
    ; synthesised from 8-byte operations without reading memory you may not own.
    cmp qword [opA + 32], 1
    je .byte_form
    cmp qword [opB + 32], 1
    je .byte_form

    cmp qword [opB], 2
    je .imm_form
    cmp qword [opB], 1
    je .from_mem

    ; reg/mem <- reg
    mov rbp, 0x89
    mov r12, [opB + 8]
    mov r15, opA
    jmp encode_rm

.from_mem:
    mov rbp, 0x8B
    mov r12, [opA + 8]
    mov r15, opB
    jmp encode_rm

.byte_form:
    mov qword [rex_w], 0
    cmp qword [opB], 1
    je .byte_from_mem
    ; r/m8 <- reg8
    mov rbp, 0x88
    mov r12, [opB + 8]
    mov r15, opA
    jmp encode_rm
.byte_from_mem:
    ; reg8 <- r/m8
    mov rbp, 0x8A
    mov r12, [opA + 8]
    mov r15, opB
    jmp encode_rm

.imm_form:
    mov rbp, 0xC7
    xor r12, r12                ; /0
    mov r15, opA
    call encode_rm
    mov rdi, [opB + 16]
    call emit_dword
    add qword [pc_vaddr], 4
    ret

; ------------------------------------------------------------------------------
; shl / shr / sar
;   reg, imm8    REX.W C1 /d ib
;   reg, cl      REX.W D3 /d
; ------------------------------------------------------------------------------
parse_shift:
    mov qword [rex_w], 1
    movzx rax, byte [rsi + 5]   ; /digit: 4 = shl, 5 = shr, 7 = sar
    mov [alu_digit], rax
    mov rdi, opA
    call parse_operand

    ; second operand: "cl" or an immediate
    call get_token
    cmp rcx, 2
    jne .imm
    mov ax, word [rdi]
    cmp ax, 'cl'
    jne .imm

    mov rbp, 0xD3
    mov r12, [alu_digit]
    mov r15, opA
    jmp encode_rm

.imm:
    call is_number
    cmp rdx, 1
    jne error_exit
    mov rbx, rax
    ; shift-by-one has its own one-byte-shorter opcode, and binutils uses it,
    ; so match it or the golden byte comparison fails on a non-bug.
    cmp rbx, 1
    je .by_one
    mov rbp, 0xC1
    mov r12, [alu_digit]
    mov r15, opA
    push rbx
    call encode_rm
    pop rbx
    mov rdi, rbx
    call emit_byte
    add qword [pc_vaddr], 1
    ret
.by_one:
    mov rbp, 0xD1
    mov r12, [alu_digit]
    mov r15, opA
    jmp encode_rm

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

; ------------------------------------------------------------------------------
; dw / dd / dq: a comma-separated list of numbers and/or symbol addresses, each
; emitted little-endian in [data_size] bytes.
;
; A symbol is tried before a number because a data list is mostly labels, and
; find_symbol leaves rdi/rcx alone so is_number can still see the same token.
;
; Registers: r12 = value being shifted out, r15 = width, rbp = byte counter.
; rbp is used for the counter rather than r10 because helpers are free to
; clobber r10 and emit_byte is called from inside the loop.
; ------------------------------------------------------------------------------
parse_data:
.loop:
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
    je .done
    cmp al, 0
    je .done
    cmp al, ';'
    je .done
    call get_token
    cmp rcx, 0
    je .done
    call find_symbol
    cmp rax, 0
    jne .emit
    call is_number
    cmp rdx, 1
    je .emit
    ; Neither a number nor a symbol we know yet. During the sizing pass that is
    ; simply a forward reference -- `pp: dq msg` with msg defined further down
    ; is the normal case -- so emit a placeholder and let pass 2 resolve it.
    ; During the emit pass the symbol really is undefined.
    test r11, r11
    jnz error_exit
    xor rax, rax
.emit:
    mov r12, rax
    mov r15, [data_size]
    xor rbp, rbp
.byte_loop:
    cmp rbp, r15
    jge .advance_pc
    mov rdi, r12
    call emit_byte              ; a no-op during the sizing pass
    shr r12, 8
    inc rbp
    jmp .byte_loop
.advance_pc:
    mov rax, [data_size]
    add qword [pc_vaddr], rax
    jmp .loop
.adv:
    inc r13
    jmp .loop
.done:
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
    mov qword [reg_size], 8
    cmp rcx, 2
    je .two
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
    cmp eax, 'r10'
    je .r10
    cmp eax, 'r11'
    je .r11
    cmp eax, 'r12'
    je .r12
    cmp eax, 'r13'
    je .r13
    cmp eax, 'r14'
    je .r14
    cmp eax, 'r15'
    je .r15
    jmp .no_reg
.two:
    ; r8 and r9. The extended registers need REX.B when used as r/m and REX.R
    ; when used as the reg field; encode_rm derives both from the index.
    mov ax, word [rdi]
    cmp ax, 'r8'
    je .r8
    cmp ax, 'r9'
    je .r9
    ; The four byte registers that need no REX prefix. ah/ch/dh/bh are not
    ; supported: without REX, indexes 4-7 mean those rather than spl/bpl/sil/dil.
    cmp ax, 'al'
    je .b0
    cmp ax, 'cl'
    je .b1
    cmp ax, 'dl'
    je .b2
    cmp ax, 'bl'
    je .b3
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
.r8: mov eax, 8
    ret
.r9: mov eax, 9
    ret
.r10: mov eax, 10
    ret
.r11: mov eax, 11
    ret
.r12: mov eax, 12
    ret
.r13: mov eax, 13
    ret
.r14: mov eax, 14
    ret
.r15: mov eax, 15
    ret
.b0: mov qword [reg_size], 1
    mov eax, 0
    ret
.b1: mov qword [reg_size], 1
    mov eax, 1
    ret
.b2: mov qword [reg_size], 1
    mov eax, 2
    ret
.b3: mov qword [reg_size], 1
    mov eax, 3
    ret

is_number:
    xor rax, rax
    xor rdx, rdx
    xor r8, r8                  ; negative?
    cmp rcx, 0
    je .done
    ; A leading minus was not handled at all, so `xor rax, -1` - which is how a
    ; minimal-instruction-set compiler writes `not` - failed to parse.
    movzx rbx, byte [rdi]
    cmp bl, '-'
    jne .nosign
    mov r8, 1
    inc rdi
    dec rcx
    cmp rcx, 0
    je .invalid                 ; a lone "-" is not a number
.nosign:
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
    cmp r8, 0
    je .positive
    mov rbx, 0
    sub rbx, rax
    mov rax, rbx
.positive:
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
    ; name, type, opcode, ModRM /digit for the imm form, spare
    db "mov ", 1, 0x89, 0, 0
    db "add ", 0, 0x01, 0, 0
    db "or  ", 0, 0x09, 1, 0
    db "and ", 0, 0x21, 4, 0
    db "sub ", 0, 0x29, 5, 0
    db "xor ", 0, 0x31, 6, 0
    db "cmp ", 0, 0x39, 7, 0
    db "shl ", 8, 4, 0, 0
    db "shr ", 8, 5, 0, 0
    db "sar ", 8, 7, 0, 0
    db "jmp ", 2, 0xE9, 0, 0
    db "je  ", 3, 0x84, 0, 0
    db "jne ", 3, 0x85, 0, 0
    db "jl  ", 3, 0x8C, 0, 0
    db "jg  ", 3, 0x8F, 0, 0
    db "jz  ", 3, 0x84, 0, 0   ; alias of je
    db "jnz ", 3, 0x85, 0, 0   ; alias of jne
    db "jle ", 3, 0x8E, 0, 0
    db "jge ", 3, 0x8D, 0, 0
    db "jb  ", 3, 0x82, 0, 0
    db "jae ", 3, 0x83, 0, 0
    db "jbe ", 3, 0x86, 0, 0
    db "ja  ", 3, 0x87, 0, 0
    db "js  ", 3, 0x88, 0, 0
    db "jns ", 3, 0x89, 0, 0
    db "call", 4, 0xE8, 0, 0
    db "ret ", 5, 0xC3, 0, 0
    db "sysc", 6, 0x0F, 0x05, 0
    db "sys ", 6, 0x0F, 0x05, 0
    db "db  ", 7, 0, 0, 0
    db "dw  ", 9, 0, 2, 0   ; element width lives in the /digit byte
    db "dd  ", 9, 0, 4, 0
    db "dq  ", 9, 0, 8, 0
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
    ; dw / dd / dq are NO LONGER ignored -- they are real data directives now,
    ; handled by parse_data. Leaving them here made `pp: dq msg` emit nothing
    ; and skip pc_vaddr, so pp silently aliased whatever label came next.
    db "time"          ; times
    db "    "          ; terminator

; --- DEMO PROGRAM (This block is assembled by the tool itself) ---
demo_start:
    mov rax, 60
    xor rdi, rdi
    syscall