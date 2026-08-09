This single-file program reads its own source code (`mini_asm.asm`), parses the instructions and labels, calculates x86-64 machine code, generates a valid ELF64 executable header, and writes the final binary (`a.out`).

### Bootstrapping Instructions
1.  **Compile with NASM:** `nasm -f elf64 mini_asm.asm -o mini_asm.o`
2.  **Link:** `ld -o mini_asm mini_asm.o`
3.  **Run:** `./mini_asm`
    *   This will read `mini_asm.asm` and output `a.out`.
    *   You can run `./a.out` and it will assemble itself again, proving it is self-hosting.<br>


Here is the fully self-contained, self-hosting version of the assembler. It includes its own internal opcode-to-binary lookup table, parses labels and instructions independently, and performs a standard two-pass assembly (calculating sizes and label addresses in pass 1, then generating the final x86-64 machine code in pass 2).
Once you compile this for the first time using an external assembler like nasm or fasm, the resulting binary (a.out) will be completely standalone and capable of compiling its own source code (selfHosted.asm), effectively replacing your external assembler.


selfContained.asm
   nasm -f elf64 selfHosted.asm -o selfHosted.o
   ld -o selfHosted selfHosted.o