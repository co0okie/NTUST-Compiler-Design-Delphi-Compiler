%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "ast.h"

#define Reduce(l, r) if (LOG_TRACE) printf("/* %2d: %16s <= %-80s */\n", yylineno, l, r)
#define Trace(t)  if (LOG_TRACE) printf("/* %2d: %-100s */\n", yylineno, t)
int LOG_TRACE = 1;
int LOG_TABLE = 1;
int LOG_JASM = 0;

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

unsigned long hash_djb2(const char *str) {
    unsigned long hash = 5381;
    int c;
    while ((c = *str++))
        hash = ((hash << 5) + hash) + c;
    return hash;
}

void push_scope(int reset_local_index) {
    Scope* new_scope = (Scope*)malloc(sizeof(Scope));
    for (int i = 0; i < HASH_SIZE; i++) {
        new_scope->table[i] = NULL;
    }
    new_scope->order_head = NULL;
    new_scope->order_tail = NULL;
    new_scope->local_index = reset_local_index ? 0 : current_scope->local_index;
    new_scope->next = current_scope;
    current_scope = new_scope;
    Trace("Scope Pushed");
}

void print_symbol_table(Scope* scope) {
    printf("%2d: Scope Popped, Symbol Table:\n", yylineno);
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
}

void pop_scope() {
    if (current_scope == NULL) return;
    
    if (LOG_TABLE) print_symbol_table(current_scope);
    
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
            char msg[256];
            sprintf(msg, "Identifier '%s' is already declared.", name);
            yyerror(msg);
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
%}

%union {
    int ival;
    float fval;
    char* sval;
    int type_val;
    struct _ASTNode* ast_node; 
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
%type <ast_node> expr const_expr opt_expr_list expr_list id_list var_decl decl opt_decls opt_params params param opt_init id_opt_invoke opt_invoke boolean_expr

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
        if (LOG_JASM) printf("class %s {\n", $2);
        program_id = $2;
        push_scope(1);
    }
    opt_decls {
        for (Entry* curr = current_scope->order_head; curr != NULL; curr = curr->next_in_scope) {
            if (curr->kind != SYM_VAR) continue;
            curr->as.var.is_global = 1;
            if (!LOG_JASM) continue;
            printf("field static int %s", curr->name);
            if (curr->as.var.is_initialized) printf(" = %d", curr->as.var.val);
            printf("\n");
        }
    }
    opt_subprograms {
    }
    BEGIN_KW {
        if (LOG_JASM) {
            printf("  method public static void main(java.lang.String[])\n");
            printf("  max_stack 15\n");
            printf("  max_locals 15 {\n");
        }
    }
    opt_stmts 
    END ID DOT {
        if (strcmp($2, $13) != 0) {
            yyerror("Program end identifier does not match start identifier.");
            YYABORT;
        }
        pop_scope();
        free($2); free($13);
        if (LOG_JASM) {
            printf("    return\n");
            printf("  }\n");
            printf("}\n");
        }
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
        push_scope(1);
    }
    opt_params COLON type SEMICOLON {
        if ($6 == TYPE_STR) {
            yyerror("function of return type string is not supported.");
            YYABORT;
        }
        Entry* sym = lookup_symbol($2);
        if (sym != NULL) {
            sym->type = (DataType)$6;
            ParamNode** tail = &(sym->as.subprog.param_list);
            for (ASTNode* curr = $4->as.list.head; curr != NULL; curr = curr->next) {
                assert(curr->node_type == AST_PARAM);
                *tail = (ParamNode*)malloc(sizeof(ParamNode));
                (*tail)->type = curr->as.param.type;
                (*tail)->next = NULL;
                tail = &((*tail)->next);
            }
        }
    }
    opt_local_decls 
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        Reduce("func_decl", "FUNCTION ID opt_params : type ; opt_decls BEGIN stmts END ID ;");
        if (strcmp($2, $13) != 0) {
            yyerror("Function end identifier does not match.");
            YYABORT;
        }
        pop_scope();
        free($2); free($13);
        if ($4) free_ast($4);
    } ;

proc_decl:
    PROCEDURE ID  { 
        Entry* sym = insert_symbol($2, SYM_PROC, TYPE_VOID); 
        if (sym == NULL) YYABORT;
        push_scope(1);
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
    }
    opt_local_decls 
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        Reduce("proc_decl", "PROCEDURE ID opt_params ; opt_decls BEGIN stmts END ID ;");
        if (strcmp($2, $11) != 0) {
            yyerror("Procedure end identifier does not match.");
            YYABORT;
        }
        pop_scope();
        free($2); free($11);
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
            yyerror("string parameter is not supported.");
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

type:
    INTEGER_TYPE { $$ = TYPE_INT; } |
    REAL_TYPE  {
        yyerror("real type is not supported.");
        YYABORT;
    } |
    BOOLEAN_TYPE { $$ = TYPE_BOOL; } |
    STRING_TYPE  { $$ = TYPE_STR; } ;

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
    ID ASSIGN expr SEMICOLON {
        Reduce("simple_stmt", "ID := expr ;");
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char s[256]; sprintf(s, "Undeclared identifier '%s'.", $1); yyerror(s); YYABORT;
        }
        if (sym->kind == SYM_CONST) { yyerror("Cannot assign to constant."); YYABORT; }
        if (sym->kind == SYM_FUNC || sym->kind == SYM_PROC) { yyerror("Cannot assign to function/procedure."); YYABORT; }
        if (sym->type != $3->as.expr.data_type && $3->as.expr.data_type != TYPE_UNKNOWN && sym->type != TYPE_UNKNOWN) {
            yyerror("Type mismatch in assignment."); YYABORT;
        }
        free($1); free_ast($3);
    } |
    WRITE expr SEMICOLON {
        Reduce("simple_stmt", "WRITE expr ;");
        free_ast($2);
    } |
    WRITELN expr SEMICOLON {
        Reduce("simple_stmt", "WRITELN expr ;");
        free_ast($2);
    } |
    READ ID SEMICOLON {
        yyerror("read is not supported.");
        YYABORT;
    } |
    RETURN SEMICOLON {
        Reduce("simple_stmt", "RETURN ;");
    } |
    RETURN expr SEMICOLON {
        Reduce("simple_stmt", "RETURN expr ;");
        free_ast($2);
    } ;

block_stmt:
    BEGIN_KW {
        push_scope(0);
    }
    opt_local_decls stmts
    END SEMICOLON {
        Reduce("block_stmt", "BEGIN opt_decls stmts END ;");
        pop_scope(); 
    } ;

conditional_stmt:
    IF boolean_expr THEN stmt %prec LOWER_THAN_ELSE {
        Reduce("conditional_stmt", "IF boolean_expr THEN stmt");
        free_ast($2);
    } |
    IF boolean_expr THEN stmt ELSE stmt {
        Reduce("conditional_stmt", "IF boolean_expr THEN stmt ELSE stmt");
        free_ast($2);
    } ;

loop_stmt:
    REPEAT stmts UNTIL boolean_expr SEMICOLON {
        Reduce("loop_stmt", "REPEAT stmts UNTIL boolean_expr ;");
        free_ast($4);
    } |
    WHILE boolean_expr DO stmt {
        Reduce("loop_stmt", "WHILE boolean_expr DO stmt");
        free_ast($2);
    } |
    FOR ID ASSIGN expr TO expr {
        Entry* sym = lookup_symbol($2);
        if (sym == NULL) { yyerror("For-loop counter undeclared."); YYABORT; }
        if (sym->type != TYPE_INT) { yyerror("For-loop counter must be integer."); YYABORT; }
        if ($4->as.expr.data_type != TYPE_INT || $6->as.expr.data_type != TYPE_INT) {
            yyerror("For-loop bounds must be integer."); YYABORT;
        }
        free($2); free_ast($4); free_ast($6);
    } DO stmt {
        Reduce("loop_stmt", "FOR ID := expr TO expr DO stmt");
    } ;

procedure_invoke:
    id_opt_invoke SEMICOLON {
        Reduce("procedure_invoke", "id_invoke ;");
        if ($1->as.expr.data_type != TYPE_VOID && $1->as.expr.data_type != TYPE_UNKNOWN) {
            yyerror("Only procedures can be called as statements."); 
            YYABORT;
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
        Reduce("const_decl", "CONST ID = expr ;");
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
            yyerror("string variable is not supported.");
            YYABORT;
        }
        if ($5 && $4 != $5->as.expr.data_type) {
            yyerror("variable type does not match initializer type."); 
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
        yyerror("array is not supported.");
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
            yyerror("Const expression must be evaluated at compile time.");
            YYABORT;
        }
        $$ = $1;
    }

boolean_expr:
    expr {
        if ($1->as.expr.data_type != TYPE_BOOL && $1->as.expr.data_type != TYPE_UNKNOWN) {
            yyerror("Condition expression must be boolean.");
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
            yyerror("Procedure cannot be used in an expression."); 
            YYABORT;
        }
        $$ = $1;
    } |
    INT_CONST { $$ = new_expr_int_node($1); } |
    REAL_CONST {
        yyerror("real constants are not supported."); 
        YYABORT;
    } |
    STR_CONST { $$ = new_expr_str_node($1); free($1); } |
    TRUE_KW { $$ = new_expr_bool_node(1); } |
    FALSE_KW { $$ = new_expr_bool_node(0); } ;

/* -----------------------------------------------------
 * Invoke Engine: Handles Variable Resolution & Calling
 * ----------------------------------------------------- */
id_opt_invoke:
    ID opt_invoke {
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256]; sprintf(msg, "Undeclared identifier '%s'.", $1); yyerror(msg);
            YYABORT;
        }

        if ($2 == NULL) { /* Variable or parameterless call (no parentheses) */
            if (sym->kind == SYM_FUNC || sym->kind == SYM_PROC) {
                if (sym->as.subprog.param_list != NULL) {
                    char msg[256]; sprintf(msg, "Too few arguments in call to '%s'.", $1); yyerror(msg);
                    YYABORT;
                } else {
                    $$ = new_expr_invoke_node(sym->type, sym->name, new_list());
                }
            } else if (sym->kind == SYM_CONST) {
                $$ = sym->type == TYPE_INT ?
                    new_expr_int_node(sym->as.const_.val.int_val) :
                    sym->type == TYPE_BOOL ?
                    new_expr_bool_node(sym->as.const_.val.bool_val) :
                    new_expr_str_node(sym->as.const_.val.str_val);
            } else { // variable
                $$ = sym->as.var.is_global ?
                    new_expr_global_var_node($1, sym->type) :
                    new_expr_local_var_node(sym->as.var.index, sym->type);
            }
        } else { /* Call with parentheses */
            if (sym->kind != SYM_FUNC && sym->kind != SYM_PROC) {
                char msg[256]; sprintf(msg, "'%s' is not a function/procedure.", $1); yyerror(msg);
                YYABORT;
            } else {
                ASTNode* curr_arg = $2->as.list.head;
                ParamNode* curr_param = sym->as.subprog.param_list;
                int arg_index = 1;
                while (curr_param != NULL) {
                    if (curr_arg == NULL) {
                        char msg[256]; sprintf(msg, "Too few arguments in call to '%s'.", $1); yyerror(msg); YYABORT; break;
                    }
                    if (curr_param->type != curr_arg->as.expr.data_type && curr_arg->as.expr.data_type != TYPE_UNKNOWN) {
                        char msg[256]; sprintf(msg, "Argument %d of '%s' expects %s, but got %s.", arg_index, $1, type_to_string(curr_param->type), type_to_string(curr_arg->as.expr.data_type)); yyerror(msg); YYABORT;
                    }
                    curr_param = curr_param->next;
                    curr_arg = curr_arg->next;
                    arg_index++;
                }
                if (curr_param == NULL && curr_arg != NULL) {
                    char msg[256]; sprintf(msg, "Too many arguments in call to '%s'.", $1); yyerror(msg); YYABORT;
                }
                $$ = new_expr_invoke_node(sym->type, sym->name, $2->as.list);
            }
            free($2); // not free_ast, to keep expr_list alive
        }
        
        free($1);
    } ;

opt_invoke:
    LBRACK expr RBRACK {
        yyerror("array is not supported.");
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

%%

void yyerror(const char *msg) {
    fprintf(stderr, "%02d: Semantic Error: %s\n", yylineno, msg);
}

int main(int argc, char** argv) {
    if (LOG_JASM) {
        printf("/*----------------------------------------------------------------------------------------------------------*/\n");
        printf("/*                                              Java Assembly                                               */\n");
        printf("/*----------------------------------------------------------------------------------------------------------*/\n");
    }
    if (yyparse() == 0) {
        printf("\n=> Syntax & Semantic analysis completed successfully!\n");
        return 0;
    }
    for (; current_scope; current_scope = current_scope->next) {
        print_symbol_table(current_scope);
    }
    return 1;
}