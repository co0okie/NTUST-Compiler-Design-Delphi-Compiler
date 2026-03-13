%{
#include <stdio.h>
#include <stdlib.h>

#define ID_LENGTH 64
// fixed hash table size for simplicity
#define TABLE_SIZE 1024
// string length for string literals
#define BUF_SIZE 16384
#define LIST strcat(buf, yytext)
#define token(t) { LIST; printf("<%s>\n", #t); }
#define tokenString(t, s) { LIST; printf("<%s: %s>\n", #t, s); }

char buf[BUF_SIZE];

typedef struct _Entry {
    char name[ID_LENGTH];
    struct _Entry *next;
} Entry;

// similar to c++ unordered_set<Entry>
// use chaining for collision resolution
Entry* symbolTable[TABLE_SIZE];

// simple hash function for strings
unsigned long hash_djb2(const char *str) {
    unsigned long hash = 5381;
    int c;
    while ((c = *str++)) hash = ((hash << 5) + hash) + c; 
    return hash;
}

// not use in this assignment, but useful for future semantic analysis
Entry* lookup(Entry* table[TABLE_SIZE], char* name) {
    unsigned long hashValue = hash_djb2(name) % TABLE_SIZE;
    for (Entry* current = table[hashValue]; current; current = current->next) {
        if (strcmp(current->name, name) == 0) return current;
    }
    return NULL;
}

void insert(Entry* table[TABLE_SIZE], char* name) {
    if (strlen(name) >= ID_LENGTH) {
        fprintf(stderr, "Identifier too long: %s\n", name);
        fprintf(stderr, "Please modify ID_LENGTH to larger value.\n");
        exit(-1);
    }
    unsigned long hashValue = hash_djb2(name) % TABLE_SIZE;
    for (Entry* current = table[hashValue]; current; current = current->next) {
        // avoid inserting duplicate identifiers
        if (strcmp(current->name, name) == 0) return;
    }
    Entry* newEntry = (Entry*) malloc(sizeof(Entry));
    strncpy(newEntry->name, name, ID_LENGTH);
    newEntry->next = table[hashValue];
    table[hashValue] = newEntry;
}

void dump(Entry* table[TABLE_SIZE]) {
    printf("Symbol Table:\n");
    for (int i = 0; i < TABLE_SIZE; i++) {
        Entry* entry = table[i];
        while (entry) {
            printf("%s\n", entry->name);
            entry = entry->next;
        }
    }
}
%}

%option yylineno

%%

\n {
    LIST;
    printf("%d: %s", yylineno - 1, buf);
    buf[0] = '\0';
}
[ \t]* { LIST; }
\/\/.* { LIST; }
// multi-line comments
\(\*([^*]|\*+[^)*])*\*+\) { LIST; }
,               token(COMMA)
:               token(COLON)
\.              token(PERIOD)
;               token(SEMICOLON)
\(              token(LPAREN)
\)              token(RPAREN)
\[              token(LBRACKET)
\]              token(RBRACKET)
\{              token(LBRACE)
\}              token(RBRACE)
\+              token(PLUS)
\-              token(MINUS)
\*              token(MULTIPLY)
\/              token(DIVIDE)
// case insensitive
(?i:mod)        token(REMAINDER)
\<              token(LT)
\<=             token(LE)
\>              token(GT)
\>=             token(GE)
=               token(EQ)
\<\>            token(NE)
(?i:and)        token(AND)
(?i:or)         token(OR)
(?i:not)        token(NOT)
:=              token(ASSIGN)
(?i:array)      token(ARRAY)
(?i:boolean)    token(BOOLEAN)
(?i:begin)      token(BEGIN)
(?i:case)       token(CASE)
(?i:const)      token(CONST)
(?i:continue)   token(CONTINUE)
(?i:do)         token(DO)
(?i:downto)     token(DOWNTO)
(?i:else)       token(ELSE)
(?i:end)        token(END)
(?i:exit)       token(EXIT)
(?i:for)        token(FOR)
(?i:function)   token(FUNCTION)
(?i:goto)       token(GOTO)
(?i:if)         token(IF)
(?i:in)         token(IN)
(?i:integer)    token(INTEGER)
(?i:loop)       token(LOOP)
(?i:of)         token(OF)
(?i:procedure)  token(PROCEDURE)
(?i:program)    token(PROGRAM)
(?i:repeat)     token(REPEAT)
(?i:return)     token(RETURN)
(?i:real)       token(REAL)
(?i:string)     token(STRING)
(?i:then)       token(THEN)
(?i:to)         token(TO)
(?i:type)       token(TYPE)
(?i:until)      token(UNTIL)
(?i:var)        token(VAR)
(?i:while)      token(WHILE)
(?i:write)      token(WRITE)
(?i:writeln)    token(WRITELN)
(?i:true)       token(TRUE)
(?i:false)      token(FALSE)
[a-zA-Z][a-zA-Z0-9]* {
    tokenString(IDENTIFIER, yytext);
    insert(symbolTable, yytext);
}
// e.g. 1.23, .5, 1e-10, 2.5E+6, -.5e-3
[+-]?[0-9]*\.[0-9]+([eE][+-]?[0-9]+)?   tokenString(REAL, yytext)
[0-9]+          tokenString(INTEGER, yytext)
// e.g. "hello ""world""" -> hello "world"
\"(\"\"|[^\"])*\" {
    // extract the exact string content
    char str[BUF_SIZE];
    int j = 0;
    for (int i = 1; i < yyleng - 1; i++) {
        if (yytext[i] == '"' && yytext[i + 1] == '"') {
            str[j++] = '"';
            i++;
        } else {
            str[j++] = yytext[i];
        }
    }
    str[j] = '\0';
    tokenString(STRING, str);
}
. {
    LIST;
    printf("%d: %s\n", yylineno - 1, buf);
    printf("bad character: '%s'\n", yytext);
    exit(-1);
}
%%
int main(int argc, char **argv) {
    for (int i = 0; i < TABLE_SIZE; i++) {
        symbolTable[i] = NULL;
    }

    yylex();

    // print the last line if the file doesn't end with a newline
    if (buf[0] != '\0') printf("%d: %s\n", yylineno, buf);

    printf("\n");
    dump(symbolTable);

    // free symbol table memory
    for (int i = 0; i < TABLE_SIZE; i++) {
        Entry* entry = symbolTable[i];
        while (entry) {
            Entry* temp = entry;
            entry = entry->next;
            free(temp);
        }
    }
    
    return 0;
}