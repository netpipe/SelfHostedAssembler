#include <stdio.h>

// --- Host I/O Wrappers ---
// In the self-compiled subset version, these are replaced with 'syscall' and 'print(ASCII)'
int get_host_char() { return getchar(); }
void put_host_char(int c) { putchar(c); }

// --- Subset-Compliant Compiler State ---
char src[100000];
int src_len = 0;
int pos = 0;
int line = 1;

int ch;
int token;
int token_val;
char token_name[64];

int sym_table[1000];
int sym_start[100];
int sym_end[100];
int sym_count = 0;
int sym_end_total = 0;

int label = 0;

void emit(char *s) {
    int i = 0;
    while (s[i] != 0) { put_host_char(s[i]); i = i + 1; }
}

void emit_int(int v) {
    if (v < 0) { put_host_char('-'); v = 0 - v; }
    if (v == 0) { put_host_char('0'); return; }
    int digits[20]; int count = 0;
    while (v > 0) {
        // Subset-compliant division by 10 using subtraction
        int q = 0; int r = v;
        while (r >= 10) { r = r - 10; q = q + 1; }
        digits[count] = r; v = q; count = count + 1;
    }
    while (count > 0) {
        count = count - 1;
        put_host_char(digits[count] + '0');
    }
}

void str_copy(char *dest, char *src) {
    int i = 0;
    while (src[i] != 0) { dest[i] = src[i]; i = i + 1; }
    dest[i] = 0;
}

int str_eq(char *a, char *b) {
    int i = 0;
    while (1) {
        if (a[i] != b[i]) return 0;
        if (a[i] == 0) return 1;
        i = i + 1;
    }
}

// --- Tokenizer ---
void read_char() {
    if (pos >= src_len) ch = -1;
    else { ch = src[pos]; pos = pos + 1; }
}

void next() {
    while (ch == ' ' || ch == '\n' || ch == '\t' || ch == '\r') {
        if (ch == '\n') line = line + 1;
        read_char();
    }
    if (ch == -1) { token = -1; return; }
    
    if (ch >= '0' && ch <= '9') {
        token = 258; // T_NUM
        token_val = 0;
        while (ch >= '0' && ch <= '9') {
            // Subset-compliant multiplication by 10 using addition
            int temp = token_val;
            int i = 0;
            while (i < 9) { token_val = token_val + temp; i = i + 1; }
            token_val = token_val + (ch - '0');
            read_char();
        }
        return;
    }
    
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
        int i = 0;
        token_name[i] = ch; i = i + 1; read_char();
        while ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_') {
            if (i < 63) { token_name[i] = ch; i = i + 1; }
            read_char();
        }
        token_name[i] = 0;
        if (str_eq(token_name, "while")) { token = 259; return; }
        if (str_eq(token_name, "if")) { token = 260; return; }
        if (str_eq(token_name, "else")) { token = 266; return; }
        if (str_eq(token_name, "print")) { token = 261; return; }
        token = 257; // T_VAR
        return;
    }
    
    if (ch == '=') { read_char(); if (ch == '=') { token = 262; read_char(); return; } token = '='; return; }
    if (ch == '!') { read_char(); if (ch == '=') { token = 263; read_char(); return; } return; }
    if (ch == '<') { read_char(); if (ch == '=') { token = 264; read_char(); return; } token = '<'; return; }
    if (ch == '>') { read_char(); if (ch == '=') { token = 265; read_char(); return; } token = '>'; return; }
    
    token = ch;
    read_char();
}

// --- Symbol Table ---
int find_var_by_name(char *name) {
    int i = 0;
    while (i < sym_count) {
        int k = sym_start[i]; int j = 0; int match = 1;
        while (k < sym_end[i]) {
            if (sym_table[k] != name[j]) { match = 0; break; }
            k = k + 1; j = j + 1;
        }
        if (match && name[j] == 0) return i;
        i = i + 1;
    }
    return -1;
}

int add_var_by_name(char *name) {
    int id = sym_count; sym_count = sym_count + 1;
    int k = 0; sym_start[id] = sym_end_total;
    while (name[k] != 0) { sym_table[sym_end_total] = name[k]; sym_end_total = sym_end_total + 1; k = k + 1; }
    sym_end[id] = sym_end_total;
    return id;
}

// --- Code Generators ---
void factor(); void term(); void expr();

void factor() {
    if (token == 258) { 
        emit("    mov rax, "); emit_int(token_val); emit("\n"); next();
    } else if (token == 257) {
        int id = find_var_by_name(token_name);
        if (id == -1) id = add_var_by_name(token_name);
        // Subset-compliant multiplication by 8 for offset
        int offset = 0; int i = 0;
        while (i < id) { offset = offset + 8; i = i + 1; }
        emit("    mov rax, [vars + "); emit_int(offset); emit("]\n"); next();
    } else if (token == '(') { next(); expr(); if (token == ')') next(); }
}

void term() {
    factor();
    while (token == '*' || token == '/') {
        int op = token; next();
        emit("    sub rsp, 8\n    mov [rsp], rax\n");
        factor();
        emit("    mov rcx, [rsp]\n    add rsp, 8\n");
        if (op == '*') {
            emit("    mov rbx, 0\nmul_loop:\n    cmp rax, 0\n    je mul_end\n    add rbx, rcx\n    sub rax, 1\n    jmp mul_loop\nmul_end:\n    mov rax, rbx\n");
        } else {
            emit("    mov rbx, 0\ndiv_loop:\n    cmp rcx, rax\n    jl div_end\n    sub rcx, rax\n    add rbx, 1\n    jmp div_loop\ndiv_end:\n    mov rax, rbx\n");
        }
    }
}

void expr() {
    term();
    while (token == '+' || token == '-') {
        int op = token; next();
        emit("    sub rsp, 8\n    mov [rsp], rax\n");
        term();
        emit("    mov rcx, [rsp]\n    add rsp, 8\n");
        if (op == '+') emit("    add rax, rcx\n");
        else { emit("    sub rcx, rax\n    mov rax, rcx\n"); }
    }
}

void condition() {
    expr();
    int op = token;
    if (op == 262 || op == 263 || op == 264 || op == 265 || op == '<' || op == '>') {
        next();
        emit("    sub rsp, 8\n    mov [rsp], rax\n");
        expr();
        emit("    mov rcx, [rsp]\n    add rsp, 8\n");
        emit("    cmp rcx, rax\n");
        int lbl_t = label; label = label + 1;
        int lbl_e = label; label = label + 1;
        
        if (op == 262) emit("    je lbl_");
        else if (op == 263) emit("    jne lbl_");
        else if (op == '<') emit("    jl lbl_");
        else if (op == '>') emit("    jg lbl_");
        else if (op == 264) { emit("    jl lbl_"); emit_int(lbl_t); emit("\n    je lbl_"); }
        else if (op == 265) { emit("    jg lbl_"); emit_int(lbl_t); emit("\n    je lbl_"); }
        
        emit_int(lbl_t); emit("\n    mov rax, 0\n    jmp lbl_"); emit_int(lbl_e); emit("\n");
        emit("lbl_"); emit_int(lbl_t); emit(":\n    mov rax, 1\nlbl_"); emit_int(lbl_e); emit(":\n");
    }
}

void statement();

void statement() {
    if (token == 257) {
        char name[64]; str_copy(name, token_name); next();
        if (token == '=') {
            next(); expr();
            int id = find_var_by_name(name);
            if (id == -1) id = add_var_by_name(name);
            int offset = 0; int i = 0;
            while (i < id) { offset = offset + 8; i = i + 1; }
            emit("    mov [vars + "); emit_int(offset); emit("], rax\n");
        } else if (token == '(') {
            if (str_eq(name, "print")) {
                next(); expr();
                if (token == ')') next();
                emit("    call print_int\n");
            }
        }
        if (token == ';') next();
    } else if (token == 260) {
        next(); if (token == '(') next();
        condition(); if (token == ')') next();
        int lbl_else = label; label = label + 1;
        int lbl_end = label; label = label + 1;
        emit("    cmp rax, 0\n    je lbl_"); emit_int(lbl_else); emit("\n");
        statement();
        emit("    jmp lbl_"); emit_int(lbl_end); emit("\nlbl_"); emit_int(lbl_else); emit(":\n");
        if (token == 266) { next(); statement(); }
        emit("lbl_"); emit_int(lbl_end); emit(":\n");
    } else if (token == 259) {
        next();
        int lbl_start = label; label = label + 1;
        int lbl_end = label; label = label + 1;
        emit("lbl_"); emit_int(lbl_start); emit(":\n");
        if (token == '(') next(); condition(); if (token == ')') next();
        emit("    cmp rax, 0\n    je lbl_"); emit_int(lbl_end); emit("\n");
        statement();
        emit("    jmp lbl_"); emit_int(lbl_start); emit("\nlbl_"); emit_int(lbl_end); emit(":\n");
    } else if (token == '{') {
        next();
        while (token != '}' && token != -1) statement();
        if (token == '}') next();
    } else if (token == ';') next();
}

void emit_print_int() {
    emit("print_int:\n");
    emit("    mov r10, 0\n    cmp rax, 0\n    jge not_neg\n");
    emit("    mov r10, 1\n    mov rbx, 0\n    sub rbx, rax\n    mov rax, rbx\nnot_neg:\n");
    emit("    cmp rax, 0\n    je print_zero\nprint_loop:\n    cmp rax, 0\n    je print_done\n");
    emit("    mov rcx, rax\n    mov rbx, 0\n    mov rdi, 10\ndiv10_loop:\n    cmp rcx, rdi\n    jl div10_end\n");
    emit("    sub rcx, rdi\n    add rbx, 1\n    jmp div10_loop\ndiv10_end:\n    add rcx, 48\n");
    emit("    sub r8, 1\n    mov [r8], cl\n    add r9, 1\n    mov rax, rbx\n    jmp print_loop\nprint_done:\n");
    emit("    cmp r10, 0\n    je skip_minus\n    sub r8, 1\n    mov rcx, 0\n    add rcx, 45\n    mov [r8], cl\n    add r9, 1\n");
    emit("skip_minus:\n    mov rax, 1\n    mov rdi, 1\n    mov rsi, r8\n    mov rdx, r9\n    syscall\n    ret\n\n");
    emit("print_zero:\n    mov r8, vars + 200\n    sub r8, 1\n    mov rcx, 0\n    add rcx, 48\n    mov [r8], cl\n");
    emit("    mov r9, 1\n    cmp r10, 0\n    je skip_minus_z\n    sub r8, 1\n    mov rcx, 0\n    add rcx, 45\n    mov [r8], cl\n    add r9, 1\n");
    emit("skip_minus_z:\n    mov rax, 1\n    mov rdi, 1\n    mov rsi, r8\n    mov rdx, r9\n    syscall\n    ret\n");
}

void program() {
    emit("section .bss\n    vars resb 256\n\nsection .text\n    global _start\n\n_start:\n");
    if (token == 258 || token == 257) { 
         next(); if (token == 257) { next(); if (token == '(') next(); if (token == ')') next(); if (token == '{') next();
             while (token != '}' && token != -1) statement();
             if (token == '}') next();
         }
    } else while (token != -1) statement();
    
    emit("    mov rax, 60\n    xor rdi, rdi\n    syscall\n\n");
    emit_print_int();
}

int main() {
    int c;
    while ((c = get_host_char()) != -1) {
        src[src_len] = c; src_len = src_len + 1;
    }
    pos = 0; read_char(); next(); program();
    return 0;
}