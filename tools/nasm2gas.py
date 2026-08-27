#!/usr/bin/env python3
"""nasm2gas.py - translate the NASM subset used by SelfHostedAssembler into
GNU-as Intel syntax, so the assemblers can be built and run on a box that has
binutils but no NASM.

    python3 tools/nasm2gas.py selfContained.asm > selfContained.s
    as --64 -o selfContained.o selfContained.s && ld -o selfContained selfContained.o

It is deliberately faithful: it does not "fix" anything, so a bug in the .asm
stays a bug in the binary.
"""
import re
import sys

LONG_JUMPS = False

SIZE_KW = ("byte", "word", "dword", "qword")


def split_comment(line):
    """Strip a ';' comment, respecting '...' and "..." literals."""
    out, i, n = [], 0, len(line)
    while i < n:
        c = line[i]
        if c in "'\"":
            q = c
            out.append(c)
            i += 1
            while i < n:
                out.append(line[i])
                if line[i] == q:
                    i += 1
                    break
                i += 1
            continue
        if c == ';':
            break
        out.append(c)
        i += 1
    return "".join(out).rstrip()


def char_consts(s):
    """NASM 'abc' -> the little-endian packed integer it denotes."""
    def rep(m):
        body = m.group(1)
        v = 0
        for k, ch in enumerate(body):
            v |= ord(ch) << (8 * k)
        return str(v)
    return re.sub(r"'([^']*)'", rep, s)


def add_ptr(s):
    """`byte [x]` -> `byte ptr [x]` (GAS Intel syntax needs the PTR)."""
    for kw in SIZE_KW:
        s = re.sub(r"\b%s\s+\[" % kw, "%s ptr [" % kw, s)
    return s


def data_bytes(directive, rest):
    """db/dw/dd/dq -> .byte/.word/.long/.quad, splitting out string pieces."""
    gas = {"db": ".byte", "dw": ".word", "dd": ".long", "dq": ".quad"}[directive]
    # split on commas that are outside quotes
    items, cur, i, n = [], "", 0, len(rest)
    while i < n:
        c = rest[i]
        if c in "'\"":
            q = c
            cur += c
            i += 1
            while i < n:
                cur += rest[i]
                if rest[i] == q:
                    i += 1
                    break
                i += 1
            continue
        if c == ',':
            items.append(cur.strip())
            cur = ""
            i += 1
            continue
        cur += c
        i += 1
    if cur.strip():
        items.append(cur.strip())

    out, pending = [], []
    for it in items:
        if directive == "db" and len(it) >= 2 and it[0] == '"' and it[-1] == '"':
            if pending:
                out.append("    %s %s" % (gas, ", ".join(pending)))
                pending = []
            out.append('    .ascii %s' % it)
        else:
            pending.append(char_consts(it))
    if pending:
        out.append("    %s %s" % (gas, ", ".join(pending)))
    return out


def main(path):
    raw = [split_comment(l) for l in open(path).read().splitlines()]

    # ---- pass 1: which global label owns each line (for `.local` mangling),
    #      and the set of section-relative symbols (labels + data + .bss) ----
    owner, cur, syms = [], "top", set()
    for line in raw:
        m = re.match(r"^([A-Za-z_][\w]*)\s*:", line)
        if m:
            cur = m.group(1)
            syms.add(cur)
        owner.append(cur)
        s = line.strip()
        m = re.match(r"^\.([A-Za-z_][\w]*)\s*:", s)
        if m:
            syms.add("%s__%s" % (cur, m.group(1)))
        m = re.match(r"^([A-Za-z_][\w]*)\s+(?:db|dw|dd|dq|res[bwdq])\b", s, re.I)
        if m:
            syms.add(m.group(1))

    out = ["    .intel_syntax noprefix"]
    section = "text"
    for idx, line in enumerate(raw):
        s = line.strip()
        if not s:
            continue

        low = s.lower()

        if low.startswith("global "):
            out.append("    .globl " + s.split(None, 1)[1])
            continue
        if low in ("section .data", "section .text", "section .bss"):
            section = low.split(".")[1]
            out.append("    ." + section)
            continue
        if low.startswith("align "):
            out.append("    .balign " + s.split()[1])
            continue

        # everything below can carry labels: mangle NASM local labels now.
        # foo.bar -> foo__bar, then a leading .bar -> <owning global>__bar.
        # Quoted text is stashed first so "selfHosted.asm" survives untouched.
        lits = []

        def stash(m):
            lits.append(m.group(0))
            return "\x00%d\x00" % (len(lits) - 1)

        s = re.sub(r"'[^']*'|\"[^\"]*\"", stash, s)
        s = re.sub(r"\b([A-Za-z_][\w]*)\.([A-Za-z_][\w]*)", r"\1__\2", s)
        s = re.sub(r"(^|[\s,\[])\.([A-Za-z_][\w]*)",
                   lambda m: "%s%s__%s" % (m.group(1), owner[idx], m.group(2)), s)
        s = re.sub(r"\x00(\d+)\x00", lambda m: lits[int(m.group(1))], s)

        # NAME equ VALUE
        m = re.match(r"^([A-Za-z_][\w]*)\s+equ\s+(.+)$", s, re.I)
        if m:
            out.append("    .equ %s, %s" % (m.group(1), char_consts(m.group(2))))
            continue

        # NAME resb/resw/resd/resq N   (.bss reservations)
        m = re.match(r"^([A-Za-z_][\w]*)\s+res([bwdq])\s+(\d+)$", s, re.I)
        if m:
            mult = {"b": 1, "w": 2, "d": 4, "q": 8}[m.group(2).lower()]
            out.append("%s: .zero %d" % (m.group(1), int(m.group(3)) * mult))
            continue

        # [NAME] db ... / dw ... / dd ... / dq ...
        m = re.match(r"^(?:([A-Za-z_][\w]*)\s+)?(db|dw|dd|dq)\s+(.+)$", s, re.I)
        if m and m.group(2).lower() in ("db", "dw", "dd", "dq"):
            if m.group(1):
                out.append("%s:" % m.group(1))
            out.extend(data_bytes(m.group(2).lower(), m.group(3)))
            continue

        # a label, optionally with an instruction on the same line
        m = re.match(r"^([A-Za-z_][\w]*)\s*:\s*(.*)$", s)
        if m:
            out.append("%s:" % m.group(1))
            s = m.group(2).strip()
            if not s:
                continue

        # ordinary instruction
        s = add_ptr(char_consts(s))
        # mini-asm always encodes branches as rel32. GAS relaxes short ones to
        # rel8, which is equally correct but produces different bytes, so the
        # golden comparison asks GAS for the long form explicitly.
        if LONG_JUMPS:
            s = re.sub(r"^(jmp|je|jne|jl|jg|jle|jge|jz|jnz)\s+",
                       r"\1.d32 ", s, flags=re.I)
        # NASM `mov rdi, in_path` means the ADDRESS; GAS Intel syntax reads a
        # bare symbol as memory contents, so an explicit `offset` is required.
        # Branch targets and anything already inside [] must be left alone.
        mnem = s.split()[0].lower()
        if not (mnem.startswith("j") or mnem in ("call", "lea")):
            def deref(txt):
                return re.sub(
                    r"\b([A-Za-z_][\w]*)\b",
                    lambda m: ("offset " + m.group(1)) if m.group(1) in syms else m.group(1),
                    txt)
            s = "".join(seg if seg.startswith("[") else deref(seg)
                        for seg in re.split(r"(\[[^\]]*\])", s))
        out.append("    " + s)

    return "\n".join(out) + "\n"


if __name__ == "__main__":
    argv = [a for a in sys.argv[1:] if a != "--long-jumps"]
    LONG_JUMPS = "--long-jumps" in sys.argv
    sys.stdout.write(main(argv[0]))
