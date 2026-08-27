#!/bin/sh
# End-to-end: C source -> nano_cc -> mini-asm -> running binary, with no gcc and
# no binutils anywhere in the path.
#
#   sh tests/bootstrap.sh <build-dir> <path-to-nano_cc-repo>
#
# For each demo, the reference output is produced the normal way (nano_cc, then
# gcc to assemble and link) and compared against the binary mini-asm produced
# from `nano_cc --minimal --nasm`. Both must print the same thing and exit the
# same way.

set -u
BUILD=$1
NANO=$2
ASM=$BUILD/fixed
FAIL=0

if [ ! -x "$NANO/nano_cc" ]; then
    echo "SKIP bootstrap: no nano_cc at $NANO (pass NANOCC=/path/to/simpleCpp-build-fix)"
    exit 0
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$ASM" "$W/mini_asm"

for d in test features structs bitwise printf switch; do
    [ -f "$NANO/$d.c" ] || continue

    # reference: the ordinary toolchain
    ( cd "$NANO" && ./nano_cc "$d.c" "$W/ref.s" ) >/dev/null 2>&1 || { echo "FAIL $d: nano_cc"; FAIL=1; continue; }
    cc -nostdlib -no-pie "$W/ref.s" -o "$W/ref" 2>/dev/null || { echo "FAIL $d: reference link"; FAIL=1; continue; }
    REF=$( "$W/ref" 2>&1; echo "rc=$?" )

    # bootstrap: nano_cc --minimal --nasm, assembled by mini-asm alone
    ( cd "$NANO" && ./nano_cc --minimal --nasm "$d.c" "$W/selfHosted.asm" ) >/dev/null 2>&1 \
        || { echo "FAIL $d: nano_cc --minimal --nasm"; FAIL=1; continue; }
    rm -f "$W/a.out"
    ( cd "$W" && timeout 60 ./mini_asm ) 2>"$W/err"
    if [ $? -ne 0 ]; then
        echo "FAIL $d: mini-asm rejected the output: $(cat "$W/err")"
        FAIL=1
        continue
    fi
    chmod +x "$W/a.out"
    GOT=$( "$W/a.out" 2>&1; echo "rc=$?" )

    if [ "$REF" = "$GOT" ]; then
        echo "PASS $d: same output as the gcc-assembled build ($(wc -c < "$W/a.out") byte binary)"
    else
        echo "FAIL $d: bootstrap binary behaves differently"
        printf '%s\n' "--- reference ---" "$REF" "--- bootstrap ---" "$GOT"
        FAIL=1
    fi
done

exit $FAIL
