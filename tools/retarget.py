#!/usr/bin/env python3
"""retarget.py — swap the OS block in the assembler for another one.

    python3 tools/retarget.py fixed/selfContained.asm fixed/target-nanoos.inc > out.asm

Everything the assembler needs from the operating system it RUNS on lives
between two marker lines in the source:

    ; ==== TARGET BEGIN ====
    ...
    ; ==== TARGET END ====

This replaces that region wholesale. The point is that there is one assembler
and several targets, rather than several assemblers: a second copy of a
1,900-line file drifts, and a divergence between two copies of an assembler
shows up as a miscompilation on one platform and not the other, which is close
to the worst shape a bug can have.

The replacement file carries its own markers, so the output can be retargeted
again -- and so a file that is missing them fails here rather than producing an
assembler with no entry point.
"""

import sys

BEGIN = "; ==== TARGET BEGIN ===="
END = "; ==== TARGET END ===="


def split_on_markers(text, what):
    lines = text.split("\n")
    try:
        i = lines.index(BEGIN)
        j = lines.index(END)
    except ValueError:
        sys.exit("retarget: %s has no %s / %s markers" % (what, BEGIN, END))
    if j < i:
        sys.exit("retarget: %s has END before BEGIN" % what)
    return lines[:i], lines[i:j + 1], lines[j + 1:]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, block = sys.argv[1], sys.argv[2]

    before, _, after = split_on_markers(open(src).read(), src)
    _, replacement, _ = split_on_markers(open(block).read(), block)

    sys.stdout.write("\n".join(before + replacement + after))


if __name__ == "__main__":
    main()
