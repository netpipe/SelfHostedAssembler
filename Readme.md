This single-file program reads its own source code (`mini_asm.asm`), parses the instructions and labels, calculates x86-64 machine code, generates a valid ELF64 executable header, and writes the final binary (`a.out`).

[simpleC++ compiler](https://github.com/netpipe/simpleC-/tree/main) is designed to make assembly for this using --minimal flag

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


Writing a parser in raw x86-64 assembly while handling string logic and memory is extremely verbose. The most practical approach for a "C compiler for this assembler" is a lightweight compiler written in C that generates the exact, strictly-compliant assembly output required by your self-hosting assembler.

### Strict Subset Compliance
The generated assembly strictly adheres to the supported subset defined in `selfHosted.asm`:
- **Allowed**: `mov, add, sub, cmp, xor, jmp, je, jne, jl, jg, call, ret, syscall, db`.
- **Avoided**: `push`, `pop`, `lea`, `test`, `imul`, and `idiv`.
- **No `push/pop`**: Instead of pushing to the stack for evaluation, the compiler uses `sub rsp, 8` and `mov [rsp], rax` to evaluate expressions without relying on restricted instructions.
- **No `imul/idiv`**: Multiplication and division are implemented via repeated addition/subtraction loops to stay strictly within the instruction subset.
- **Static Memory**: Local variables are stored in a fixed `.bss` array (`vars`) to avoid complex stack pointer arithmetic for variable addressing.

### How It Works
1. **Memory Strategy**: The compiler defines a 256-byte `.bss` section named `vars`. Local variables map directly to offsets inside `vars`. This prevents the need for `push`/`pop` or complex dynamic stack frames (which aren't well-supported in the strict subset).
2. **Strict Arithmetic**: It parses `+`, `-`, `*`, and `/`. Multiplication and Division do not use `imul`/`idiv` (which are forbidden in the subset). Instead, it emits tight x86-64 assembly loops using `add`, `sub`, and `cmp` to compute the result.
3. **No Standard Library**: The `print(expr)` function maps to a custom `print_int` block written entirely in the assembly subset that invokes `syscall` (`rax=1` for `sys_write`) to write directly to standard output (`rdi=1`).
4. **Recursive Descent**: Operator precedence is correctly handled by splitting parsing into `expr()` (+, -), `term()` (*, /), and `factor()` (numbers, variables, parentheses).


