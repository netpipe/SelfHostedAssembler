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
; The defaults, for the no-argument invocation every test here uses.
def_in_path db "selfHosted.asm", 0
def_out_path db "a.out", 0
err_msg db "Error: ", 10
err_len equ 8
unk_msg db "Error: unknown mnemonic: "
unk_len equ 25
nl_msg db 10
sym_msg db "Error: symbol table full", 10
sym_msg_len equ 25
big_msg db "Error: input larger than the buffer", 10
big_len equ 36
code_msg db "Error: code ran into the .bss base address", 10
code_len equ 43
bss_msg db "Error: .bss reservation is implausibly large", 10
bss_len equ 44
b8_msg db "Error: 8-bit register with an immediate is not supported", 10
b8_len equ 57
args_msg db "Error: usage: mini_asm [input.asm [output]] [-b BASE]", 10
args_len equ 54
pass_msg db "Error: the two passes disagree about the size of the output", 10
pass_len equ 59

section .bss
in_buf resb 1048576 ; 1MB input buffer
out_buf resb 1048576 ; 1MB output buffer
sym_tbl resb 262144 ; symbol table
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
imm_tmp resq 1   ; the immediate being encoded, parked across emit_* calls
bss_size resq 1  ; bytes reserved by resb/resw/resd/resq so far
data_split resq 1 ; file offset of `section .data`, or 0 if there was none
sym_addr resq 1  ; the address add_symbol is about to record

; Where the OUTPUT is linked. Runtime state now, not assemble-time constants:
; the address a program is loaded at is a property of the machine it will run
; on, and this assembler now has to produce binaries for two of them -- Linux
; at 0x400000, and nano-os, whose user address space starts at 512 GiB.
; Both passes read these, and they are set before pass 1 from the command line,
; so the two passes never disagree about a value.
out_base resq 1  ; -b, or 0x400000
code_base resq 1 ; out_base + hdr_size -- the entry point
bss_base resq 1  ; out_base + bss_gap
in_path_p resq 1
out_path_p resq 1

; argv, and the scratch the argument parser and the OS block use.
g_argc resq 1
g_argv resq 1
a_i resq 1
a_pos resq 1
a_cur resq 1
t_path resq 1
t_fd resq 1
t_n resq 1
t_buf resq 1
t_res resq 1
pass1_end resq 1 ; where pass 1 finished; pass 2 has to finish in the same place

section .text

; --- CONSTANTS ---
; 176 = one 64-byte ELF header and TWO 56-byte program headers.
;
; Two, because one segment has to be both writable and executable and that is
; the single property every "write some bytes, then jump to them" technique
; needs. A `section .data` in the source splits the image: everything before it
; is read+execute, everything after is read+write, and nothing is both.
;
; A source with no `section .data` still gets one RWX segment, because its code
; and its data are interleaved and there is nowhere to cut. e_phnum is patched
; to 1 in that case rather than leaving a second header full of zeros.
hdr_size equ 176

; Where resb/resq reservations live: a fixed distance above the output base,
; deliberately, and not "wherever the code happens to end".
;
; The assembler is two-pass, and pass 2 must emit exactly the byte counts pass 1
; measured. Instruction length here depends on the VALUE of an operand -- an
; immediate that fits in 32 bits is `mov reg, imm32`, one that does not is the
; 10-byte movabs form. If a .bss label were placed after the code, its value
; would not be known until pass 1 had finished, so pass 1 would size it as one
; instruction and pass 2 as another, and every label after that point would be
; wrong. A fixed base is known before pass 1 starts, so both passes agree.
;
; Everything between p_filesz and p_memsz is zero-filled by the kernel, so the
; gap between the end of the code and here costs address space and nothing at
; all in the file or in resident memory.
bss_gap equ 0x400000
bss_max equ 0x40000000        ; a reservation larger than 1 GiB is a typo
sym_max equ 10922 ; sym_tbl is 262144 bytes at 24 bytes per entry. The original
                 ; reserved 4096 bytes and claimed 256 entries, which would have
                 ; run 2 KB past the end of the table.
                 ;
                 ; 65536 bytes (2730 entries) was enough for every hand-written
                 ; program here and not for a real one: nano_cc's own source
                 ; comes out as 4024 labels, so the first thing this assembler
                 ; was pointed at that it had not been sized for hit the limit.
                 ; It said so rather than overrunning, which is the only reason
                 ; that was a five-minute problem.
buf_size equ 1048576

; --- ELF64 HEADER (120 Bytes) ---
elf_hdr:
db 0x7f, "ELF", 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
dw 2 ; e_type = ET_EXEC
dw 0x3e ; e_machine = EM_X86_64
dd 1 ; e_version
dq 0 ; e_entry (PATCHED LATER -- depends on -b)
dq 64 ; e_phoff
dq 0 ; e_shoff
dd 0 ; e_flags
dw 64 ; e_ehsize
dw 56 ; e_phentsize
dw 2 ; e_phnum (PATCHED to 1 when there is no data section)
dw 0 ; e_shentsize
dw 0 ; e_shnum
dw 0 ; e_shstrndx
phdr:
dd 1 ; p_type = PT_LOAD
dd 7 ; p_flags (PATCHED: 5 = R|X when there are two segments, 7 if one)
dq 0 ; p_offset
dq 0 ; p_vaddr (PATCHED LATER)
dq 0 ; p_paddr (PATCHED LATER)
dq 0 ; p_filesz (PATCHED LATER)
dq 0 ; p_memsz (PATCHED LATER)
dq 0x1000 ; p_align

; The second segment: the data half. Left as PT_NULL and only filled in if a
; `section .data` turned up, so an image with one segment does not carry a
; header describing a region that does not exist.
phdr2:
dd 0 ; p_type = PT_NULL (PATCHED to PT_LOAD)
dd 6 ; p_flags = PF_R | PF_W -- and deliberately not PF_X
dq 0 ; p_offset (PATCHED LATER)
dq 0 ; p_vaddr (PATCHED LATER)
dq 0 ; p_paddr (PATCHED LATER)
dq 0 ; p_filesz (PATCHED LATER)
dq 0 ; p_memsz (PATCHED LATER)
dq 0x1000 ; p_align

; ==== TARGET BEGIN ====
; ==============================================================================
; TARGET: LINUX
; ==============================================================================
; Everything the assembler needs from the operating system it RUNS on lives in
; this block, and nothing outside it issues a syscall or knows a syscall
; number. `tools/retarget.py` swaps everything between the two TARGET markers
; for another block -- fixed/target-nanoos.inc -- and produces the same
; assembler, from the same body, running on nano-os instead.
;
; That is a split worth being deliberate about, because the alternative is two
; copies of a 1,900-line assembler that drift apart -- and a divergence between
; them would show up as a miscompilation on one platform and not the other,
; which is close to the worst shape a bug can have.
;
; Note the OTHER axis, which is independent of this one: which OS the assembler
; runs on has nothing to do with which base address it EMITS for. That is the
; -b flag, and it is why building a nano-os assembler on Linux is possible at
; all -- the Linux build, told -b 0x8000000000, produces the nano-os binary.
;
; The four routines and their contracts:
;   os_read_input   rdi = path                  -> rax = bytes read into in_buf,
;                                                  or negative if unreadable
;   os_write_output rdi = path, rsi = buf,
;                   rdx = length                -> rax = 0, or negative
;   os_err          rsi = buf, rdx = length     -> writes to stderr
;   os_exit         rdi = status                -> does not return
;
; and one constant, def_base: where output goes when -b is not given. That is a
; property of the machine you would normally be assembling FOR, so it belongs
; with the target rather than with the assembler.
; ==============================================================================

def_base equ 0x400000

_start:
    ; Linux puts argc at [rsp] and argv immediately above it. This has to be
    ; the very first thing that runs: a `call` would put a return address
    ; exactly where argc is.
    mov rax, [rsp]
    mov [g_argc], rax
    mov rax, rsp
    add rax, 8
    mov [g_argv], rax
    jmp main_flow

os_read_input:
    mov [t_path], rdi
    mov rax, 2                  ; sys_open
    mov rdi, [t_path]
    xor rsi, rsi                ; O_RDONLY
    xor rdx, rdx
    syscall
    test rax, rax
    js .fail
    mov [t_fd], rax
    mov rax, 0                  ; sys_read
    mov rdi, [t_fd]
    lea rsi, [rip + in_buf]
    mov rdx, buf_size
    syscall
    mov [t_n], rax
    mov rax, 3                  ; sys_close
    mov rdi, [t_fd]
    syscall
    mov rax, [t_n]
    ret
.fail:
    mov rax, -1
    ret

os_write_output:
    mov [t_path], rdi
    mov [t_buf], rsi
    mov [t_n], rdx
    mov rax, 2                  ; sys_open
    mov rdi, [t_path]
    mov rsi, 577                ; O_WRONLY | O_CREAT | O_TRUNC
    mov rdx, 420                ; 0644
    syscall
    test rax, rax
    js .fail
    mov [t_fd], rax
    mov rax, 1                  ; sys_write
    mov rdi, [t_fd]
    mov rsi, [t_buf]
    mov rdx, [t_n]
    syscall
    mov [t_n], rax
    mov rax, 3                  ; sys_close
    mov rdi, [t_fd]
    syscall
    xor rax, rax
    ret
.fail:
    mov rax, -1
    ret

os_err:
    mov rax, 1                  ; sys_write
    mov rdi, 2                  ; stderr
    syscall
    ret

os_exit:
    mov rax, 60
    syscall
; ==== TARGET END ====

; cstr_len — length of the NUL-terminated string at rdi, in rcx.
; is_number wants a pointer and a length; argv gives a pointer and a NUL.
cstr_len:
    xor rcx, rcx
.loop:
    movzx rax, byte [rdi + rcx]
    cmp al, 0
    je .done
    inc rcx
    jmp .loop
.done:
    ret

; parse_args — mini_asm [input.asm [output]] [-b BASE]
;
; With no arguments at all it behaves exactly as it always has: selfHosted.asm
; in, a.out out, linked at 0x400000. Every existing test invokes it that way,
; which is the point -- adding arguments must not change the no-argument case.
;
; Loop state lives in memory rather than registers because is_number clobbers
; rax, rbx, rcx, rdx, rdi, r8 and r9, and the argument index was in one of them
; the first time this was written.
parse_args:
    ; Through a register for the same reason as the base below: a store of an
    ; immediate to memory carries 32 bits, and a symbol above 2 GiB does not
    ; fit in them.
    lea rax, [rip + def_in_path]
    mov [in_path_p], rax
    lea rax, [rip + def_out_path]
    mov [out_path_p], rax
    ; Through a register, not `mov qword [mem], def_base`. A store of an
    ; immediate to memory carries 32 bits and sign-extends them; 0x400000 fits
    ; and nano-os's 0x8000000000 does not, so writing it that way is correct on
    ; one target and silently a different number on the other. GNU as refuses
    ; it outright, which is the good outcome -- but only because it was asked.
    mov rax, def_base
    mov [out_base], rax
    mov qword [a_i], 1
    mov qword [a_pos], 0
.loop:
    mov rax, [a_i]
    cmp rax, [g_argc]
    jge .done
    mov rbx, rax
    shl rbx, 3
    add rbx, [g_argv]
    mov rdi, [rbx]
    mov [a_cur], rdi
    movzx rax, byte [rdi]
    cmp al, '-'
    jne .positional

    ; -b BASE
    movzx rax, byte [rdi + 1]
    cmp al, 'b'
    jne bad_args
    movzx rax, byte [rdi + 2]
    cmp al, 0
    jne bad_args
    mov rax, [a_i]
    inc rax
    mov [a_i], rax
    cmp rax, [g_argc]
    jge bad_args                ; -b with nothing after it
    mov rbx, rax
    shl rbx, 3
    add rbx, [g_argv]
    mov rdi, [rbx]
    call cstr_len
    call is_number
    cmp rdx, 1
    jne bad_args
    mov [out_base], rax
    jmp .next

.positional:
    mov rax, [a_pos]
    cmp rax, 0
    jne .second
    mov rax, [a_cur]
    mov [in_path_p], rax
    mov qword [a_pos], 1
    jmp .next
.second:
    cmp rax, 1
    jne bad_args                ; a third file name is a mistake, not an input
    mov rax, [a_cur]
    mov [out_path_p], rax
    mov qword [a_pos], 2

.next:
    mov rax, [a_i]
    inc rax
    mov [a_i], rax
    jmp .loop

.done:
    ; Everything else is derived, once, before pass 1 -- so both passes see the
    ; same addresses and size every instruction the same way.
    mov rax, [out_base]
    add rax, hdr_size
    mov [code_base], rax
    mov rax, [out_base]
    add rax, bss_gap
    mov [bss_base], rax
    ret

main_flow:
    call parse_args

    ; 1. Read the input
    mov rdi, [in_path_p]
    call os_read_input
    test rax, rax
    js error_exit
    mov [in_size], rax
    ; A short read would silently assemble the first N bytes and drop the rest,
    ; which is far worse than refusing.
    cmp rax, buf_size
    jge input_too_big

    ; 2. Initialize Output Buffer with ELF Header
    lea rsi, [elf_hdr]
    lea rdi, [out_buf]
    mov rcx, hdr_size
    rep movsb

    ; 3. Pass 1: Scan Labels & Calculate Sizes
    mov qword [sym_cnt], 0
    mov rax, [code_base]
    mov [pc_vaddr], rax
    mov qword [out_ptr], hdr_size
    mov qword [bss_size], 0
    mov qword [data_split], 0
    xor r11, r11 ; r11 = 0 (Pass 1 mode)
    call process_file

    ; Remember where pass 1 finished. The two passes MUST agree, and until this
    ; check existed they could disagree silently -- see the note at .imm. A
    ; divergence does not produce a broken-looking binary, it produces a
    ; plausible one whose labels are all wrong past the first instruction that
    ; changed size.
    mov rax, [pc_vaddr]
    mov [pass1_end], rax

    ; 4. Pass 2: Generate Machine Code
    mov rax, [code_base]
    mov [pc_vaddr], rax
    mov qword [out_ptr], hdr_size
    mov qword [bss_size], 0
    mov qword [data_split], 0
    mov r11, 1 ; r11 = 1 (Pass 2 mode)
    call process_file

    mov rax, [pc_vaddr]
    cmp rax, [pass1_end]
    jne pass_mismatch

    ; 5. Check the code did not run into the .bss base, then patch the header.
    ;
    ; The two are the same check: if the emitted code reached the .bss base, a
    ; reservation and an instruction are sharing an address, and the program
    ; would overwrite its own code the first time it touched that global.
    mov rax, [pc_vaddr]
    cmp rax, [bss_base]
    jae code_too_big

    lea rdi, [rip + out_buf]

    ; The load address, which is only known now: it came from -b.
    mov rax, [code_base]
    mov [rdi+24], rax           ; e_entry
    mov rax, [out_base]
    mov [rdi+80], rax           ; p_vaddr
    mov [rdi+88], rax           ; p_paddr

    cmp qword [data_split], 0
    jne .two_segments

    ; ---- one segment ----
    ; No `section .data`, so code and data are interleaved and there is nowhere
    ; to cut. It stays RWX, and e_phnum drops to 1 rather than leaving a header
    ; that describes a segment which does not exist. The image is byte for byte
    ; what it always was.
    ;
    ; p_filesz is what is in the file. p_memsz reaches past the end of it to
    ; cover the reservations, and the loader zero-fills the difference -- which
    ; is the whole point: 19 MB of uninitialised globals cost nothing.
    mov word [rdi+56], 1        ; e_phnum
    mov rax, [out_ptr]
    mov [rdi+96], rax           ; p_filesz
    mov [rdi+104], rax          ; p_memsz
    cmp qword [bss_size], 0
    je .patched
    mov rax, bss_gap
    add rax, [bss_size]
    mov [rdi+104], rax
    jmp .patched

.two_segments:
    ; ---- two: read+execute up to the split, read+write after it ----
    ; Nothing is both, which is the only property that matters here.
    mov dword [rdi+68], 5       ; phdr1 p_flags = PF_R | PF_X
    mov rax, [data_split]
    mov [rdi+96], rax           ; phdr1 p_filesz = everything before the split
    mov [rdi+104], rax          ; phdr1 p_memsz  = the same; code is all file

    mov dword [rdi+120], 1      ; phdr2 p_type = PT_LOAD
    mov rax, [data_split]
    mov [rdi+128], rax          ; phdr2 p_offset
    mov rbx, [out_base]
    add rbx, rax
    mov [rdi+136], rbx          ; phdr2 p_vaddr
    mov [rdi+144], rbx          ; phdr2 p_paddr
    mov rbx, [out_ptr]
    sub rbx, rax
    mov [rdi+152], rbx          ; phdr2 p_filesz = the rest of the file
    mov [rdi+160], rbx          ; phdr2 p_memsz, unless something was reserved
    cmp qword [bss_size], 0
    je .patched
    ; The .bss sits bss_gap above the base, so measured from the data segment's
    ; own start it reaches (bss_gap - split) + bss_size. Everything between the
    ; end of the file and there is zero-filled by the loader.
    mov rbx, bss_gap
    sub rbx, rax
    add rbx, [bss_size]
    mov [rdi+160], rbx
.patched:

    ; 6. Write the output
    mov rdi, [out_path_p]
    lea rsi, [rip + out_buf]
    mov rdx, [out_ptr]
    call os_write_output
    test rax, rax
    js error_exit

    ; 7. Exit
    xor rdi, rdi
    call os_exit

pass_mismatch:
    lea rsi, [rip + pass_msg]
    mov rdx, pass_len
    call os_err
    mov rdi, 1
    call os_exit

bad_args:
    lea rsi, [rip + args_msg]
    mov rdx, args_len
    call os_err
    mov rdi, 1
    call os_exit

error_exit:
    lea rsi, [rip + err_msg]
    mov rdx, err_len
    call os_err
    call print_source_line
    mov rdi, 1
    call os_exit


code_too_big:
    lea rsi, [rip + code_msg]
    mov rdx, code_len
    call os_err
    mov rdi, 1
    call os_exit

bss_too_big:
    lea rsi, [rip + bss_msg]
    mov rdx, bss_len
    call os_err
    mov rdi, 1
    call os_exit

; `mov al, 9` and `cmp al, 9` are outside the documented subset, and until now
; they did not say so -- they assembled to something else and said nothing.
;
;   mov al, 9   ->  88 c0   which is `mov al, al`. parse_mov checks for a
;                   byte-sized operand BEFORE it checks for an immediate, so
;                   it read the immediate slot as a register index and found 0.
;   cmp al, 9   ->  48 83 f8 09   which is `cmp rax, 9`. parse_alu checks for
;                   the immediate first and never looks at the operand size, so
;                   it compared all 64 bits of rax when only al was written.
;
; The second is the worse one: it is a correct instruction for the wrong
; register, and after `mov al, [rsi]` the upper 56 bits of rax are whatever they
; were, so it compares a byte against nine and then fails on a value nobody
; wrote. Refusing is not the whole answer -- encoding b0+r and 3c would be --
; but an error is strictly better than plausible wrong bytes, and it makes the
; documented subset something the assembler actually enforces.
byte_imm_unsupported:
    lea rsi, [rip + b8_msg]
    mov rdx, b8_len
    call os_err
    mov rdi, 1
    call os_exit

input_too_big:
    lea rsi, [rip + big_msg]
    mov rdx, big_len
    call os_err
    mov rdi, 1
    call os_exit

; A word that is neither a known instruction nor a known directive. Reported
; rather than skipped: silently dropping a line the assembler does not
; understand produces a binary that is quietly missing instructions.
; print_source_line — write the source line r13 is pointing into, to stderr.
;
; "Error: " with nothing after it was by a wide margin the most expensive thing
; about working with this assembler. It is a fine report for a nine-line test
; program and useless for a real one: the first real input pointed at it was
; 39,000 lines, and nothing in the message said which of them it objected to.
;
; r13 is the read pointer, so walk back to the newline before it and forward to
; the one after, and print what lies between.
print_source_line:
    lea r8, [in_buf]
    mov r9, [in_size]
    add r9, r8
    cmp r13, r8
    jb .none                    ; r13 is not in the buffer: the open failed,
    cmp r13, r9                 ; and there is no line to point at
    ja .none
    mov rsi, r13
.back:
    cmp rsi, r8
    jbe .fwd_init
    mov rdi, rsi
    sub rdi, 1
    movzx rax, byte [rdi]
    cmp al, 10
    je .fwd_init
    mov rsi, rdi
    jmp .back
.fwd_init:
    xor rcx, rcx
.fwd:
    cmp rcx, 200                ; one line, not the rest of the file
    jge .print
    movzx rax, byte [rsi + rcx]
    cmp al, 0
    je .print
    cmp al, 10
    je .print
    inc rcx
    jmp .fwd
.print:
    cmp rcx, 0
    je .none
    mov rdx, rcx
    call os_err                 ; rsi is already the start of the line
    lea rsi, [rip + nl_msg]
    mov rdx, 1
    call os_err
.none:
    ret

unknown_mnemonic:
    lea rsi, [rip + unk_msg]
    mov rdx, unk_len
    call os_err
    lea rsi, [rip + key_buf]
    mov rdx, 4
    call os_err
    lea rsi, [rip + nl_msg]
    mov rdx, 1
    call os_err
    call print_source_line
    mov rdi, 1
    call os_exit

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
; Pad to the next page and record where the data half of the image starts.
;
; The padding has to happen in BOTH passes, or they disagree about every
; address after it -- so the count comes from pc_vaddr, which is correct in
; both, rather than from out_ptr, which only moves in the emit pass.
;
; A page boundary is not decoration either. The loader maps a segment at
; p_vaddr with the file bytes from p_offset, and the two have to be congruent
; modulo the page size. Splitting mid-page would put one page in two segments
; with different permissions, and whichever was mapped second would win.
start_data_section:
    mov rax, [pc_vaddr]
    neg rax
    and rax, 4095
    mov [t_res], rax            ; how many bytes of padding
.pad:
    cmp qword [t_res], 0
    je .padded
    xor rdi, rdi
    call emit_byte              ; emits in pass 2 only
    inc qword [pc_vaddr]        ; but the address advances in both
    dec qword [t_res]
    jmp .pad
.padded:
    mov rax, [pc_vaddr]
    sub rax, [code_base]
    add rax, hdr_size           ; a file offset, not an offset into the code
    mov [data_split], rax
    ret

; label_name_len — length of the name at rdi, up to whitespace or end of line.
; Returns it in rcx, which is what add_symbol and hash_str_token expect.
; Shared by "name db ..." and "name resb ..." rather than written twice: two
; copies of a name scanner is two places for the terminator set to drift.
label_name_len:
    xor rcx, rcx
.scan:
    movzx rax, byte [rdi + rcx]
    cmp al, ' '
    je .done
    cmp al, 9
    je .done
    cmp al, 0
    je .done
    cmp al, 10
    je .done
    inc rcx
    jmp .scan
.done:
    ret

; add_symbol      — define the name at rdi/rcx at the current code address.
; add_symbol_abs  — define it at the address in rax instead, for .bss labels,
;                   which are nowhere near the program counter.
add_symbol:
    mov rax, [pc_vaddr]
add_symbol_abs:
    mov [sym_addr], rax         ; parked: hash_str_token returns in rax
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
    lea rdi, [rip + sym_tbl]
    add rdi, rax
    pop rax
    mov [rdi], rax
    mov [rdi+8], r9
    mov rax, [sym_addr]
    mov [rdi+16], rax
    inc qword [sym_cnt]
.done:
    ret

sym_overflow:
    lea rsi, [rip + sym_msg]
    mov rdx, sym_msg_len
    call os_err
    mov rdi, 1
    call os_exit

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
; ident_char — is al part of an identifier?  in: al   out: rdx = 1 if yes.
;
; a-z was the whole test until nano_cc's output arrived. That output is full of
; names like `_n`, `cont_lbl` and `asm_sym.buf`, and word_key stopped at the
; first character outside a-z -- so `_n resb 8` produced a key of four spaces,
; which then matched the '    ' terminator of whichever table was searched next
; and the line was silently treated as a directive to ignore. The label was
; never defined, and the first use of it failed with no indication that a
; DEFINITION had gone missing rather than a reference being wrong.
ident_char:
    mov rdx, 1
    cmp al, 'a'
    jb .upper
    cmp al, 'z'
    jbe .yes
.upper:
    cmp al, 'A'
    jb .digit
    cmp al, 'Z'
    jbe .yes
.digit:
    cmp al, '0'
    jb .punct
    cmp al, '9'
    jbe .yes
.punct:
    cmp al, '_'
    je .yes
    cmp al, '.'
    je .yes
    cmp al, '$'
    je .yes
    xor rdx, rdx
.yes:
    ret

; word_key — the first four identifier characters at rdi, space-padded, as one
; 32-bit key. Advances rdi past the WHOLE word, however long it is.
word_key:
    xor rcx, rcx
.copy:
    movzx rax, byte [rdi]
    call ident_char
    cmp rdx, 0
    je .fill
    cmp rcx, 4
    jge .skip_rest
    lea rbx, [rip + key_buf]
    add rbx, rcx
    mov byte [rbx], al
    inc rcx
    inc rdi
    jmp .copy
.skip_rest:
    inc rdi
    movzx rax, byte [rdi]
    call ident_char
    cmp rdx, 0
    je .fill
    jmp .skip_rest
.fill:
    cmp rcx, 4
    jge .done
    lea rbx, [rip + key_buf]
    add rbx, rcx
    mov byte [rbx], ' '
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
    cmp dword [r8], '    '      ; terminator first -- see parse_instruction
    je .no
    cmp dword [r8], eax
    je .yes
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
    ; The terminator is tested FIRST. Both tables end with a '    ' entry, and
    ; a key of four spaces is a real possibility -- word_key produces one for a
    ; word made entirely of characters it does not accept. Matching the
    ; terminator as though it were an opcode sent the assembler into a table
    ; entry that is not one.
    cmp dword [rsi], '    '
    je .not_found
    cmp dword [rsi], eax
    je .found
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
    cmp r15, 10
    je parse_int
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
    je .maybe_section

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
    mov qword [data_size], 1
    cmp eax, 'resb'
    je .reserve
    mov qword [data_size], 2
    cmp eax, 'resw'
    je .reserve
    mov qword [data_size], 4
    cmp eax, 'resd'
    je .reserve
    mov qword [data_size], 8
    cmp eax, 'resq'
    je .reserve
    call is_directive
    cmp rdx, 1
    je .skip
    mov eax, [mnemonic_buf]
    mov dword [key_buf], eax
    jmp unknown_mnemonic

.maybe_section:
    ; Directives are ignored -- except that `section .data` marks where the
    ; writable half of the image begins, which is the whole basis of emitting
    ; two segments instead of one.
    mov eax, [mnemonic_buf]
    cmp eax, 'sect'
    jne .skip
    mov rdi, r12
.sec_ws:
    movzx rax, byte [rdi]
    cmp al, ' '
    je .sec_adv
    cmp al, 9
    je .sec_adv
    jmp .sec_word
.sec_adv:
    inc rdi
    jmp .sec_ws
.sec_word:
    call word_key
    cmp eax, '.dat'
    jne .skip
    cmp qword [data_split], 0   ; only the FIRST one is a split
    jne .skip
    jmp start_data_section

.skip:
    ret

.reserve:
    ; "name resb N" — reserve N * width bytes of zeroed memory and define name
    ; at the address they will have. Nothing is emitted: that is the entire
    ; point, and it is why the same source came out at 61 MB when uninitialised
    ; globals were written as `db 0, 0, 0, ...` instead.
    ;
    ; Before this, the line fell through to is_directive and was skipped whole,
    ; so the LABEL WAS NEVER DEFINED -- and a program with a .bss died on the
    ; first reference to a global with an empty "Error:" and nothing else.
    mov rdi, r13
    call label_name_len
    mov rax, [bss_base]
    add rax, [bss_size]
    call add_symbol_abs

    mov r13, r12                ; consume "name resb"
    call get_token
    cmp rcx, 0
    je error_exit               ; a reservation with no count
    call is_number
    cmp rdx, 1
    jne error_exit              ; ... or one that is not a number
    mov rcx, [data_size]
    mul rcx                     ; rax = count * element width
    add rax, [bss_size]
    cmp rax, bss_max
    jae bss_too_big             ; also catches a count that wrapped
    mov [bss_size], rax
    ret

.data_label:
    ; "name db ..." — define name at the current address, then emit the bytes.
    mov rdi, r13
    call label_name_len
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
    ;
    ; The placeholder is out_base, NOT zero, and that is a correctness
    ; requirement rather than tidiness. `mov reg, imm` is seven bytes when the
    ; value fits in a signed 32-bit field and ten when it does not, so a
    ; placeholder of zero sizes a forward reference as the short form in pass 1
    ; and pass 2 then emits the long one. Every label after that point is wrong
    ; by three bytes per occurrence, and the program jumps into the middle of an
    ; instruction. It never showed up at 0x400000 because both the placeholder
    ; and the real address fit in 32 bits there; at nano-os's 512 GiB, neither
    ; does. out_base is the lowest address any symbol in the output can have,
    ; so it is in the same size class as all of them.
    test r11, r11
    jnz error_exit
    mov rax, [out_base]
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
    mov rax, [out_base]         ; same size class as the real value; see .imm
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
    mov rax, [out_base]         ; same size class as the real value; see .imm
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
    lea rdi, [rip + opA]
    call parse_operand
    lea rdi, [rip + opB]
    call parse_operand

    ; Before anything else: this instruction group has no 8-bit forms here, and
    ; the immediate path below would silently widen a byte compare to 64 bits.
    cmp qword [opA + 32], 1
    je byte_imm_unsupported
    cmp qword [opB + 32], 1
    je byte_imm_unsupported

    cmp qword [opB], 2
    je .imm_form

    cmp qword [opA], 1
    je .mem_dst
    cmp qword [opB], 1
    je .mem_src

    ; reg, reg
    mov r12, [opB + 8]
    lea r15, [rip + opA]
    jmp encode_rm

.mem_dst:                       ; mem, reg
    mov r12, [opB + 8]
    lea r15, [rip + opA]
    jmp encode_rm

.mem_src:                       ; reg, mem  ->  opcode + 2
    add rbp, 2
    mov r12, [opA + 8]
    lea r15, [rip + opB]
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
    lea r15, [rip + opA]
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
    lea r15, [rip + opA]
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
    lea rdi, [rip + opA]
    call parse_operand
    lea rdi, [rip + opB]
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
    lea r15, [rip + opA]
    jmp encode_rm

.from_mem:
    mov rbp, 0x8B
    mov r12, [opA + 8]
    lea r15, [rip + opB]
    jmp encode_rm

.byte_form:
    mov qword [rex_w], 0
    cmp qword [opB], 2
    je byte_imm_unsupported     ; mov al, 9 -- see the note by the label
    cmp qword [opB], 1
    je .byte_from_mem
    ; r/m8 <- reg8
    mov rbp, 0x88
    mov r12, [opB + 8]
    lea r15, [rip + opA]
    jmp encode_rm
.byte_from_mem:
    ; reg8 <- r/m8
    mov rbp, 0x8A
    mov r12, [opA + 8]
    lea r15, [rip + opB]
    jmp encode_rm

.imm_form:
    ; C7 /0 id carries a 32-bit field that the processor SIGN-EXTENDS to 64.
    ; An immediate outside -2^31..2^31-1 therefore cannot use it -- the value
    ; loaded would silently be a different number. GNU as switches to the
    ; 10-byte REX.W B8+rd io form for those, and keeps the 7-byte form when it
    ; fits, so both halves of that rule have to be matched here or the golden
    ; byte comparison fails.
    mov rax, [opB + 16]
    mov [imm_tmp], rax
    shl rax, 32
    sar rax, 32                 ; round-trip it through a 32-bit field
    cmp rax, [imm_tmp]
    je .imm32                   ; survived: the short form is exact

    ; only the register form has a full 64-bit immediate; there is no
    ; `mov [mem], imm64` on x86-64
    cmp qword [opA], 0
    jne error_exit

    mov rax, 0x48               ; REX.W
    mov rcx, [opA + 8]
    cmp rcx, 8
    jl .movabs_rex
    add rax, 1                  ; REX.B for r8..r15
.movabs_rex:
    mov rdi, rax
    call emit_byte
    mov rax, [opA + 8]
    and rax, 7
    add rax, 0xB8               ; B8+rd
    mov rdi, rax
    call emit_byte
    mov rdi, [imm_tmp]
    call emit_qword
    add qword [pc_vaddr], 10
    ret

.imm32:
    mov rbp, 0xC7
    xor r12, r12                ; /0
    lea r15, [rip + opA]
    call encode_rm
    mov rdi, [imm_tmp]
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
    lea rdi, [rip + opA]
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
    lea r15, [rip + opA]
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
    lea r15, [rip + opA]
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
    lea r15, [rip + opA]
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

; int N -- CD ib. Two bytes, and the only way a program says anything to
; nano-os, whose syscall boundary is vector 0x80. `syscall` is the Linux
; equivalent and was already here; without this one the assembler could build
; programs for exactly one of the two operating systems it now runs on.
;
; The operand is required to be a number in 0..255. `int` with a label, or with
; 0x180, is a mistake rather than something to truncate quietly.
parse_int:
    call get_token
    cmp rcx, 0
    je error_exit
    call is_number
    cmp rdx, 1
    jne error_exit
    cmp rax, 0
    jl error_exit
    cmp rax, 255
    jg error_exit
    mov [imm_tmp], rax
    test r11, r11
    jz .skip_emit
    mov rdi, 0xCD
    call emit_byte
    mov rdi, [imm_tmp]
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
    lea r8, [rip + sym_tbl]
    add r8, r10
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
    lea rbx, [rip + out_buf]
    add rbx, [out_ptr]
    mov byte [rbx], dil
    inc qword [out_ptr]
.skip:
    ret

emit_dword:
    test r11, r11
    jz .skip
    lea rbx, [rip + out_buf]
    add rbx, [out_ptr]
    mov dword [rbx], edi
    add qword [out_ptr], 4
.skip:
    ret

; ADDRESSING NOTE, for the six places below and above that look roundabout.
;
; `mov byte [out_buf + rbx], dil` encodes out_buf as a 32-bit absolute address.
; That is fine at 0x400000 and impossible at 0x8000000000, which is where
; nano-os puts user memory -- ld refuses it with "relocation truncated to fit",
; which is the good outcome, but only after the address is chosen. So a symbol
; plus a register index is written as a RIP-relative lea and an add: two
; instructions instead of one, and no assumption about how high the program
; lives.
;
; ------------------------------------------------------------------------------
; emit_qword: rdi = 64-bit value, little-endian, as two dwords.
; The value goes through a bss slot rather than a register because emit_dword
; is a helper and is free to clobber rbx (see the register contract at the top).
; ------------------------------------------------------------------------------
emit_qword:
    mov [imm_tmp], rdi
    call emit_dword
    mov rdi, [imm_tmp]
    shr rdi, 32
    call emit_dword
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
    db "int ", 10, 0xCD, 0, 0
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
    ; resb / resw / resd / resq are NO LONGER ignored either, for the same
    ; reason dw/dd/dq stopped being: "ignore it" and "handle it" look identical
    ; until something depends on the difference. They are handled in
    ; parse_instruction's .second path, as the SECOND word of "name resb N".
    ;
    ; A reservation that reaches here is therefore one with no name in front of
    ; it -- including `name: resb N`, where the colon makes the name a code
    ; label at the current address and leaves a bare `resb` behind. That form
    ; cannot be assembled correctly, so it is reported rather than skipped: the
    ; label would otherwise point into the middle of the code and every write
    ; through it would overwrite an instruction.
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