# Pascal/Delphi Compiler Parser

This project is a syntax and semantic analyzer for a Pascal/Delphi-like programming language. It is built using Lex (Flex) for lexical analysis and Yacc (Bison) for syntax parsing and semantic validation.

The parser checks for correct grammar structure, manages variable scopes (global and local), and performs strict type checking for assignments, function parameters, and array indexing.

## Prerequisites

To build and run this project, you need the following tools installed on your system:

- gcc or cc
- flex
- bison or yacc
- make

## Build Instructions

Compile the parser using the provided Makefile:

```bash
make
```

This will generate an executable named parser.

## Running the Parser

You can run the parser by feeding it a source code file via standard input:

```bash
./parser < testcase/tricky.del
```

Or use the Makefile shortcut to run the default test case:

```bash
make run
```

## Automated Testing

The project includes an automated verification script. It parses all .del files in the testcase/ directory. Files prefixed with err_ are expected to fail (testing the error handling), while all other files should pass successfully.

Run the verification suite:

```bash
make verify
```

## Clean Up

To remove all generated files and executables, run:

```bash
make clean
```

# Changelog

- remove real, array type variable, and read statement.
- string is restricted to constant and string literal.