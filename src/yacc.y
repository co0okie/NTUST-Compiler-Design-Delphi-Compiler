%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define Reduce(l, r) if (Opt_P) printf("%02d: %12s <= %s\n", yylineno, l, r)
#define Trace(t)  if (Opt_P) printf("%02d: %s\n", yylineno, t)
int Opt_P = 1;

extern int yylineno;
extern int yylex();
void yyerror(const char *msg);
int error_count = 0;

/*======================================================
 * Semantic Analysis: Symbol Table & Scope Management
 *======================================================*/
#define HASH_SIZE 211
#define MAX_ID_LEN 50
#define MAX_PARAMS 20

typedef enum { 
    TYPE_INT, 
    TYPE_REAL, 
    TYPE_BOOL, 
    TYPE_STR, 
    TYPE_VOID,    /* For procedure */
    TYPE_ARRAY,   /* For array variable */
    TYPE_UNKNOWN 
} DataType;

typedef struct _Entry {
    char name[MAX_ID_LEN];
    DataType type;           /* 變數、常數或函式回傳值的類型 */
    int is_const;            /* 0: var/func/proc, 1: const */
    int is_function;         /* 擴充：紀錄是否為 Function/Procedure */
    
    /* 陣列專屬資訊 */
    int array_start;
    int array_end;
    DataType element_type;   /* 陣列元素的類型 */
    
    /* 函式/程序專屬資訊 */
    int param_count;
    DataType param_types[MAX_PARAMS];
    
    struct _Entry *next;
    struct _Entry *next_in_scope; /* 擴充：紀錄宣告順序 */
} Entry;

typedef struct _Scope {
    Entry* table[HASH_SIZE];
    Entry* order_head;       /* 擴充：Scope 內第一個宣告的 Symbol */
    Entry* order_tail;       /* 擴充：Scope 內最後一個宣告的 Symbol */
    struct _Scope *next;
} Scope;

Scope* current_scope = NULL;

/* 優雅的字串串列：用來傳遞多個 ID 名稱與對應的型別 */
typedef struct _IdNode {
    char name[MAX_ID_LEN];
    DataType type;           /* 擴充：紀錄該節點的型別 (供參數傳遞使用) */
    struct _IdNode *next;
} IdNode;

IdNode* create_id_node(const char* name) {
    IdNode* node = (IdNode*)malloc(sizeof(IdNode));
    strncpy(node->name, name, MAX_ID_LEN - 1);
    node->name[MAX_ID_LEN - 1] = '\0';
    node->type = TYPE_UNKNOWN; 
    node->next = NULL;
    return node;
}

/* 參數型別收集器：用來將呼叫時傳入的參數型別打包比對 */
typedef struct _ParamList {
    int count;
    DataType types[MAX_PARAMS];
} ParamList;

ParamList* create_param_list() {
    ParamList* list = (ParamList*)malloc(sizeof(ParamList));
    list->count = 0;
    return list;
}

void add_param_type(ParamList* list, DataType type) {
    if (list->count < MAX_PARAMS) {
        list->types[list->count++] = type;
    }
}

/* 輔助函數：將 DataType 轉換為字串，方便報錯顯示 */
const char* type_to_string(DataType t) {
    switch(t) {
        case TYPE_INT: return "int";
        case TYPE_REAL: return "real";
        case TYPE_BOOL: return "boolean";
        case TYPE_STR: return "string";
        case TYPE_VOID: return "void";
        case TYPE_ARRAY: return "array";
        default: return "unknown";
    }
}

/* 輔助函數：比對傳入的參數是否與函式/程序的定義相符 */
void check_arguments(const char* func_name, Entry* sym, ParamList* args) {
    if (sym == NULL || args == NULL) return;
    
    if (sym->param_count != args->count) {
        char msg[256];
        sprintf(msg, "Semantic Error: '%s' expects %d arguments, but got %d.", func_name, sym->param_count, args->count);
        yyerror(msg);
        return;
    }
    
    for (int i = 0; i < sym->param_count; i++) {
        /* 如果傳入的參數本身就有語意錯誤 (TYPE_UNKNOWN)，就暫時不報型別不合的錯誤，避免錯誤洗版 */
        if (sym->param_types[i] != args->types[i] && args->types[i] != TYPE_UNKNOWN) {
            char msg[256];
            sprintf(msg, "Semantic Error: Argument %d of '%s' expects %s, but got %s.",
                    i + 1, func_name, type_to_string(sym->param_types[i]), type_to_string(args->types[i]));
            yyerror(msg);
        }
    }
}

unsigned long hash_djb2(const char *str) {
    unsigned long hash = 5381;
    int c;
    while ((c = *str++))
        hash = ((hash << 5) + hash) + c;
    return hash;
}

void push_scope() {
    Scope* new_scope = (Scope*)malloc(sizeof(Scope));
    for (int i = 0; i < HASH_SIZE; i++) {
        new_scope->table[i] = NULL;
    }
    new_scope->order_head = NULL;
    new_scope->order_tail = NULL;
    new_scope->next = current_scope;
    current_scope = new_scope;
    Trace("Scope Pushed");
}

void pop_scope() {
    if (current_scope == NULL) return;
    
    if (Opt_P) {
        printf("%02d: Scope Popped, Symbol Table:\n", yylineno);
        Entry* curr = current_scope->order_head;
        while (curr != NULL) {
            if (curr->type == TYPE_VOID) {
                printf("    %s: procedure(", curr->name);
                for(int p=0; p<curr->param_count; p++) {
                    printf("%s%s", type_to_string(curr->param_types[p]), p < curr->param_count - 1 ? ", " : "");
                }
                printf(")\n");
            } else if (curr->is_function) {
                printf("    %s: function(", curr->name);
                for(int p=0; p<curr->param_count; p++) {
                    printf("%s%s", type_to_string(curr->param_types[p]), p < curr->param_count - 1 ? ", " : "");
                }
                printf("): %s\n", type_to_string(curr->type));
            } else if (curr->type == TYPE_ARRAY) {
                printf("    %s: array [%d, %d] of %s\n", curr->name, curr->array_start, curr->array_end, type_to_string(curr->element_type));
            } else {
                printf("    %s: %s\n", curr->name, type_to_string(curr->type));
            }
            curr = curr->next_in_scope;
        }
    }
    
    Scope* temp = current_scope;
    current_scope = current_scope->next;
    /* 釋放記憶體 */
    for (int i = 0; i < HASH_SIZE; i++) {
        Entry* curr = temp->table[i];
        while (curr != NULL) {
            Entry* next = curr->next;
            free(curr);
            curr = next;
        }
    }
    free(temp);
}

/* 核心的 Insert 函數 */
Entry* insert_symbol(const char* name, DataType type, int is_const) {
    int idx = hash_djb2(name) % HASH_SIZE;
    Entry* curr = current_scope->table[idx];
    
    while (curr != NULL) {
        if (strcmp(curr->name, name) == 0) {
            char msg[256];
            sprintf(msg, "Semantic Error: Identifier '%s' is already declared.", name);
            yyerror(msg);
            return NULL; 
        }
        curr = curr->next;
    }
    
    Entry* new_entry = (Entry*)malloc(sizeof(Entry));
    strncpy(new_entry->name, name, MAX_ID_LEN - 1);
    new_entry->name[MAX_ID_LEN - 1] = '\0';
    new_entry->type = type;
    new_entry->is_const = is_const;
    new_entry->is_function = 0;
    new_entry->param_count = 0;
    new_entry->array_start = 0;
    new_entry->array_end = 0;
    new_entry->element_type = TYPE_UNKNOWN;
    
    new_entry->next = current_scope->table[idx];
    current_scope->table[idx] = new_entry;
    
    new_entry->next_in_scope = NULL;
    if (current_scope->order_head == NULL) {
        current_scope->order_head = new_entry;
        current_scope->order_tail = new_entry;
    } else {
        current_scope->order_tail->next_in_scope = new_entry;
        current_scope->order_tail = new_entry;
    }
    
    return new_entry;
}

Entry* lookup_symbol(const char* name) {
    Scope* sc = current_scope;
    while (sc != NULL) {
        int idx = hash_djb2(name) % HASH_SIZE;
        Entry* curr = sc->table[idx];
        while (curr != NULL) {
            if (strcmp(curr->name, name) == 0) {
                return curr; 
            }
            curr = curr->next;
        }
        sc = sc->next;
    }
    return NULL; 
}

%}

%union {
    int ival;
    float fval;
    char* sval;
    int type_val; 
    struct _IdNode* id_node_ptr; 
    struct _ParamList* param_list_ptr; /* 新增：用來傳遞已打包好的參數陣列 */
}

/* Tokens */
%token <sval> ID STR_CONST
%token <ival> INT_CONST
%token <fval> REAL_CONST

/* Keywords */
%token PROGRAM CONST VAR ARRAY OF 
%token INTEGER_TYPE REAL_TYPE BOOLEAN_TYPE STRING_TYPE
%token FUNCTION PROCEDURE BEGIN_KW END
%token IF THEN ELSE WHILE DO FOR TO REPEAT UNTIL
%token READ WRITE WRITELN RETURN TRUE_KW FALSE_KW

/* Operators & Symbols */
%token ASSIGN LE GE NEQ SEMICOLON COLON COMMA EQ LT GT
%token ADD SUB MUL DIV LPAREN RPAREN LBRACK RBRACK DOT MOD AND OR NOT

/* Non-terminal types */
%type <type_val> type expr
%type <id_node_ptr> id_list opt_formal_args formal_args formal_arg
%type <param_list_ptr> opt_expr opt_expr_list expr_list

/* Precedence */
%nonassoc LOWER_THAN_ELSE 
%nonassoc ELSE
%left OR
%left AND
%right NOT
%left EQ NEQ LT LE GT GE
%left ADD SUB
%left MUL DIV MOD
%right UMINUS

%%

/*=========================
 * Program Structure
 *=========================*/
program:
    PROGRAM ID SEMICOLON {
        push_scope(); 
    }
    decls 
    subprograms 
    BEGIN_KW 
    stmts 
    END ID DOT {
        if (strcmp($2, $10) != 0) {
            yyerror("Semantic Error: Program end identifier does not match start identifier.");
        }
        pop_scope();
        free($2); free($10);
        Reduce("program", "PROGRAM ID ; decls subprograms BEGIN stmts END ID .");
    } ;

/*=========================
 * Global Declarations
 *=========================*/
decls:
    decls decl |
    /* empty */ ;

decl:
    const_decl |
    var_decl ;

const_decl:
    CONST ID EQ expr SEMICOLON {
        Reduce("const_decl", "CONST ID = expr ;");
        Entry* sym = insert_symbol($2, TYPE_UNKNOWN, 1);
        if (sym != NULL) {
            sym->type = (DataType)$4;
        }
        free($2);
    } ;

var_decl:
    VAR id_list COLON type opt_init SEMICOLON {
        Reduce("var_decl", "VAR id_list : type opt_init ;");
        IdNode* curr = $2;
        while (curr != NULL) {
            insert_symbol(curr->name, (DataType)$4, 0);
            IdNode* temp = curr;
            curr = curr->next;
            free(temp); 
        }
    } |
    VAR id_list COLON ARRAY LBRACK INT_CONST COMMA INT_CONST RBRACK OF type SEMICOLON {
        Reduce("var_decl", "VAR id_list : ARRAY [ INT , INT ] OF type ;");
        IdNode* curr = $2;
        while (curr != NULL) {
            Entry* sym = insert_symbol(curr->name, TYPE_ARRAY, 0);
            if (sym != NULL) {
                sym->array_start = $6;
                sym->array_end = $8;
                sym->element_type = (DataType)$11;
            }
            IdNode* temp = curr;
            curr = curr->next;
            free(temp);
        }
    } ;

id_list:
    id_list COMMA ID {
        IdNode* node = create_id_node($3);
        IdNode* curr = $1;
        while (curr->next != NULL) {
            curr = curr->next;
        }
        curr->next = node;
        $$ = $1;
        free($3); 
    } |
    ID {
        $$ = create_id_node($1);
        free($1);
    } ;

opt_init:
    EQ expr |
    /* empty */ ;

type:
    INTEGER_TYPE { $$ = TYPE_INT; } |
    REAL_TYPE  { $$ = TYPE_REAL; } |
    BOOLEAN_TYPE { $$ = TYPE_BOOL; } |
    STRING_TYPE  { $$ = TYPE_STR; } ;

/*=========================
 * Functions & Procedures
 *=========================*/
subprograms:
    subprograms subprogram |
    /* empty */ ;

subprogram:
    func_decl |
    proc_decl ;

func_decl:
    FUNCTION ID  { 
        insert_symbol($2, TYPE_UNKNOWN, 0);
        push_scope();
    }
    opt_formal_args COLON type SEMICOLON {
        Entry* sym = lookup_symbol($2);
        if (sym != NULL) {
            sym->is_function = 1;
            sym->type = (DataType)$6; 
            IdNode* curr = $4;
            while (curr != NULL) {
                if (sym->param_count < MAX_PARAMS) {
                    sym->param_types[sym->param_count++] = curr->type;
                }
                IdNode* temp = curr;
                curr = curr->next;
                free(temp);
            }
        }
    }
    decls 
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        Reduce("func_decl", "FUNCTION ID opt_formal_args : type ; decls BEGIN stmts END ID ;");
        if (strcmp($2, $13) != 0) {
            yyerror("Semantic Error: Function end identifier does not match.");
        }
        pop_scope();
        free($2); free($13);
    } ;

proc_decl:
    PROCEDURE ID  { 
        insert_symbol($2, TYPE_VOID, 0); 
        push_scope(); 
    }
    opt_formal_args SEMICOLON {
        Entry* sym = lookup_symbol($2);
        if (sym != NULL) {
            sym->is_function = 1; /* 將程序也標示為可呼叫之涵式類別 */
            IdNode* curr = $4;
            while (curr != NULL) {
                if (sym->param_count < MAX_PARAMS) {
                    sym->param_types[sym->param_count++] = curr->type;
                }
                IdNode* temp = curr;
                curr = curr->next;
                free(temp);
            }
        }
    }
    decls 
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        Reduce("proc_decl", "PROCEDURE ID opt_formal_args ; decls BEGIN stmts END ID ;");
        if (strcmp($2, $11) != 0) {
            yyerror("Semantic Error: Procedure end identifier does not match.");
        }
        pop_scope();
        free($2); free($11);
    } ;

opt_formal_args:
    LPAREN formal_args RPAREN { $$ = $2; } |
    /* empty */               { $$ = NULL; } ;

formal_args:
    formal_args COMMA formal_arg {
        IdNode* curr = $1;
        while (curr->next != NULL) curr = curr->next;
        curr->next = $3;
        $$ = $1;
    } |
    formal_arg {
        $$ = $1;
    } ;

formal_arg:
    ID COLON type {
        Reduce("formal_arg", "ID : type");
        insert_symbol($1, (DataType)$3, 0);
        $$ = create_id_node($1);
        $$->type = (DataType)$3;
        free($1);
    } ;

/*=========================
 * Local Blocks & Statements
 *=========================*/
block_stmt:
    BEGIN_KW {
        push_scope(); 
    }
    decls stmts
    END SEMICOLON {
        pop_scope(); 
    } ;

stmts:
    stmts stmt |
    stmt ;

stmt:
    simple_stmt |
    block_stmt |
    conditional_stmt |
    loop_stmt ;

simple_stmt:
    ID ASSIGN expr SEMICOLON {
        Reduce("simple_stmt", "ID := expr ;");
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256];
            sprintf(msg, "Semantic Error: Undeclared identifier '%s'.", $1);
            yyerror(msg);
        } else if (sym->is_const) {
            char msg[256];
            sprintf(msg, "Semantic Error: Cannot assign to constant '%s'.", $1);
            yyerror(msg);
        } else if (sym->type != (DataType)$3 && (DataType)$3 != TYPE_UNKNOWN) {
            char msg[256];
            sprintf(msg, "Semantic Error: Cannot assign expression of type %s to '%s' of type %s.", type_to_string((DataType)$3), $1, type_to_string(sym->type));
            yyerror(msg);
        }
        free($1);
    } |
    ID LBRACK expr RBRACK ASSIGN expr SEMICOLON { 
        Reduce("simple_stmt", "ID [ expr ] := expr ;");
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256];
            sprintf(msg, "Semantic Error: Undeclared identifier '%s'.", $1);
            yyerror(msg);
        } else if (sym->type != TYPE_ARRAY) {
            char msg[256];
            sprintf(msg, "Semantic Error: '%s' is not an array.", $1);
            yyerror(msg);
        } else {
            if ((DataType)$3 != TYPE_INT && (DataType)$3 != TYPE_UNKNOWN) {
                char msg[256];
                sprintf(msg, "Semantic Error: Array index must be integer, got %s.", type_to_string((DataType)$3));
                yyerror(msg);
            }
            if (sym->element_type != (DataType)$6 && (DataType)$6 != TYPE_UNKNOWN) {
                char msg[256];
                sprintf(msg, "Semantic Error: Cannot assign expression of type %s to array element of type %s.", type_to_string((DataType)$6), type_to_string(sym->element_type));
                yyerror(msg);
            }
        }
        free($1); 
    } |
    WRITE expr SEMICOLON |
    WRITELN expr SEMICOLON |
    READ ID SEMICOLON { free($2); } |
    RETURN SEMICOLON |
    RETURN expr SEMICOLON |
    ID opt_expr SEMICOLON {
        Reduce("simple_stmt", "ID opt_expr ;");
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256];
            sprintf(msg, "Semantic Error: Undeclared function/procedure '%s'.", $1);
            yyerror(msg);
        } else {
            check_arguments($1, sym, $2); /* 執行參數檢查 */
        }
        free($1);
        if ($2) free($2); /* 釋放佔用的參數清單記憶體 */
    } ;

opt_expr:
    LPAREN opt_expr_list RPAREN { $$ = $2; } |
    /* empty */                 { $$ = create_param_list(); } ;

opt_expr_list:
    expr_list   { $$ = $1; } |
    /* empty */ { $$ = create_param_list(); } ;

expr_list:
    expr_list COMMA expr {
        $$ = $1;
        add_param_type($$, (DataType)$3);
    } |
    expr {
        $$ = create_param_list();
        add_param_type($$, (DataType)$1);
    } ;

conditional_stmt:
    IF expr THEN stmt %prec LOWER_THAN_ELSE |
    IF expr THEN stmt ELSE stmt ;

loop_stmt:
    REPEAT stmts UNTIL expr SEMICOLON |
    WHILE expr DO stmt |
    FOR ID ASSIGN expr TO expr DO stmt {
        Entry* sym = lookup_symbol($2);
        if (sym == NULL) {
            yyerror("Semantic Error: For-loop counter undeclared.");
        }
        free($2);
    } ;

/*=========================
 * Expressions
 *=========================*/
expr:
    expr OR expr   { $$ = TYPE_BOOL; } |
    expr AND expr  { $$ = TYPE_BOOL; } |
    NOT expr       { $$ = TYPE_BOOL; } |
    expr EQ expr   { $$ = TYPE_BOOL; } |
    expr NEQ expr  { $$ = TYPE_BOOL; } |
    expr LT expr   { $$ = TYPE_BOOL; } |
    expr LE expr   { $$ = TYPE_BOOL; } |
    expr GT expr   { $$ = TYPE_BOOL; } |
    expr GE expr   { $$ = TYPE_BOOL; } |
    expr ADD expr  { $$ = ($1 == TYPE_REAL || $3 == TYPE_REAL) ? TYPE_REAL : TYPE_INT; } |
    expr SUB expr  { $$ = ($1 == TYPE_REAL || $3 == TYPE_REAL) ? TYPE_REAL : TYPE_INT; } |
    expr MUL expr  { $$ = ($1 == TYPE_REAL || $3 == TYPE_REAL) ? TYPE_REAL : TYPE_INT; } |
    expr DIV expr  { $$ = ($1 == TYPE_REAL || $3 == TYPE_REAL) ? TYPE_REAL : TYPE_INT; } |
    expr MOD expr  { $$ = TYPE_INT; } |
    SUB expr %prec UMINUS { $$ = $2; } |
    LPAREN expr RPAREN    { $$ = $2; } |
    ID  {
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256];
            sprintf(msg, "Semantic Error: Undeclared identifier '%s'.", $1);
            yyerror(msg);
            $$ = TYPE_UNKNOWN;
        } else if (sym->type == TYPE_VOID) {
            yyerror("Semantic Error: Procedure cannot be used in an expression.");
            $$ = TYPE_UNKNOWN;
        } else {
            $$ = sym->type;
        }
        free($1);
    } |
    ID LBRACK expr RBRACK { 
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256];
            sprintf(msg, "Semantic Error: Undeclared identifier '%s'.", $1);
            yyerror(msg);
            $$ = TYPE_UNKNOWN;
        } else if (sym->type != TYPE_ARRAY) {
            char msg[256];
            sprintf(msg, "Semantic Error: '%s' is not an array.", $1);
            yyerror(msg);
            $$ = TYPE_UNKNOWN;
        } else {
            if ((DataType)$3 != TYPE_INT && (DataType)$3 != TYPE_UNKNOWN) {
                char msg[256];
                sprintf(msg, "Semantic Error: Array index must be integer, got %s.", type_to_string((DataType)$3));
                yyerror(msg);
            }
            $$ = sym->element_type;
        }
        free($1); 
    } |
    ID LPAREN opt_expr_list RPAREN {
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256];
            sprintf(msg, "Semantic Error: Undeclared function '%s'.", $1);
            yyerror(msg);
            $$ = TYPE_UNKNOWN;
        } else if (sym->type == TYPE_VOID) {
            yyerror("Semantic Error: Procedure cannot be used in an expression.");
            $$ = TYPE_UNKNOWN;
        } else if (!sym->is_function) {
            char msg[256];
            sprintf(msg, "Semantic Error: '%s' is not a function.", $1);
            yyerror(msg);
            $$ = TYPE_UNKNOWN;
        } else {
            check_arguments($1, sym, $3); /* 執行參數檢查 */
            $$ = sym->type;
        }
        free($1);
        if ($3) free($3); /* 釋放佔用的參數清單記憶體 */
    } |
    INT_CONST { $$ = TYPE_INT; } |
    REAL_CONST { $$ = TYPE_REAL; } |
    STR_CONST { $$ = TYPE_STR; free($1); } |
    TRUE_KW { $$ = TYPE_BOOL; } |
    FALSE_KW { $$ = TYPE_BOOL; } ;

%%

void yyerror(const char *msg) {
    fprintf(stderr, "%02d: %s\n", yylineno, msg);
    error_count++;
}

int main(int argc, char** argv) {
    if (yyparse() == 0 && error_count == 0) {
        printf("\n=> Syntax analysis completed successfully!\n");
        return 0;
    } else {
        printf("\n=> Parsing failed.\n");
        return 1;
    }
}