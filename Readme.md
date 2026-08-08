This single-file program reads its own source code (`mini_asm.asm`), parses the instructions and labels, calculates x86-64 machine code, generates a valid ELF64 executable header, and writes the final binary (`a.out`).

### Bootstrapping Instructions
1.  **Compile with NASM:** `nasm -f elf64 mini_asm.asm -o mini_asm.o`
2.  **Link:** `ld -o mini_asm mini_asm.o`
3.  **Run:** `./mini_asm`
    *   This will read `mini_asm.asm` and output `a.out`.
    *   You can run `./a.out` and it will assemble itself again, proving it is self-hosting.