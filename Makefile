# Build harness for netpipe/SelfHostedAssembler using plain binutils (no NASM).
#
#   make fetch    # clone upstream into ./upstream
#   make          # build selfContained, selfHosted and the toy C compiler
#   make check    # run the reproductions from README.md
#   make clean

UP      ?= original
BUILD    = build
PY      ?= python3
AS      ?= as
LD      ?= ld
CC      ?= gcc

.PHONY: all fetch check clean

# selfHosted.asm does not currently link (it jumps to an undefined label,
# process_line.done_line), so its failure is reported rather than fatal.
all: $(BUILD)/selfContained $(BUILD)/cc_boot
	-@$(MAKE) --no-print-directory $(BUILD)/selfHosted

# Upstream HEAD now carries the M1 fix (netpipe applied it), so the audit in
# section 1 is run against the vendored pre-M1 sources in original/ instead.
fetch:
	@test -d upstream || git clone --depth 1 https://github.com/netpipe/SelfHostedAssembler.git upstream

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.s: $(UP)/%.asm tools/nasm2gas.py | $(BUILD)
	$(PY) tools/nasm2gas.py $< > $@

$(BUILD)/%.o: $(BUILD)/%.s
	$(AS) --64 -o $@ $<

$(BUILD)/selfContained: $(BUILD)/selfContained.o
	$(LD) -o $@ $<

$(BUILD)/selfHosted: $(BUILD)/selfHosted.o
	$(LD) -o $@ $<

# The toy C compiler needs a real C compiler; bootstrap.c supplies its I/O.
$(BUILD)/cc_boot: $(UP)/c-compiler/bootstrap.c $(UP)/c-compiler/compiler.c | $(BUILD)
	$(CC) -w -o $@ $<

check: all
	@sh tests/run.sh $(abspath $(BUILD)) $(abspath $(UP))

clean:
	rm -rf $(BUILD)

.PRECIOUS: $(BUILD)/%.s

# ---- M1: the corrected assembler in fixed/ ----------------------------------
.PHONY: m1 golden

$(BUILD)/fixed.s: fixed/selfContained.asm tools/nasm2gas.py | $(BUILD)
	$(PY) tools/nasm2gas.py $< > $@

$(BUILD)/fixed.o: $(BUILD)/fixed.s
	$(AS) --64 -o $@ $<

$(BUILD)/fixed: $(BUILD)/fixed.o
	$(LD) -o $@ $<

m1: $(BUILD)/fixed

golden: $(BUILD)/fixed
	@sh tests/golden.sh $(abspath $(BUILD))

# End-to-end: C -> nano_cc --minimal --nasm -> mini-asm -> running binary.
# Point NANOCC at a built clone of anirudhatalmale6-alt/simpleCpp-build-fix.
NANOCC ?= ../repo
.PHONY: bootstrap
bootstrap: $(BUILD)/fixed
	@sh tests/bootstrap.sh $(abspath $(BUILD)) $(abspath $(NANOCC))

# The whole loop: the compiler's OWN source, compiled by the compiler, assembled
# by this assembler, and the result made to do it again and come out identical.
# No gcc and no binutils anywhere in it.
.PHONY: selfhost
selfhost: $(BUILD)/fixed
	@sh tests/selfhost.sh $(abspath $(BUILD)) $(abspath $(NANOCC))

# ---- self-host readiness ----------------------------------------------------
# Lists every construct in a source that falls outside the assembler's own
# accepted subset, so the whole gap is visible at once rather than one
# "unknown mnemonic" abort at a time.
.PHONY: selfhost-scan
selfhost-scan:
	-@$(PY) tools/selfhost_scan.py fixed/selfContained.asm
