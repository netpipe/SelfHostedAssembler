#!/usr/bin/env python3
"""selfhost_scan.py -- can mini-asm assemble the given .asm source?

Scans a NASM-subset source line by line and reports every construct that is
outside the assembler's own accepted subset, so the whole gap is visible at
once instead of one 'unknown mnemonic' abort at a time.

    python3 tools/selfhost_scan.py fixed/selfContained.asm

Exit status is 0 when the file is already self-hostable, 1 otherwise.
"""
import re
import sys
import collections

# --- what fixed/selfContained.asm actually implements ------------------------
MNEMONICS = set("""
mov add or and sub xor cmp shl shr sar
jmp je jz jne jnz jl jle jg jge jb jbe ja jae js jns
call ret syscall db
""".split())

DIRECTIVES = set("""
section global extern align bits org equ
resb resw resd resq db dw dd dq times
""".split())

REGS64 = set("rax rcx rdx rbx rsp rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15".split())
REGS8 = set("al cl dl bl".split())
REGS = REGS64 | REGS8

# 32-bit names have no encoding in the minimal target
REGS32 = set("eax ecx edx ebx esp ebp esi edi".split())
REGS16 = set("ax cx dx bx sp bp si di".split())
REGS8X = set("sil dil spl bpl r8b r9b r10b r11b r12b r13b r14b r15b ah bh ch dh".split())

SIZE_KW = {"byte", "word", "dword", "qword"}


def strip_comment(line):
    out, in_str, quote = [], False, ""
    i = 0
    while i < len(line):
        ch = line[i]
        if in_str:
            out.append(ch)
            if ch == quote:
                in_str = False
        elif ch in "'\"":
            in_str, quote = True, ch
            out.append(ch)
        elif ch == ";":
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).rstrip()


def collect_labels(path):
    """Names defined in this file. A label may legally be spelled like a
    register (`ch:`, `si:`), and there it is a symbol, not a register."""
    labels = set()
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = strip_comment(raw).strip()
        m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:", line)
        if m:
            labels.add(m.group(1).lower())
            continue
        m = re.match(r"^([A-Za-z_.$][\w.$]*)\s+(equ|db|dw|dd|dq|res[bwdq])\b", line, re.I)
        if m:
            labels.add(m.group(1).lower())
    return labels


def classify_mem(inner, labels):
    """Return (ok, reason) for one [...] operand."""
    inner = inner.strip()
    toks = [t.strip() for t in re.split(r"([+\-*])", inner) if t.strip()]
    if "*" in toks:
        return False, "scaled index (SIB)"
    terms = [t for t in toks if t not in "+-"]
    regs = [t for t in terms if t.lower() in REGS and t.lower() not in labels]
    if len(regs) >= 2:
        return False, "base+index (SIB)"
    bad = [t for t in terms
           if t.lower() in REGS32 | REGS16 | REGS8X and t.lower() not in labels]
    if bad:
        return False, "sub-64-bit base register %s" % bad[0]
    if len(terms) > 2:
        return False, "more than base+disp"
    return True, ""


def scan(path):
    problems = collections.defaultdict(list)
    labels = collect_labels(path)
    for no, raw in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        line = strip_comment(raw)
        if not line.strip():
            continue
        s = line.strip()

        # a label on its own, or a label followed by something
        m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$", s)
        if m:
            s = m.group(2).strip()
            if not s:
                continue

        head = s.split(None, 1)
        word = head[0].lower()
        rest = head[1] if len(head) > 1 else ""

        # `name equ 5`, `name db 1,2` -- the directive is the second word
        if len(head) > 1:
            second = rest.split(None, 1)[0].lower()
            if second in DIRECTIVES and word not in MNEMONICS and word not in DIRECTIVES:
                word, rest = second, rest.split(None, 1)[1] if len(rest.split(None, 1)) > 1 else ""

        if word in DIRECTIVES:
            continue
        if word.startswith("%"):
            problems["preprocessor directive (%s)" % word].append((no, s))
            continue
        if word not in MNEMONICS:
            problems["unsupported mnemonic: %s" % word].append((no, s))
            continue

        # operands
        depth, cur, ops = 0, "", []
        for ch in rest:
            if ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
            if ch == "," and depth == 0:
                ops.append(cur.strip())
                cur = ""
            else:
                cur += ch
        if cur.strip():
            ops.append(cur.strip())

        for op in ops:
            body = op
            for kw in SIZE_KW:
                body = re.sub(r"^%s\s+" % kw, "", body, flags=re.I)
            body = body.strip()
            mm = re.match(r"^\[(.*)\]$", body)
            if mm:
                ok, why = classify_mem(mm.group(1), labels)
                if not ok:
                    problems["memory operand: %s" % why].append((no, s))
            elif body.lower() in REGS32 | REGS16 | REGS8X and body.lower() not in labels:
                problems["unsupported register: %s" % body.lower()].append((no, s))

    return problems


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    problems = scan(path)
    total = sum(len(v) for v in problems.values())
    print("self-host scan: %s" % path)
    print("-" * 70)
    if not total:
        print("no blockers -- this source is inside the assembler's own subset.")
        return 0
    for why in sorted(problems, key=lambda k: -len(problems[k])):
        hits = problems[why]
        print("%4d  %s" % (len(hits), why))
        for no, text in hits[:3]:
            print("        line %-5d %s" % (no, text))
        if len(hits) > 3:
            print("        ... and %d more" % (len(hits) - 3))
    print("-" * 70)
    print("%d site(s) to rewrite before this source can assemble itself." % total)
    return 1


if __name__ == "__main__":
    sys.exit(main())
