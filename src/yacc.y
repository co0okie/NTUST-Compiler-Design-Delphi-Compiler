%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "ast.h"

#define Reduce(l, r) if (LOG_TRACE) printf("/* %2d: %16s <= %-80s */\n", yylineno, l, r)
#define Trace(t)  if (LOG_TRACE) printf("/* %2d: %-100s */\n", yylineno, t)

#define JASM(...) \
    do { \
        if (LOG_JASM) printf(__VA_ARGS__); \
    } while(0)
#define ERROR(...) \
    do { \
        fprintf(stderr, "%02d: Semantic Error: ", yylineno); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
    } while(0)
int LOG_TRACE = 0;
int LOG_TABLE = 0;
int LOG_JASM = 1;

extern int yylineno;
extern int yylex();
void yyerror(const char *msg);

/*======================================================
 * Semantic Analysis: Symbol Table & Scope Management
 *======================================================*/
#define HASH_SIZE 211
#define MAX_ID_LEN 50

typedef struct _ParamNode {
    DataType type;
    struct _ParamNode *next;
} ParamNode;

typedef enum {
    SYM_VAR,
    SYM_CONST,
    SYM_FUNC,
    SYM_PROC
} SymbolKind;

typedef struct _Entry {
    char* name;
    SymbolKind kind;
    DataType type;
    
    union {
        struct {
            int is_initialized;
            int is_global;
            int index;
            int val;
        } var;

        struct {
            union {
                int int_val;
                int bool_val;
                char* str_val;
            } val;
        } const_;
        
        struct {
            ParamNode* param_list;
        } subprog;
    } as;
    
    struct _Entry *next;
    struct _Entry *next_in_scope; 
} Entry;

typedef struct _Scope {
    Entry* table[HASH_SIZE];
    // order_head -- entry->next_in_scope -- entry->next_in_scope -- ... -- order_tail
    Entry* order_head;
    Entry* order_tail;
    int local_index;
    DataType return_type; // for function/procedure
    int has_return;
    struct _Scope *next; // outer scope
} Scope;

Scope* current_scope = NULL;
char* program_id;
int label_counter = 0;

const char* type_to_string(DataType t) {
    switch(t) {
        case TYPE_INT: return "integer";
        case TYPE_BOOL: return "boolean";
        case TYPE_STR: return "string";
        case TYPE_VOID: return "void";
        default: return "unknown";
    }
}

const char* kind_to_string(SymbolKind k) {
    switch(k) {
        case SYM_VAR: return "var";
        case SYM_CONST: return "const";
        case SYM_FUNC: return "function";
        case SYM_PROC: return "procedure";
        default: return "unknown";
    }
}

unsigned long hash_djb2(const char *str) {
    unsigned long hash = 5381;
    int c;
    while ((c = *str++))
        hash = ((hash << 5) + hash) + c;
    return hash;
}

void push_scope(int reset_local_index, DataType return_type) {
    Scope* new_scope = (Scope*)malloc(sizeof(Scope));
    for (int i = 0; i < HASH_SIZE; i++) {
        new_scope->table[i] = NULL;
    }
    new_scope->order_head = NULL;
    new_scope->order_tail = NULL;
    new_scope->local_index = reset_local_index ? 0 : current_scope->local_index;
    new_scope->return_type = return_type;
    new_scope->has_return = 0;
    new_scope->next = current_scope;
    current_scope = new_scope;
    Trace("Scope Pushed");
}

void print_symbol_table(Scope* scope) {
    printf("/* %2d: Symbol Table of Current Scope:\n", yylineno);
    for (Entry* curr = scope->order_head; curr != NULL; curr = curr->next_in_scope) {
        if (curr->kind == SYM_PROC || curr->kind == SYM_FUNC) {
            printf("    %s: %s(", curr->name, type_to_string(curr->type));
            ParamNode* pnode = curr->as.subprog.param_list;
            while (pnode != NULL) {
                printf("%s%s", type_to_string(pnode->type), pnode->next ? ", " : "");
                pnode = pnode->next;
            }
            printf(")\n");
        } else if (curr->kind == SYM_CONST) {
            printf("    %s: const %s ", curr->name, type_to_string(curr->type));
            if (curr->type == TYPE_INT) {
                printf("%d\n", curr->as.const_.val.int_val);
            } else if (curr->type == TYPE_BOOL) {
                printf("%s\n", curr->as.const_.val.bool_val ? "true" : "false");
            } else if (curr->type == TYPE_STR) {
                printf("\"%s\"\n", curr->as.const_.val.str_val);
            } else {
                printf("unknown\n");
            }
        } else if (curr->kind == SYM_VAR) {
            printf("    %s: %s", curr->name, type_to_string(curr->type));
            if (curr->as.var.is_initialized)
                printf(" %d", curr->as.var.val);
            if (curr->as.var.is_global)
                printf(", global");
            else
                printf(", local index %d", curr->as.var.index);
            printf("\n");
        }
    }
    printf(" */\n");
}

void pop_scope() {
    if (current_scope == NULL) return;
    
    Scope* temp = current_scope;
    current_scope = current_scope->next;
    for (int i = 0; i < HASH_SIZE; i++) {
        Entry* curr = temp->table[i];
        while (curr != NULL) {
            Entry* next = curr->next;
            
            if (curr->kind == SYM_CONST && curr->type == TYPE_STR && curr->as.const_.val.str_val != NULL) {
                free(curr->as.const_.val.str_val);
            }
            if (curr->kind == SYM_FUNC || curr->kind == SYM_PROC) {
                ParamNode* pnode = curr->as.subprog.param_list;
                while (pnode != NULL) {
                    ParamNode* next_pnode = pnode->next;
                    free(pnode);
                    pnode = next_pnode;
                }
            }
            free(curr->name);
            free(curr);
            curr = next;
        }
    }
    free(temp);
}

Entry* insert_symbol(const char* name, SymbolKind kind, DataType type) {
    int idx = hash_djb2(name) % HASH_SIZE;
    Entry* curr = current_scope->table[idx];
    
    while (curr != NULL) {
        if (strcmp(curr->name, name) == 0) {
            ERROR("Identifier '%s' is already declared.", name);
            return NULL; 
        }
        curr = curr->next;
    }
    
    Entry* new_entry = (Entry*)malloc(sizeof(Entry));
    new_entry->name = strdup(name);
    new_entry->kind = kind;
    new_entry->type = type;
    
    if (kind == SYM_FUNC || kind == SYM_PROC) {
        new_entry->as.subprog.param_list = NULL;
    }
    
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

const char* type_to_jasm(DataType t) {
    switch(t) {
        case TYPE_INT: return "int";
        case TYPE_BOOL: return "int";
        case TYPE_STR: return "java.lang.String";
        case TYPE_VOID: return "void";
    }
    return NULL;
}

void print_expr_jasm(ASTNode* expr);

void print_assign_jasm(Entry* sym, ASTNode* expr) {
    print_expr_jasm(expr);
    if (sym->as.var.is_global)
        JASM("    putstatic int %s.%s\n", program_id, sym->name);
    else
        JASM("    istore %d\n", sym->as.var.index);
}
%}

%union {
    int ival;
    float fval;
    char* sval;
    int type_val;
    struct _Entry* symbol;
    struct _ASTNode* ast_node;
    struct {
        int label1;
        int label2;
    } l;
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
%type <type_val> type 
%type <symbol> id var_id
%type <ast_node> expr const_expr opt_expr_list expr_list id_list var_decl decl opt_decls opt_params params param opt_init id_opt_invoke opt_invoke boolean_expr
%type <l> if_prefix

/* Precedence */
%nonassoc LOWER_THAN_ELSE 
%nonassoc ELSE
%left OR
%left AND
%right NOT
%left EQ NEQ LT LE GT GE
%left ADD SUB
%left MUL DIV MOD
%right NEG

%%

program:
    PROGRAM ID SEMICOLON {
        JASM("class %s {\n", $2);
        program_id = $2;
        push_scope(1, TYPE_VOID);
    }
    opt_global_decls {
        if (LOG_TABLE) print_symbol_table(current_scope);
    }
    opt_subprograms 
    BEGIN_KW {
        if (LOG_TABLE) print_symbol_table(current_scope);
        JASM("  method public static void main(java.lang.String[])\n");
        JASM("  max_stack 15\n");
        JASM("  max_locals 15 {\n");
    }
    opt_stmts 
    END ID DOT {
        if (strcmp($2, $12) != 0) {
            ERROR("Program end identifier does not match start identifier.");
            YYABORT;
        }
        pop_scope();
        free($2); free($12);
        JASM("    return\n");
        JASM("  }\n");
        JASM("}\n");
        Reduce("program", "PROGRAM ID ; opt_decls opt_subprograms BEGIN opt_stmts END ID .");
    } ;

opt_subprograms:
    opt_subprograms subprogram |
    /* empty */ ;

subprogram:
    func_decl |
    proc_decl ;

func_decl:
    FUNCTION ID  { 
        Entry* sym = insert_symbol($2, SYM_FUNC, TYPE_UNKNOWN);
        if (sym == NULL) YYABORT;
        push_scope(1, TYPE_UNKNOWN);
    }
    opt_params COLON type SEMICOLON {
        if ($6 == TYPE_STR) {
            ERROR("function of return type string is not supported.");
            YYABORT;
        }
        Entry* sym = lookup_symbol($2);
        sym->type = (DataType)$6;
        current_scope->return_type = (DataType)$6;
        ParamNode** tail = &(sym->as.subprog.param_list);
        for (ASTNode* curr = $4->as.list.head; curr != NULL; curr = curr->next) {
            assert(curr->node_type == AST_PARAM);
            *tail = (ParamNode*)malloc(sizeof(ParamNode));
            (*tail)->type = curr->as.param.type;
            (*tail)->next = NULL;
            tail = &((*tail)->next);
        }
        JASM("  method public static %s %s(", type_to_jasm($6), sym->name);
        for (ASTNode* curr = $4->as.list.head; curr != NULL; curr = curr->next) {
            JASM("%s", type_to_jasm(curr->as.param.type));
            if (curr->next) JASM(", ");
        }
        JASM(")\n");
        JASM("  max_stack 15\n");
        JASM("  max_locals 15 {\n");
    }
    opt_local_decls {
        if (LOG_TABLE) print_symbol_table(current_scope);
    }
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        JASM("    nop\n");
        JASM("  }\n");
        if (strcmp($2, $14) != 0) {
            ERROR("Function end identifier does not match.");
            YYABORT;
        }
        Reduce("func_decl", "FUNCTION ID opt_params : type ; opt_decls BEGIN stmts END ID ;");
        pop_scope();
        free($2); free($14);
        if ($4) free_ast($4);
    } ;

proc_decl:
    PROCEDURE ID  { 
        Entry* sym = insert_symbol($2, SYM_PROC, TYPE_VOID); 
        if (sym == NULL) YYABORT;
        push_scope(1, TYPE_VOID);
    }
    opt_params SEMICOLON {
        Entry* sym = lookup_symbol($2);
        if (sym != NULL) {
            ParamNode** tail = &(sym->as.subprog.param_list);
            for (ASTNode* curr = $4->as.list.head; curr != NULL; curr = curr->next) {
                assert(curr->node_type == AST_PARAM);
                *tail = (ParamNode*)malloc(sizeof(ParamNode));
                (*tail)->type = curr->as.param.type;
                (*tail)->next = NULL;
                tail = &((*tail)->next);
            }
        }
        JASM("  method public static void %s(", sym->name);
        for (ASTNode* curr = $4->as.list.head; curr != NULL; curr = curr->next) {
            JASM("%s", type_to_jasm(curr->as.param.type));
            if (curr->next) JASM(", ");
        }
        JASM(")\n");
        JASM("  max_stack 15\n");
        JASM("  max_locals 15 {\n");
    }
    opt_local_decls {
        if (LOG_TABLE) print_symbol_table(current_scope);
    }
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        JASM("    return\n");
        JASM("  }\n");
        Reduce("proc_decl", "PROCEDURE ID opt_params ; opt_decls BEGIN stmts END ID ;");
        if (strcmp($2, $12) != 0) {
            ERROR("Procedure end identifier does not match.");
            YYABORT;
        }
        pop_scope();
        free($2); free($12);
        if ($4) free_ast($4);
    } ;

opt_params:
    LPAREN params RPAREN { $$ = $2; } |
    /* empty */          { $$ = new_list_node(); } ;

params:
    params COMMA param {
        $$ = $1;
        append_ast_node(&$1->as.list, $3);
    } |
    param {
        $$ = new_list_node();
        append_ast_node(&$$->as.list, $1);
    } ;

param:
    ID COLON type {
        Reduce("param", "ID : type");
        if ($3 == TYPE_STR) {
            ERROR("string parameter is not supported.");
            YYABORT;
        }
        Entry* sym = insert_symbol($1, SYM_VAR, (DataType)$3);
        if (sym == NULL) YYABORT;
        sym->as.var.index = current_scope->local_index++;
        sym->as.var.is_initialized = 0;
        sym->as.var.is_global = 0;
        $$ = new_param_node($1, (DataType)$3);
        free($1);
    } ;

opt_stmts:
    stmts |
    /* empty */ ;

stmts:
    stmts stmt |
    stmt ;

stmt:
    simple_stmt |
    block_stmt |
    conditional_stmt |
    loop_stmt |
    procedure_invoke ;

simple_stmt:
    var_id ASSIGN expr SEMICOLON {
        Reduce("simple_stmt", "var_id := expr ;");
        if ($1->type != $3->as.expr.data_type && $3->as.expr.data_type != TYPE_UNKNOWN && $1->type != TYPE_UNKNOWN) {
            ERROR("Type %s != %s mismatch in assignment.", type_to_string($1->type), type_to_string($3->as.expr.data_type)); YYABORT;
        }
        print_assign_jasm($1, $3);
        free_ast($3);
    } |
    WRITE expr SEMICOLON {
        JASM("    getstatic java.io.PrintStream java.lang.System.out\n");
        print_expr_jasm($2);
        DataType t = $2->as.expr.data_type;
        JASM("    invokevirtual void java.io.PrintStream.print(%s)\n", t == TYPE_BOOL ? "boolean" : type_to_jasm(t));
        Reduce("simple_stmt", "WRITE expr ;");
        free_ast($2);
    } |
    WRITELN expr SEMICOLON {
        JASM("    getstatic java.io.PrintStream java.lang.System.out\n");
        print_expr_jasm($2);
        DataType t = $2->as.expr.data_type;
        JASM("    invokevirtual void java.io.PrintStream.println(%s)\n", t == TYPE_BOOL ? "boolean" : type_to_jasm(t));
        Reduce("simple_stmt", "WRITELN expr ;");
        free_ast($2);
    } |
    READ ID SEMICOLON {
        ERROR("read is not supported.");
        YYABORT;
    } |
    RETURN SEMICOLON {
        if (current_scope->return_type != TYPE_VOID) {
            ERROR("return type should be void but got %s.", type_to_string(current_scope->return_type));
            YYABORT;
        }
        JASM("    return\n");
        Reduce("simple_stmt", "RETURN ;");
    } |
    RETURN expr SEMICOLON {
        if (current_scope->return_type != $2->as.expr.data_type) {
            ERROR("return type should be %s but got %s.", type_to_string(current_scope->return_type), type_to_string($2->as.expr.data_type));
            YYABORT;
        }
        print_expr_jasm($2);
        JASM("    ireturn\n");
        Reduce("simple_stmt", "RETURN expr ;");
        free_ast($2);
    } ;

block_stmt:
    BEGIN_KW {
        push_scope(0, current_scope->return_type);
    }
    opt_local_decls {
        if (LOG_TABLE) print_symbol_table(current_scope);
    } stmts
    END SEMICOLON {
        Reduce("block_stmt", "BEGIN opt_decls stmts END ;");
        pop_scope(); 
    } ;

if_prefix:
    IF boolean_expr THEN {
        print_expr_jasm($2);
        free_ast($2);
        
        $$.label1 = label_counter++;
        $$.label2 = label_counter++; // for if-then-else only
        
        JASM("    ifeq L%d\n", $$.label1);
    } ;

conditional_stmt:
    if_prefix stmt %prec LOWER_THAN_ELSE {
        JASM("L%d: nop\n", $1.label1);
        Reduce("conditional_stmt", "IF boolean_expr THEN stmt");
    } |
    if_prefix stmt ELSE {
        JASM("    goto L%d\n", $1.label2);
        JASM("L%d: nop\n", $1.label1);
    } stmt {
        JASM("L%d: nop\n", $1.label2);
        Reduce("conditional_stmt", "IF boolean_expr THEN stmt ELSE stmt");
    } ;

loop_stmt:
    REPEAT {
        $<l>$.label1 = label_counter++;
        JASM("L%d: nop\n", $<l>$.label1);
    } stmts UNTIL boolean_expr SEMICOLON {
        print_expr_jasm($5);
        JASM("    ifeq L%d\n", $<l>2.label1);
        Reduce("loop_stmt", "REPEAT stmts UNTIL boolean_expr ;");
        free_ast($5);
    } |
    WHILE boolean_expr {
        $<l>$.label1 = label_counter++;
        JASM("L%d: nop\n", $<l>$.label1);
        print_expr_jasm($2);
        $<l>$.label2 = label_counter++;
        JASM("    ifeq L%d\n", $<l>$.label2);
    } DO stmt {
        JASM("    goto L%d\n", $<l>3.label1);
        JASM("L%d: nop\n", $<l>3.label2);
        Reduce("loop_stmt", "WHILE boolean_expr DO stmt");
        free_ast($2);
    } |
    FOR var_id ASSIGN expr TO expr {
        if ($2->type != TYPE_INT) { ERROR("For-loop counter %s must be integer.", $2->name); YYABORT; }
        if ($4->as.expr.data_type != TYPE_INT || $6->as.expr.data_type != TYPE_INT) {
            ERROR("For-loop bounds must be integer."); YYABORT;
        }
        print_assign_jasm($2, $4);
        $<l>$.label1 = label_counter++;
        JASM("L%d: nop\n", $<l>$.label1);
        ASTNode* var = $2->as.var.is_global ? 
            new_expr_global_var_node($2->name, $2->type) : 
            new_expr_local_var_node($2->as.var.index, $2->type);
        ASTNode* cmp = new_expr_binary_op_node(LE, var, $6);
        print_expr_jasm(cmp);
        $<l>$.label2 = label_counter++;
        JASM("    ifeq L%d\n", $<l>$.label2);
        free_ast(cmp);
    } DO stmt {
        ASTNode* var = $2->as.var.is_global ? 
            new_expr_global_var_node($2->name, $2->type) : 
            new_expr_local_var_node($2->as.var.index, $2->type);
        ASTNode* inc = new_expr_binary_op_node(ADD, var, new_expr_int_node(1));
        print_assign_jasm($2, inc);
        JASM("    goto L%d\n", $<l>7.label1);
        JASM("L%d: nop\n", $<l>7.label2);
        Reduce("loop_stmt", "FOR var_id := expr TO expr DO stmt");
        free_ast(inc); free_ast($4);
    } ;

procedure_invoke:
    id_opt_invoke SEMICOLON {
        Entry* sym = lookup_symbol($1->as.expr.as.invoke.name);
        if (sym->type != TYPE_VOID) {
            ERROR("\"%s\" of kind \"%s\" cannat be invoked in a statement.", sym->name, kind_to_string(sym->kind)); 
            YYABORT;
        }
        print_expr_jasm($1);
        Reduce("procedure_invoke", "id_invoke ;");
        free_ast($1);
    } ;

opt_global_decls:
    opt_decls {
        for (ASTNode* n = $1->as.list.head; n != NULL; n = n->next) {
            Entry* sym = lookup_symbol(n->as.id);
            if (sym->kind != SYM_VAR) continue;
            sym->as.var.is_global = 1;
            if (!LOG_JASM) continue;
            printf("  field static int %s", sym->name);
            if (sym->as.var.is_initialized) printf(" = %d", sym->as.var.val);
            printf("\n");
        }
        free_ast($1);
    } ;

opt_local_decls:
    opt_decls {
        for (ASTNode* n = $1->as.list.head; n != NULL; n = n->next) {
            Entry* sym = lookup_symbol(n->as.id);
            if (sym->kind != SYM_VAR) continue;
            sym->as.var.index = current_scope->local_index++;
            sym->as.var.is_global = 0;
            if (!LOG_JASM) continue;
            if (!sym->as.var.is_initialized) continue;
            printf("    sipush %d\n", sym->as.var.val);
            printf("    istore %d\n", sym->as.var.index);
        }
        free_ast($1);
    } ;

opt_decls:
    opt_decls decl {
        $$ = $1;
        // concat $1 and $2
        if ($$->as.list.tail) $$->as.list.tail->next = $2->as.list.head;
        else $$->as.list.head = $2->as.list.head;
        $$->as.list.tail = $2->as.list.tail;
        free($2); // not free_ast, to keep list alive
    } |
    /* empty */ { $$ = new_list_node(); } ;

decl:
    const_decl { $$ = new_list_node(); } |
    var_decl { $$ = $1; } ;

const_decl:
    CONST ID EQ const_expr SEMICOLON {
        Reduce("const_decl", "CONST ID = const_expr ;");
        Entry* sym = insert_symbol($2, SYM_CONST, $4->as.expr.data_type);
        if (sym == NULL) YYABORT;
        if ($4->as.expr.data_type == TYPE_INT) sym->as.const_.val.int_val = $4->as.expr.as.int_val;
        else if ($4->as.expr.data_type == TYPE_BOOL) sym->as.const_.val.bool_val = $4->as.expr.as.bool_val;
        else if ($4->as.expr.data_type == TYPE_STR) sym->as.const_.val.str_val = strdup($4->as.expr.as.str_val);
        free($2);
        free_ast($4);
    } ;

var_decl:
    VAR id_list COLON type opt_init SEMICOLON {
        Reduce("var_decl", "VAR id_list : type opt_init ;");
        if ($4 == TYPE_STR) {
            ERROR("string variable is not supported.");
            YYABORT;
        }
        if ($5 && $4 != $5->as.expr.data_type) {
            ERROR("variable type does not match initializer type."); 
            YYABORT;
        }
        for (ASTNode* curr = $2->as.list.head; curr != NULL; curr = curr->next) {
            Entry* sym = insert_symbol(curr->as.id, SYM_VAR, (DataType)$4);
            if (sym == NULL) YYABORT;
            if ($5) {
                sym->as.var.is_initialized = 1;
                sym->as.var.val = $5->as.expr.as.int_val;
            } else {
                sym->as.var.is_initialized = 0;
            }
        }
        $$ = $2;
        if ($5) free_ast($5);
    } |
    VAR id_list COLON ARRAY LBRACK INT_CONST COMMA INT_CONST RBRACK OF type SEMICOLON {
        ERROR("array is not supported.");
        YYABORT;
    } ;

id_list:
    id_list COMMA ID {
        $$ = $1;
        append_ast_node(&$$->as.list, new_id_node($3));
        free($3);
    } |
    ID {
        $$ = new_list_node();
        append_ast_node(&$$->as.list, new_id_node($1));
        free($1);
    } ;

opt_init:
    EQ const_expr { $$ = $2; } |
    /* empty */ { $$ = NULL; } ;

const_expr:
    expr {
        if (!$1->as.expr.is_const) {
            ERROR("Const expression must be evaluated at compile time.");
            YYABORT;
        }
        $$ = $1;
    }

boolean_expr:
    expr {
        if ($1->as.expr.data_type != TYPE_BOOL && $1->as.expr.data_type != TYPE_UNKNOWN) {
            ERROR("Condition expression must be boolean.");
            YYABORT;
        }
        $$ = $1;
    } ;

expr:
    expr OR expr   { $$ = new_expr_binary_op_node(OR, $1, $3); if (!$$) YYABORT; } |
    expr AND expr  { $$ = new_expr_binary_op_node(AND, $1, $3); if (!$$) YYABORT; } |
    NOT expr       { $$ = new_expr_unary_op_node(NOT, $2); if (!$$) YYABORT; } |
    expr EQ expr   { $$ = new_expr_binary_op_node(EQ, $1, $3); if (!$$) YYABORT; } |
    expr NEQ expr  { $$ = new_expr_binary_op_node(NEQ, $1, $3); if (!$$) YYABORT; } |
    expr LT expr   { $$ = new_expr_binary_op_node(LT, $1, $3); if (!$$) YYABORT; } |
    expr LE expr   { $$ = new_expr_binary_op_node(LE, $1, $3); if (!$$) YYABORT; } |
    expr GT expr   { $$ = new_expr_binary_op_node(GT, $1, $3); if (!$$) YYABORT; } |
    expr GE expr   { $$ = new_expr_binary_op_node(GE, $1, $3); if (!$$) YYABORT; } |
    expr ADD expr  { $$ = new_expr_binary_op_node(ADD, $1, $3); if (!$$) YYABORT; } |
    expr SUB expr  { $$ = new_expr_binary_op_node(SUB, $1, $3); if (!$$) YYABORT; } |
    expr MUL expr  { $$ = new_expr_binary_op_node(MUL, $1, $3); if (!$$) YYABORT; } |
    expr DIV expr  { $$ = new_expr_binary_op_node(DIV, $1, $3); if (!$$) YYABORT; } |
    expr MOD expr  { $$ = new_expr_binary_op_node(MOD, $1, $3); if (!$$) YYABORT; } |
    SUB expr %prec NEG { $$ = new_expr_unary_op_node(NEG, $2); if (!$$) YYABORT; } |
    LPAREN expr RPAREN    { $$ = $2; } |
    id_opt_invoke {
        if ($1->as.expr.data_type == TYPE_VOID) {
            ERROR("Procedure cannot be used in an expression."); 
            YYABORT;
        }
        $$ = $1;
    } |
    INT_CONST { $$ = new_expr_int_node($1); } |
    REAL_CONST {
        ERROR("real constants are not supported."); 
        YYABORT;
    } |
    STR_CONST { $$ = new_expr_str_node($1); free($1); } |
    TRUE_KW { $$ = new_expr_bool_node(1); } |
    FALSE_KW { $$ = new_expr_bool_node(0); } ;

/* -----------------------------------------------------
 * Invoke Engine: Handles Variable Resolution & Calling
 * ----------------------------------------------------- */
id_opt_invoke:
    id opt_invoke {
        if ($2 == NULL) { /* Variable or parameterless call (no parentheses) */
            if ($1->kind == SYM_FUNC || $1->kind == SYM_PROC) {
                if ($1->as.subprog.param_list != NULL) {
                    ERROR("Too few arguments in call to '%s'.", $1->name);
                    YYABORT;
                } else {
                    $$ = new_expr_invoke_node($1->type, $1->name, new_list());
                }
            } else if ($1->kind == SYM_CONST) {
                $$ = $1->type == TYPE_INT ?
                    new_expr_int_node($1->as.const_.val.int_val) :
                    $1->type == TYPE_BOOL ?
                    new_expr_bool_node($1->as.const_.val.bool_val) :
                    new_expr_str_node($1->as.const_.val.str_val);
            } else { // variable
                $$ = $1->as.var.is_global ?
                    new_expr_global_var_node($1->name, $1->type) :
                    new_expr_local_var_node($1->as.var.index, $1->type);
            }
        } else { /* Call with parentheses */
            if ($1->kind != SYM_FUNC && $1->kind != SYM_PROC) {
                ERROR("\"%s\" of kind \"%s\" is not a function/procedure.", $1->name, kind_to_string($1->kind));
                YYABORT;
            } else {
                ASTNode* curr_arg = $2->as.list.head;
                ParamNode* curr_param = $1->as.subprog.param_list;
                int arg_index = 1;
                while (curr_param != NULL) {
                    if (curr_arg == NULL) {
                        ERROR("Too few arguments in call to '%s'.", $1->name); YYABORT; break;
                    }
                    if (curr_param->type != curr_arg->as.expr.data_type && curr_arg->as.expr.data_type != TYPE_UNKNOWN) {
                        ERROR("Argument %d of '%s' expects %s, but got %s.", arg_index, $1->name, type_to_string(curr_param->type), type_to_string(curr_arg->as.expr.data_type)); YYABORT;
                    }
                    curr_param = curr_param->next;
                    curr_arg = curr_arg->next;
                    arg_index++;
                }
                if (curr_param == NULL && curr_arg != NULL) {
                    ERROR("Too many arguments in call to '%s'.", $1->name); YYABORT;
                }
                $$ = new_expr_invoke_node($1->type, $1->name, $2->as.list);
            }
            free($2); // not free_ast, to keep expr_list alive
        }
    } ;

opt_invoke:
    LBRACK expr RBRACK {
        ERROR("array is not supported.");
        YYABORT;
    } |
    LPAREN opt_expr_list RPAREN {
        $$ = $2;
    } |
    /* empty */ { $$ = NULL; } ;

opt_expr_list:
    expr_list   { $$ = $1; } |
    /* empty */ { $$ = new_list_node(); } ;

expr_list:
    expr_list COMMA expr {
        $$ = $1;
        append_ast_node(&$$->as.list, $3);
    } |
    expr {
        $$ = new_list_node();
        append_ast_node(&$$->as.list, $1);
    } ;

var_id:
    id {
        if ($1->kind != SYM_VAR) {
            ERROR("'%s' is not a variable.", $1);
            YYABORT;
        }
        $$ = $1;
    } ;

id:
    ID {
        $$ = lookup_symbol($1);
        if ($$ == NULL) {
            ERROR("Undeclared identifier '%s'.", $1);
            YYABORT;
        }
        free($1);
    } ;

type:
    INTEGER_TYPE { $$ = TYPE_INT; } |
    REAL_TYPE  {
        ERROR("real type is not supported.");
        YYABORT;
    } |
    BOOLEAN_TYPE { $$ = TYPE_BOOL; } |
    STRING_TYPE  { $$ = TYPE_STR; } ;
%%

void yyerror(const char *msg) {
    fprintf(stderr, "%02d: %s\n", yylineno, msg);
}

int main(int argc, char** argv) {
    if (yyparse() == 0) {
        printf("\n/* Syntax & Semantic analysis completed successfully! */\n");
        return 0;
    }
    for (; current_scope; current_scope = current_scope->next) {
        print_symbol_table(current_scope);
    }
    return 1;
}

void print_expr_jasm(ASTNode* expr) {
    if (expr == NULL) return;
    if (!LOG_JASM) return;

    switch (expr->node_type) {
        case AST_CONST_INT:
            if (expr->as.expr.as.int_val >= -32768 && expr->as.expr.as.int_val <= 32767) {
                printf("    sipush %d\n", expr->as.expr.as.int_val);
            } else {
                printf("    ldc %d\n", expr->as.expr.as.int_val);
            }
            break;
        case AST_CONST_BOOL:
            printf("    %s\n", expr->as.expr.as.bool_val ? "iconst_1" : "iconst_0"); break;
        case AST_CONST_STR:
            printf("    ldc \"", expr->as.expr.as.str_val);
            for (char* c = expr->as.expr.as.str_val; *c != '\0'; c++) {
                if (*c == '"') printf("\\\"");
                else if (*c == '\'') printf("\\\'");
                else if (*c == '\\') printf("\\\\");
                else if (*c == '\n') printf("\\n");
                else if (*c == '\t') printf("\\t");
                else if (*c == '\r') printf("\\r");
                else printf("%c", *c);
            }
            printf("\"\n"); break;
        case AST_LOCAL_VAR:
            printf("    iload %d\n", expr->as.expr.as.local_var_index); break;
        case AST_GLOBAL_VAR:
            printf("    getstatic int %s.%s\n", program_id, expr->as.expr.as.global_var_name); break;
        case AST_INVOKE:
            for (ASTNode* arg = expr->as.expr.as.invoke.args.head; arg; arg = arg->next) {
                print_expr_jasm(arg);
            }
            printf("    invokestatic %s %s.%s(", type_to_jasm(expr->as.expr.data_type), program_id, expr->as.expr.as.invoke.name);
            for (ASTNode* arg = expr->as.expr.as.invoke.args.head; arg; arg = arg->next) {
                printf("%s", type_to_jasm(arg->as.expr.data_type));
                if (arg->next) printf(", ");
            }
            printf(")\n");
            break;
        case AST_BINARY_OP:
            print_expr_jasm(expr->as.expr.as.op.left);
            print_expr_jasm(expr->as.expr.as.op.right);
            int op = expr->as.expr.as.op.op;
            int is_cmp = op == EQ || op == NEQ || op == LT || op == LE || op == GT || op == GE;
            int label1 = label_counter;
            int label2 = label_counter + 1;
            if (is_cmp) {
                label_counter += 2;
                printf("    isub\n");
            }
            switch (expr->as.expr.as.op.op) {
                case ADD: printf("    iadd\n"); break;
                case SUB: printf("    isub\n"); break;
                case MUL: printf("    imul\n"); break;
                case DIV: printf("    idiv\n"); break;
                case MOD: printf("    irem\n"); break;
                case AND: printf("    iand\n"); break;
                case OR:  printf("    ior\n");  break;
                case EQ:  printf("    ifeq"); break;
                case NEQ: printf("    ifne"); break;
                case LT:  printf("    iflt"); break;
                case LE:  printf("    ifle"); break;
                case GT:  printf("    ifgt"); break;
                case GE:  printf("    ifge"); break;
            }
            if (is_cmp) {
                printf(" L%d\n", label1);
                printf("    iconst_0\n");
                printf("    goto L%d\n", label2);
                printf("L%d: nop\n", label1);
                printf("    iconst_1\n");
                printf("L%d: nop\n", label2);
            }
            break;
        case AST_UNARY_OP:
            print_expr_jasm(expr->as.expr.as.op.left);
            switch (expr->as.expr.as.op.op) {
                case NOT: printf("    iconst_m1\n    ixor\n"); break;
                case NEG: printf("    ineg\n"); break;
            }
            break;
    }
}