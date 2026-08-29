#!/bin/sh
# Golden tests for fixed/selfContained.asm.
#
# For each test program:
#   1. assemble it with the fixed mini-asm, producing a.out
#   2. assemble the SAME source with GNU as + ld, producing reference bytes
#   3. require the two byte streams to be identical
#   4. run the mini-asm binary and require the documented exit code
#
# Step 3 is the one that matters. An assembler that produces a running binary
# can still be encoding instructions wrongly in ways the test program happens
# not to exercise; comparing against binutils catches that.
#
#   sh tests/golden.sh <build-dir>

set -u
BUILD=$1
ASM=$BUILD/fixed
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0

# name:expected exit code
CASES="golden1:42 golden2:55 golden3:42 golden4:0 subset:42 golden5:42 golden6:42"

for c in $CASES; do
    name=${c%%:*}
    want=${c##*:}
    work=$(mktemp -d)
    cp "$ASM" "$work/mini_asm"
    cp "$ROOT/tests/$name.asm" "$work/selfHosted.asm"

    ( cd "$work" && timeout 10 ./mini_asm ) 2>"$work/err"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "FAIL $name: assembler exited $rc"
        cat "$work/err"
        FAIL=1
        rm -rf "$work"
        continue
    fi

    # reference bytes from binutils, with branches forced to rel32 so both
    # assemblers are making the same encoding choice
    python3 "$ROOT/tools/nasm2gas.py" --long-jumps "$ROOT/tests/$name.asm" > "$work/ref.s"
    as --64 -o "$work/ref.o" "$work/ref.s"
    ld -Ttext 0x400078 --oformat binary -o "$work/ref.bin" "$work/ref.o" 2>/dev/null

    if python3 - "$work" <<'PY'
import sys
w = sys.argv[1]
mini = open(w + "/a.out", "rb").read()[120:]
ref = open(w + "/ref.bin", "rb").read()
if mini == ref:
    print("  bytes: %d, identical to GNU as" % len(mini))
    sys.exit(0)
print("  mini-asm %d bytes, GNU as %d bytes" % (len(mini), len(ref)))
for i in range(min(len(mini), len(ref))):
    if mini[i] != ref[i]:
        print("  first difference at offset %d: %02x vs %02x" % (i, mini[i], ref[i]))
        print("  mini: " + mini[max(0, i-6):i+10].hex(" "))
        print("  gnu : " + ref[max(0, i-6):i+10].hex(" "))
        break
sys.exit(1)
PY
    then :; else
        echo "FAIL $name: encoding differs from GNU as"
        FAIL=1
        rm -rf "$work"
        continue
    fi

    chmod +x "$work/a.out"
    ( cd "$work" && ./a.out >/dev/null 2>&1 )
    got=$?
    if [ "$got" != "$want" ]; then
        echo "FAIL $name: program exited $got, expected $want"
        FAIL=1
    else
        echo "PASS $name: byte-identical to GNU as, runs, exits $got"
    fi
    rm -rf "$work"
done

# ---------------------------------------------------------------------------
# Reservations. Not byte-compared, and the reason is worth being explicit
# about: `ld` chooses where .bss goes and mini-asm puts it at a fixed address
# of its own, so the immediates differ for a reason that has nothing to do
# with encoding. What is checked instead is that the labels are defined, the
# memory is zero, writable and distinct, and that NOTHING WAS EMITTED for any
# of it -- the file has to stay small while p_memsz grows past it.
# ---------------------------------------------------------------------------
work=$(mktemp -d)
cp "$ASM" "$work/mini_asm"
cp "$ROOT/tests/bss.asm" "$work/selfHosted.asm"
( cd "$work" && rm -f a.out && timeout 10 ./mini_asm ) 2>"$work/err"
if [ ! -f "$work/a.out" ]; then
    echo "FAIL bss: assembler rejected it: $(cat "$work/err")"
    FAIL=1
else
    chmod +x "$work/a.out"
    "$work/a.out"
    rc=$?
    size=$(wc -c < "$work/a.out")
    memsz=$(readelf -lW "$work/a.out" 2>/dev/null | awk '/LOAD/{print strtonum($6)}')
    if [ "$rc" -ne 42 ]; then
        echo "FAIL bss: program exited $rc, wanted 42"
        FAIL=1
    elif [ "$size" -gt 2048 ]; then
        echo "FAIL bss: $size bytes on disk -- the reservations were emitted"
        FAIL=1
    elif [ "${memsz:-0}" -le "$size" ]; then
        echo "FAIL bss: p_memsz $memsz does not reach past p_filesz $size"
        FAIL=1
    else
        echo "PASS bss: $size bytes on disk, $memsz bytes of memory, exits 42"
    fi
fi
rm -rf "$work"

# The original assembler's failures, now expected to succeed.
work=$(mktemp -d)
cp "$ASM" "$work/mini_asm"
printf '_start:\nmov rax, 60\nxor rdi, rdi\nsyscall\n' > "$work/selfHosted.asm"
( cd "$work" && timeout 10 ./mini_asm ) 2>/dev/null
[ $? -eq 0 ] && echo "PASS regression: 'mov rax, 60' assembles (used to error)" \
             || { echo "FAIL regression: mov rax, 60"; FAIL=1; }

printf 'foo:\ncall foo\nret\n' > "$work/selfHosted.asm"
( cd "$work" && timeout 10 ./mini_asm ) 2>/dev/null
[ $? -eq 0 ] && echo "PASS regression: 'call foo' assembles (used to segfault)" \
             || { echo "FAIL regression: call foo"; FAIL=1; }

# sub/syscall/ret/shl/shr all start with a letter the original threw away.
printf '_start:\nsub rax, rax\nshl rax, 2\nshr rax, 1\nsyscall\nret\n' > "$work/selfHosted.asm"
( cd "$work" && rm -f a.out && timeout 10 ./mini_asm ) 2>/dev/null
if [ -f "$work/a.out" ] && [ "$(wc -c < "$work/a.out")" -gt 120 ]; then
    echo "PASS regression: s/r lines assemble (sub, shl, shr, syscall, ret)"
else
    echo "FAIL regression: lines starting with s/r are still being skipped"
    FAIL=1
fi

# a genuinely unknown mnemonic must still be reported, not silently dropped
printf '_start:\nsqrtps xmm0, xmm1\nret\n' > "$work/selfHosted.asm"
( cd "$work" && timeout 10 ./mini_asm ) 2>"$work/e"
if grep -q "unknown mnemonic" "$work/e"; then
    echo "PASS regression: an unknown mnemonic is reported, not skipped"
else
    echo "FAIL regression: unknown mnemonic was silently swallowed"
    FAIL=1
fi

# an error has to say WHICH LINE. "Error: " on its own is a fine report for a
# nine-line program and useless for a 39,000-line one.
printf '_start:\nmov rax, 60\nsqrtps xmm0, xmm1\nret\n' > "$work/selfHosted.asm"
( cd "$work" && timeout 10 ./mini_asm ) 2>"$work/e"
if grep -q "sqrtps" "$work/e"; then
    echo "PASS regression: the error names the offending line"
else
    echo "FAIL regression: the error does not say which line"
    FAIL=1
fi

# 8-bit register with an immediate is outside the subset. It used to assemble
# to something else without saying so: `mov al, 9` came out as `mov al, al`,
# and `cmp al, 9` as a 64-bit `cmp rax, 9`.
for prog in 'mov al, 9' 'cmp al, 9'; do
    printf '_start:\n    %s\n    ret\n' "$prog" > "$work/selfHosted.asm"
    ( cd "$work" && timeout 10 ./mini_asm ) 2>"$work/e"
    if grep -q "8-bit" "$work/e"; then
        echo "PASS regression: '$prog' is refused, not mis-encoded"
    else
        echo "FAIL regression: '$prog' did not report the unsupported form"
        FAIL=1
    fi
done
rm -rf "$work"

exit $FAIL
