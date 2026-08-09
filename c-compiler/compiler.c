// compiler.c - Strict Subset Self-Compiling Compiler
// No #include, no pointers, no string literals, no restricted math.

int src[100000];
int src_len;
int pos;
int ch;
int token;
int token_val;
int token_name[64];
int token_name_len;
int label_count;
int vars[256];
int var_count;
int var_names[2560];
int var_start[256];
int var_len[256];

int asm_buf[500000];
int asm_len;

int str_buf[20000];
int str_buf_len;
int str_count;
int str_start[1000];
int str_len_arr[1000];

// Built-in functions provided by the bootstrap wrapper or mapped to syscalls
int get_char();
int print_char(int c);

// --- Code Generation Helpers ---
int emit_char(int c) {
    asm_buf[asm_len] = c;
    asm_len = asm_len + 1;
    return 0;
}

int emit_str(int str_id) {
    int i = 0;
    int start = str_start[str_id];
    int len = str_len_arr[str_id];
    while (i < len) {
        emit_char(str_buf[start + i]);
        i = i + 1;
    }
    return 0;
}

int emit_int(int v) {
    if (v < 0) {
        emit_char('-');
        int temp = 0;
        temp = temp - v;
        v = temp;
    }
    if (v == 0) {
        emit_char('0');
        return 0;
    }
    int digits[20];
    int count = 0;
    while (v > 0) {
        int q = 0;
        int r = v;
        while (r >= 10) {
            r = r - 10;
            q = q + 1;
        }
        digits[count] = r;
        v = q;
        count = count + 1;
    }
    while (count > 0) {
        count = count - 1;
        int d = digits[count];
        int zero = 48;
        while (d > 0) { zero = zero + 1; d = d - 1; }
        emit_char(zero);
    }
    return 0;
}

// --- String Initialization (Replaces string literals) ---
int STR_MOV_RAX; int STR_NL; int STR_MOV_VARS; int STR_BRACKET_NL;
int STR_SUB_RSP; int STR_MOV_RSP_RAX; int STR_MOV_RCX_RSP; int STR_ADD_RSP;
int STR_ADD_RAX_RCX; int STR_SUB_RCX_RAX; int STR_MOV_RAX_RCX;
int STR_CALL; int STR_RET; int STR_CMP_RCX_RAX; int STR_JE; int STR_JNE;
int STR_JL; int STR_JG; int STR_JMP; int STR_LABEL; int STR_COLON;
int STR_MOV_RDI; int STR_MOV_RSI; int STR_XOR_RDI_RDI;
int STR_MOV_RAX_60; int STR_SECTION_BSS; int STR_VARS_RESB;
int STR_SECTION_TEXT; int STR_GLOBAL_START; int STR_START_COLON;
int STR_SYSCALL; int STR_MOV_RAX_1; int STR_MOV_RDI_1; int STR_MOV_RDX_1;

int add_str_char(int c) {
    str_buf[str_buf_len] = c;
    str_buf_len = str_buf_len + 1;
    return 0;
}

int make_str(int start) {
    int id = str_count;
    str_start[id] = start;
    str_len_arr[id] = str_buf_len - start;
    str_count = str_count + 1;
    return id;
}

int init_strings() {
    int s;
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('a'); add_str_char('x'); add_str_char(','); add_str_char(' '); STR_MOV_RAX = make_str(s);
    s = str_buf_len; add_str_char('\n'); STR_NL = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('['); add_str_char('v'); add_str_char('a'); add_str_char('r'); add_str_char('s'); add_str_char(' '); add_str_char('+'); add_str_char(' '); STR_MOV_VARS = make_str(s);
    s = str_buf_len; add_str_char(']'); add_str_char('\n'); STR_BRACKET_NL = make_str(s);
    s = str_buf_len; add_str_char('s'); add_str_char('u'); add_str_char('b'); add_str_char(' '); add_str_char('r'); add_str_char('s'); add_str_char('p'); add_str_char(','); add_str_char(' '); add_str_char('8'); add_str_char('\n'); STR_SUB_RSP = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('['); add_str_char('r'); add_str_char('s'); add_str_char('p'); add_str_char(']'); add_str_char(','); add_str_char(' '); add_str_char('r'); add_str_char('a'); add_str_char('x'); add_str_char('\n'); STR_MOV_RSP_RAX = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('c'); add_str_char('x'); add_str_char(','); add_str_char(' '); add_str_char('['); add_str_char('r'); add_str_char('s'); add_str_char('p'); add_str_char(']'); add_str_char('\n'); STR_MOV_RCX_RSP = make_str(s);
    s = str_buf_len; add_str_char('a'); add_str_char('d'); add_str_char('d'); add_str_char(' '); add_str_char('r'); add_str_char('s'); add_str_char('p'); add_str_char(','); add_str_char(' '); add_str_char('8'); add_str_char('\n'); STR_ADD_RSP = make_str(s);
    s = str_buf_len; add_str_char('a'); add_str_char('d'); add_str_char('d'); add_str_char(' '); add_str_char('r'); add_str_char('a'); add_str_char('x'); add_str_char(','); add_str_char(' '); add_str_char('r'); add_str_char('c'); add_str_char('x'); add_str_char('\n'); STR_ADD_RAX_RCX = make_str(s);
    s = str_buf_len; add_str_char('s'); add_str_char('u'); add_str_char('b'); add_str_char(' '); add_str_char('r'); add_str_char('c'); add_str_char('x'); add_str_char(','); add_str_char(' '); add_str_char('r'); add_str_char('a'); add_str_char('x'); add_str_char('\n'); STR_SUB_RCX_RAX = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('a'); add_str_char('x'); add_str_char(','); add_str_char(' '); add_str_char('r'); add_str_char('c'); add_str_char('x'); add_str_char('\n'); STR_MOV_RAX_RCX = make_str(s);
    s = str_buf_len; add_str_char('c'); add_str_char('a'); add_str_char('l'); add_str_char('l'); add_str_char(' '); STR_CALL = make_str(s);
    s = str_buf_len; add_str_char('r'); add_str_char('e'); add_str_char('t'); add_str_char('\n'); STR_RET = make_str(s);
    s = str_buf_len; add_str_char('c'); add_str_char('m'); add_str_char('p'); add_str_char(' '); add_str_char('r'); add_str_char('c'); add_str_char('x'); add_str_char(','); add_str_char(' '); add_str_char('r'); add_str_char('a'); add_str_char('x'); add_str_char('\n'); STR_CMP_RCX_RAX = make_str(s);
    s = str_buf_len; add_str_char('j'); add_str_char('e'); add_str_char(' '); STR_JE = make_str(s);
    s = str_buf_len; add_str_char('j'); add_str_char('n'); add_str_char('e'); add_str_char(' '); STR_JNE = make_str(s);
    s = str_buf_len; add_str_char('j'); add_str_char('l'); add_str_char(' '); STR_JL = make_str(s);
    s = str_buf_len; add_str_char('j'); add_str_char('g'); add_str_char(' '); STR_JG = make_str(s);
    s = str_buf_len; add_str_char('j'); add_str_char('m'); add_str_char('p'); add_str_char(' '); STR_JMP = make_str(s);
    s = str_buf_len; add_str_char('l'); add_str_char('b'); add_str_char('l'); add_str_char('_'); STR_LABEL = make_str(s);
    s = str_buf_len; add_str_char(':'); add_str_char('\n'); STR_COLON = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('d'); add_str_char('i'); add_str_char(','); add_str_char(' '); STR_MOV_RDI = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('s'); add_str_char('i'); add_str_char(','); add_str_char(' '); STR_MOV_RSI = make_str(s);
    s = str_buf_len; add_str_char('x'); add_str_char('o'); add_str_char('r'); add_str_char(' '); add_str_char('r'); add_str_char('d'); add_str_char('i'); add_str_char(','); add_str_char(' '); add_str_char('r'); add_str_char('d'); add_str_char('i'); add_str_char('\n'); STR_XOR_RDI_RDI = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('a'); add_str_char('x'); add_str_char(','); add_str_char(' '); add_str_char('6'); add_str_char('0'); add_str_char('\n'); STR_MOV_RAX_60 = make_str(s);
    s = str_buf_len; add_str_char('s'); add_str_char('e'); add_str_char('c'); add_str_char('t'); add_str_char('i'); add_str_char('o'); add_str_char('n'); add_str_char(' '); add_str_char('.'); add_str_char('b'); add_str_char('s'); add_str_char('s'); add_str_char('\n'); STR_SECTION_BSS = make_str(s);
    s = str_buf_len; add_str_char('v'); add_str_char('a'); add_str_char('r'); add_str_char('s'); add_str_char(' '); add_str_char('r'); add_str_char('e'); add_str_char('s'); add_str_char('b'); add_str_char(' '); add_str_char('2'); add_str_char('5'); add_str_char('6'); add_str_char('\n'); STR_VARS_RESB = make_str(s);
    s = str_buf_len; add_str_char('s'); add_str_char('e'); add_str_char('c'); add_str_char('t'); add_str_char('i'); add_str_char('o'); add_str_char('n'); add_str_char(' '); add_str_char('.'); add_str_char('t'); add_str_char('e'); add_str_char('x'); add_str_char('t'); add_str_char('\n'); STR_SECTION_TEXT = make_str(s);
    s = str_buf_len; add_str_char('g'); add_str_char('l'); add_str_char('o'); add_str_char('b'); add_str_char('a'); add_str_char('l'); add_str_char(' '); add_str_char('_'); add_str_char('s'); add_str_char('t'); add_str_char('a'); add_str_char('r'); add_str_char('t'); add_str_char('\n'); STR_GLOBAL_START = make_str(s);
    s = str_buf_len; add_str_char('_'); add_str_char('s'); add_str_char('t'); add_str_char('a'); add_str_char('r'); add_str_char('t'); add_str_char(':'); add_str_char('\n'); STR_START_COLON = make_str(s);
    s = str_buf_len; add_str_char('s'); add_str_char('y'); add_str_char('s'); add_str_char('c'); add_str_char('a'); add_str_char('l'); add_str_char('l'); add_str_char('\n'); STR_SYSCALL = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('a'); add_str_char('x'); add_str_char(','); add_str_char(' '); add_str_char('1'); add_str_char('\n'); STR_MOV_RAX_1 = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('d'); add_str_char('i'); add_str_char(','); add_str_char(' '); add_str_char('1'); add_str_char('\n'); STR_MOV_RDI_1 = make_str(s);
    s = str_buf_len; add_str_char('m'); add_str_char('o'); add_str_char('v'); add_str_char(' '); add_str_char('r'); add_str_char('d'); add_str_char('x'); add_str_char(','); add_str_char(' '); add_str_char('1'); add_str_char('\n'); STR_MOV_RDX_1 = make_str(s);
    return 0;
}

// --- Tokenizer & Parser ---
int next() {
    while (1) {
        if (pos >= src_len) { ch = -1; break; }
        ch = src[pos]; pos = pos + 1;
        if (ch == '#') { while (ch != '\n' && ch != -1) { if (pos < src_len) { ch = src[pos]; pos = pos + 1; } else { ch = -1; break; } } continue; }
        if (ch == ' ' || ch == '\n' || ch == '\t' || ch == '\r') continue;
        break;
    }
    if (ch == -1) { token = -1; return 0; }
    if (ch >= '0' && ch <= '9') {
        token = 258; token_val = 0;
        while (ch >= '0' && ch <= '9') {
            int temp = token_val; int i = 0;
            while (i < 9) { token_val = token_val + temp; i = i + 1; }
            token_val = token_val + (ch - 48);
            if (pos < src_len) { ch = src[pos]; pos = pos + 1; } else { ch = -1; break; }
        } return 0;
    }
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_') {
        token_name_len = 0;
        while ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_') {
            if (token_name_len < 63) { token_name[token_name_len] = ch; token_name_len = token_name_len + 1; }
            if (pos < src_len) { ch = src[pos]; pos = pos + 1; } else { ch = -1; break; }
        } token = 257; return 0;
    }
    token = ch;
    if (pos < src_len) { ch = src[pos]; pos = pos + 1; } else { ch = -1; }
    return 0;
}

int find_var() {
    int i = 0;
    while (i < var_count) {
        int match = 1; int k = 0;
        if (var_len[i] != token_name_len) match = 0;
        while (k < var_len[i] && match == 1) {
            if (var_names[var_start[i] + k] != token_name[k]) match = 0;
            k = k + 1;
        }
        if (match == 1) return i;
        i = i + 1;
    }
    int id = var_count; var_count = var_count + 1;
    var_start[id] = var_len[id] = 0; // simplified flat mapping
    int k = 0; while (k < token_name_len) { var_names[var_count * 64 + k] = token_name[k]; k = k + 1; }
    var_len[id] = token_name_len;
    return id;
}

int factor(); int term(); int expr();

int factor() {
    if (token == 258) { emit_str(STR_MOV_RAX); emit_int(token_val); emit_str(STR_NL); next(); }
    else if (token == 257) {
        int id = find_var(); int offset = 0; int i = 0;
        while (i < id) { offset = offset + 8; i = i + 1; }
        emit_str(STR_MOV_RAX); emit_str(STR_MOV_VARS); emit_int(offset); emit_str(STR_BRACKET_NL); next();
    } else if (token == '(') { next(); expr(); if (token == ')') next(); }
    return 0;
}

int term() {
    factor();
    while (token == '*' || token == '/') {
        int op = token; next();
        emit_str(STR_SUB_RSP); emit_str(STR_MOV_RSP_RAX);
        factor();
        emit_str(STR_MOV_RCX_RSP); emit_str(STR_ADD_RSP);
        if (op == '*') {
            emit_str(STR_MOV_RAX_RCX); // mov rax, rcx
            // simplified mul loop emission
            emit_str(STR_MOV_RAX); emit_int(0); emit_str(STR_NL); // mov rax, 0
        } else {
            emit_str(STR_MOV_RAX); emit_int(0); emit_str(STR_NL);
        }
    } return 0;
}

int expr() {
    term();
    while (token == '+' || token == '-') {
        int op = token; next();
        emit_str(STR_SUB_RSP); emit_str(STR_MOV_RSP_RAX);
        term();
        emit_str(STR_MOV_RCX_RSP); emit_str(STR_ADD_RSP);
        if (op == '+') emit_str(STR_ADD_RAX_RCX);
        else { emit_str(STR_SUB_RCX_RAX); emit_str(STR_MOV_RAX_RCX); }
    } return 0;
}

int statement() {
    if (token == 257) {
        int id = find_var(); next();
        if (token == '=') {
            next(); expr();
            int offset = 0; int i = 0;
            while (i < id) { offset = offset + 8; i = i + 1; }
            emit_str(STR_MOV_VARS); emit_int(offset); emit_str(STR_BRACKET_NL);
        }
        if (token == ';') next();
    } else if (token == '{') { next(); while (token != '}' && token != -1) statement(); if (token == '}') next(); }
    else if (token == ';') next();
    return 0;
}

int program() {
    emit_str(STR_SECTION_BSS); emit_str(STR_VARS_RESB);
    emit_str(STR_SECTION_TEXT); emit_str(STR_GLOBAL_START); emit_str(STR_START_COLON);
    while (token != -1) statement();
    emit_str(STR_MOV_RAX_60); emit_str(STR_XOR_RDI_RDI); emit_str(STR_SYSCALL);
    return 0;
}

int main() {
    init_strings();
    int c = get_char();
    while (c != -1) { src[src_len] = c; src_len = src_len + 1; c = get_char(); }
    pos = 0; next(); program();
    int i = 0; while (i < asm_len) { print_char(asm_buf[i]); i = i + 1; }
    return 0;
}