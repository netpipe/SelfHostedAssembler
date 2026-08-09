// bootstrap.c
#include <stdio.h>

// Implementations for the subset compiler's built-ins
int get_char() { return getchar(); }
int print_char(int c) { putchar(c); return 0; }

// Include the self-compiling compiler
#include "compiler.c"