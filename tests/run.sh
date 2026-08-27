#!/bin/sh
# Reproduces every claim in README.md section 1. No edits to upstream sources.
#
#   sh tests/run.sh <build-dir> <upstream-dir>

set -u
BUILD=$1
UP=$2
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$BUILD/selfContained" "$WORK/"

# The assembler hard-codes its input filename, so each case writes selfHosted.asm.
run_case() {
    desc=$1
    printf '\n=== %s ===\n' "$desc"
    lines=$(wc -l < "$WORK/selfHosted.asm")
    printf -- '--- input (%s lines) ---\n' "$lines"
    head -8 "$WORK/selfHosted.asm"
    [ "$lines" -gt 8 ] && echo "..."
    printf -- '--- result ---\n'
    ( cd "$WORK" && rm -f a.out && timeout 5 ./selfContained )
    rc=$?
    case $rc in
        0)   echo "exit 0" ;;
        1)   echo "exit 1 (error_exit)" ;;
        124) echo "exit 124 (TIMED OUT - infinite loop)" ;;
        139) echo "exit 139 (SEGFAULT)" ;;
        *)   echo "exit $rc" ;;
    esac
    if [ -f "$WORK/a.out" ]; then
        echo "a.out: $(wc -c < "$WORK/a.out") bytes"
    else
        echo "a.out: not produced"
    fi
}

printf '_start:\nmov rax, 60\nxor rdi, rdi\nsyscall\n' > "$WORK/selfHosted.asm"
run_case "1.1  simplest program in the documented subset"

printf 'foo:\ncall foo\n' > "$WORK/selfHosted.asm"
run_case "1.2  a four-letter mnemonic"

cp "$UP/selfHosted.asm" "$WORK/selfHosted.asm"
run_case "1.3  the assembler's own intended input"

printf '\n=== 1.4  toy C compiler on "x = 2 + 3 * 4; y = x - 1;" ===\n'
printf 'x = 2 + 3 * 4;\ny = x - 1;\n' | "$BUILD/cc_boot"

printf '\n=== 2.1b  is_register has no ret between .r0 and is_number ===\n'
objdump -d --no-show-raw-insn "$BUILD/selfContained.o" \
    | sed -n '/<is_register__r0>:/,/<is_number>:/p' | grep -c 'ret' \
    | sed 's/^/ret instructions found: /'

printf '\n=== 2.1a  the stray "db 0x48" executes as a REX prefix ===\n'
objdump -d --no-show-raw-insn "$BUILD/selfContained.o" \
    | sed -n '/<parse_alu>:/,/<parse_alu__skip_emit>:/p' | grep -A1 'call.*emit_byte' | head -4
