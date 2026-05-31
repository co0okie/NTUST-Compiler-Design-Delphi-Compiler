# Pascal/Delphi Compiler (Java Bytecode Generator)

This project is a syntax and semantic analyzer, as well as a code generator, for a Pascal/Delphi-like programming language. It is built using Lex (Flex) for lexical analysis and Yacc (Bison) for syntax parsing, semantic validation, and Java assembly code generation.

The compiler checks for correct grammar structure, manages variable scopes (global and local), performs strict type checking, and successfully translates the source code into Java Assembly (`.jasm`), which can be executed on the Java Virtual Machine (JVM).

## Prerequisites

To build and run this project, you need the following tools installed on your system:

- **gcc** or **cc**: C compiler
- **flex**: Lexical analyzer generator
- **bison** or **yacc**: Parser generator
- **make**: Build automation tool
- **javaa**: Java Bytecode Assembler (to convert `.jasm` into `.class`)
- **java**: Java Runtime Environment (JRE, to run the `.class` files)

## Build Instructions

Compile the parser using the provided Makefile:

```bash
make
```

This will generate an executable named `parser`.

## Running the Compiler

The compilation and execution process involves multiple steps, which are simplified by the Makefile. You can configure the target testcase inside the Makefile before running these commands.

**1. Generate Java Assembly (.jasm)**
Parse the source `.del` code and generate the Java assembly file:

```bash
./parser < testcase/example.del > testcase/example.jasm
```
or simply

```bash
make jasm
```

**2. Assemble to Java Bytecode (.class)**
Use the `javaa` assembler to convert the `.jasm` file into an executable `.class` file:

```bash
cd testcase
javaa example.jasm
```

or simply

```bash
make class
```

**3. Run the Program**
Execute the compiled Java bytecode on the JVM:

```bash
java -cp testcase example
```

or simply

```bash
make run
```

*(Note: You can simply use `make run`, and the Makefile will automatically handle the dependencies to generate the `.jasm` and `.class` files if they are missing or outdated.)*

## Automated Testing

The project includes an automated verification script. It parses all `.del` files in the `testcase/` directory. Files prefixed with `err_` are expected to fail (testing the semantic error handling), while all other files should pass successfully.

Run the verification suite:

```bash
make verify
```

## Clean Up

To remove all generated source files, executables, and Java bytecode files, run:

```bash
make clean
```

# Changelog

### Code Generation & AST (New Features)

* **Abstract Syntax Tree (AST) Implementation**: Built a complete AST specifically for expressions (`expr`). The AST nodes efficiently manage constants (int, bool, string), variable references (local and global), function invocations, and unary/binary operations, decoupling the parsing phase from the code generation phase.
* **Java Bytecode Generation**: Integrated `.jasm` generation capabilities. The compiler now translates the constructed AST and control flow statements directly into JVM stack-based instructions (e.g., `iload`, `sipush`, `iadd`, `ifeq`, `goto`, `invokestatic`).
* **Control Flow Optimization**: Handled shift/reduce conflicts (e.g., the dangling-else problem) elegantly by introducing prefix rules (`if_prefix`) and delaying label generation/jump instruction execution.

### Symbol Table & Scope Management

* **Variable Attributes**: The symbol table now records whether a variable is `global` or `local` and tracks its `is_initialized` status.
* **JVM Local Variable Indexing**: Local variables are now assigned a `local_var_index` compatible with JVM (`iload`/`istore`).
* **Advanced Scope Tracking**: The scope manager now accurately maintains the `local_var_index`. The index counter resets to `0` when entering a `program`, `function`, or `procedure` scope, but correctly inherits the counter from the parent scope when entering an anonymous `block` (begin-end).
* **Return Type Enforcement**: Subprogram scopes now track the `expected_return_type` to ensure accurate validation of `return` statements deeply nested within blocks.

### Language Restrictions & Removals

* **Removed Features**: Completely removed support for the `real` (floating-point) type, `array` type variables, and `read` statements to streamline the code generation process.
* **String Restrictions**: The `string` type is now heavily restricted. String variables cannot be modified or assigned. Strings are only allowed as constant declarations and string literals for `write`/`writeln` statements. Passing strings as function parameters or returning strings from functions is strictly prohibited.