%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define Reduce(l, r) if (LOG_TRACE) printf("/* %2d: %16s <= %-80s */\n", yylineno, l, r)
#define Trace(t)  if (LOG_TRACE) printf("/* %2d: %-100s */\n", yylineno, t)
int LOG_TRACE = 0;
int LOG_TABLE = 0;

extern int yylineno;
extern int yylex();
void yyerror(const char *msg);

/*======================================================
 * Semantic Analysis: Symbol Table & Scope Management
 *======================================================*/
#define HASH_SIZE 211
#define MAX_ID_LEN 50

typedef enum { 
    TYPE_INT, 
    TYPE_BOOL, 
    TYPE_STR, 
    TYPE_VOID, 
    TYPE_UNKNOWN 
} DataType;

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
    char name[MAX_ID_LEN];
    SymbolKind kind;         
    DataType type;           
    
    union {
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
    Entry* order_head;       
    Entry* order_tail;       
    struct _Scope *next;
} Scope;

Scope* current_scope = NULL;

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
    
    if (LOG_TABLE) {
        printf("%2d: Scope Popped, Symbol Table:\n", yylineno);
        Entry* curr = current_scope->order_head;
        while (curr != NULL) {
            if (curr->kind == SYM_PROC || curr->kind == SYM_FUNC) {
                printf("    %s: %s(", curr->name, curr->kind == SYM_PROC ? "procedure" : "function");
                ParamNode* pnode = curr->as.subprog.param_list;
                while (pnode != NULL) {
                    printf("%s%s", type_to_string(pnode->type), pnode->next ? ", " : "");
                    pnode = pnode->next;
                }
                if (curr->kind == SYM_FUNC) {
                    printf("): %s\n", type_to_string(curr->type));
                } else {
                    printf(")\n");
                }
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
            } else {
                printf("    %s: %s\n", curr->name, type_to_string(curr->type));
            }
            curr = curr->next_in_scope;
        }
    }
    
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
    strncpy(new_entry->name, name, MAX_ID_LEN - 1);
    new_entry->name[MAX_ID_LEN - 1] = '\0';
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

/*======================================================
 * Abstract Syntax Tree (AST)
 *======================================================*/
typedef enum _NodeType {
    AST_ID,             
    AST_CONST_INT,      
    AST_CONST_BOOL,     
    AST_CONST_STR,      
    AST_RUNTIME_EXPR,   
    AST_INVOKE
} NodeType;

typedef struct _ASTNode {
    NodeType node_type;
    struct _ASTNode* next;    
    
    union {
        struct {
            DataType data_type;       
            int is_const;             
            char original_id[MAX_ID_LEN]; 
            
            union {
                int int_val;              
                int bool_val;             
                char* str_val;            
            } attr;
        } expr;
        
        struct {
        } stmt;
        
        struct {
        } decl;
        
    } as;
} ASTNode;

ASTNode* allocate_node(NodeType nt, DataType dt) {
    ASTNode* node = (ASTNode*)malloc(sizeof(ASTNode));
    node->node_type = nt;
    node->next = NULL;
    node->as.expr.data_type = dt;
    node->as.expr.is_const = (nt == AST_CONST_INT || nt == AST_CONST_BOOL || nt == AST_CONST_STR);
    node->as.expr.original_id[0] = '\0';
    return node;
}

ASTNode* create_id_node(const char* name) {
    ASTNode* node = allocate_node(AST_ID, TYPE_UNKNOWN);
    strncpy(node->as.expr.original_id, name, MAX_ID_LEN - 1);
    node->as.expr.original_id[MAX_ID_LEN - 1] = '\0';
    return node;
}

ASTNode* create_int_node(int val) {
    ASTNode* node = allocate_node(AST_CONST_INT, TYPE_INT);
    node->as.expr.attr.int_val = val;
    return node;
}

ASTNode* create_bool_node(int val) {
    ASTNode* node = allocate_node(AST_CONST_BOOL, TYPE_BOOL);
    node->as.expr.attr.bool_val = val;
    return node;
}

ASTNode* create_str_node(const char* val) {
    ASTNode* node = allocate_node(AST_CONST_STR, TYPE_STR);
    node->as.expr.attr.str_val = strdup(val);
    return node;
}

ASTNode* create_runtime_node(DataType dt) {
    return allocate_node(AST_RUNTIME_EXPR, dt);
}

ASTNode* create_invoke_node(DataType dt) {
    return allocate_node(AST_INVOKE, dt);
}

void append_ast_node(ASTNode* list, ASTNode* node) {
    if (!list || !node) return;
    while (list->next != NULL) {
        list = list->next;
    }
    list->next = node;
}

void free_ast(ASTNode* node) {
    while (node != NULL) {
        ASTNode* next = node->next;
        if (node->node_type == AST_CONST_STR && node->as.expr.attr.str_val != NULL) {
            free(node->as.expr.attr.str_val);
        }
        free(node);
        node = next;
    }
}

ASTNode* evaluate_binary_op(int op, ASTNode* left, ASTNode* right);
ASTNode* evaluate_unary_op(int op, ASTNode* operand);

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
%type <ast_node> expr opt_expr_list expr_list id_list opt_formal_args formal_args formal_arg opt_init id_opt_invoke opt_invoke boolean_expr

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

program:
    PROGRAM ID SEMICOLON {
        push_scope(); 
    }
    opt_decls 
    opt_subprograms 
    BEGIN_KW 
    opt_stmts 
    END ID DOT {
        if (strcmp($2, $10) != 0) {
            yyerror("Program end identifier does not match start identifier.");
            YYABORT;
        }
        pop_scope();
        free($2); free($10);
        Reduce("program", "PROGRAM ID ; opt_decls opt_subprograms BEGIN opt_stmts END ID .");
    } ;

opt_decls:
    opt_decls decl |
    /* empty */ ;

decl:
    const_decl |
    var_decl ;

const_decl:
    CONST ID EQ expr SEMICOLON {
        Reduce("const_decl", "CONST ID = expr ;");
        if (!$4->as.expr.is_const) {
            yyerror("Const expression must be evaluated at compile time.");
            YYABORT;
        }
        
        Entry* sym = insert_symbol($2, SYM_CONST, $4->as.expr.data_type);
        if (sym == NULL) YYABORT;
        if ($4->as.expr.data_type == TYPE_INT) sym->as.const_.val.int_val = $4->as.expr.attr.int_val;
        else if ($4->as.expr.data_type == TYPE_BOOL) sym->as.const_.val.bool_val = $4->as.expr.attr.bool_val;
        else if ($4->as.expr.data_type == TYPE_STR) sym->as.const_.val.str_val = strdup($4->as.expr.attr.str_val);
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
        ASTNode* curr = $2;
        while (curr != NULL) {
            Entry* sym = insert_symbol(curr->as.expr.original_id, SYM_VAR, (DataType)$4);
            if (sym == NULL) YYABORT;
            curr = curr->next;
        }
        free_ast($2);
        if ($5) free_ast($5);
    } |
    VAR id_list COLON ARRAY LBRACK INT_CONST COMMA INT_CONST RBRACK OF type SEMICOLON {
        yyerror("array is not supported.");
        YYABORT;
    } ;

id_list:
    id_list COMMA ID {
        ASTNode* node = create_id_node($3);
        $$ = $1;
        append_ast_node($$, node);
        free($3); 
    } |
    ID {
        $$ = create_id_node($1);
        free($1);
    } ;

opt_init:
    EQ expr { $$ = $2; } |
    /* empty */ { $$ = NULL; } ;

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
        push_scope();
    }
    opt_formal_args COLON type SEMICOLON {
        Entry* sym = lookup_symbol($2);
        if (sym != NULL) {
            sym->type = (DataType)$6; 
            ASTNode* curr = $4;
            ParamNode** tail = &(sym->as.subprog.param_list);
            while (curr != NULL) {
                *tail = (ParamNode*)malloc(sizeof(ParamNode));
                (*tail)->type = curr->as.expr.data_type;
                (*tail)->next = NULL;
                tail = &((*tail)->next);
                
                curr = curr->next;
            }
        }
    }
    opt_decls 
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        Reduce("func_decl", "FUNCTION ID opt_formal_args : type ; opt_decls BEGIN stmts END ID ;");
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
        push_scope(); 
    }
    opt_formal_args SEMICOLON {
        Entry* sym = lookup_symbol($2);
        if (sym != NULL) {
            ASTNode* curr = $4;
            ParamNode** tail = &(sym->as.subprog.param_list);
            while (curr != NULL) {
                *tail = (ParamNode*)malloc(sizeof(ParamNode));
                (*tail)->type = curr->as.expr.data_type;
                (*tail)->next = NULL;
                tail = &((*tail)->next);
                
                curr = curr->next;
            }
        }
    }
    opt_decls 
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        Reduce("proc_decl", "PROCEDURE ID opt_formal_args ; opt_decls BEGIN stmts END ID ;");
        if (strcmp($2, $11) != 0) {
            yyerror("Procedure end identifier does not match.");
            YYABORT;
        }
        pop_scope();
        free($2); free($11);
        if ($4) free_ast($4);
    } ;

opt_formal_args:
    LPAREN formal_args RPAREN { $$ = $2; } |
    /* empty */               { $$ = NULL; } ;

formal_args:
    formal_args COMMA formal_arg {
        $$ = $1;
        append_ast_node($$, $3);
    } |
    formal_arg {
        $$ = $1;
    } ;

formal_arg:
    ID COLON type {
        Reduce("formal_arg", "ID : type");
        Entry* sym = insert_symbol($1, SYM_VAR, (DataType)$3);
        if (sym == NULL) YYABORT;
        $$ = create_id_node($1);
        $$->as.expr.data_type = (DataType)$3;
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
        if (sym == NULL) { yyerror("Undeclared identifier."); YYABORT; }
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
        push_scope(); 
    }
    opt_decls stmts
    END SEMICOLON {
        Reduce("block_stmt", "BEGIN opt_decls stmts END ;");
        pop_scope(); 
    } ;

boolean_expr:
    expr {
        if ($1->as.expr.data_type != TYPE_BOOL && $1->as.expr.data_type != TYPE_UNKNOWN) {
            yyerror("Condition expression must be boolean.");
            YYABORT;
        }
        $$ = $1;
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
    FOR ID ASSIGN expr TO expr DO stmt {
        Reduce("loop_stmt", "FOR ID := expr TO expr DO stmt");
        Entry* sym = lookup_symbol($2);
        if (sym == NULL) { yyerror("For-loop counter undeclared."); YYABORT; }
        if (sym->type != TYPE_INT) { yyerror("For-loop counter must be integer."); YYABORT; }
        if ($4->as.expr.data_type != TYPE_INT || $6->as.expr.data_type != TYPE_INT) {
            yyerror("For-loop bounds must be integer."); YYABORT;
        }
        free($2); free_ast($4); free_ast($6);
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

expr:
    expr OR expr   { $$ = evaluate_binary_op(OR, $1, $3); if (!$$) YYABORT; } |
    expr AND expr  { $$ = evaluate_binary_op(AND, $1, $3); if (!$$) YYABORT; } |
    NOT expr       { $$ = evaluate_unary_op(NOT, $2); if (!$$) YYABORT; } |
    expr EQ expr   { $$ = evaluate_binary_op(EQ, $1, $3); if (!$$) YYABORT; } |
    expr NEQ expr  { $$ = evaluate_binary_op(NEQ, $1, $3); if (!$$) YYABORT; } |
    expr LT expr   { $$ = evaluate_binary_op(LT, $1, $3); if (!$$) YYABORT; } |
    expr LE expr   { $$ = evaluate_binary_op(LE, $1, $3); if (!$$) YYABORT; } |
    expr GT expr   { $$ = evaluate_binary_op(GT, $1, $3); if (!$$) YYABORT; } |
    expr GE expr   { $$ = evaluate_binary_op(GE, $1, $3); if (!$$) YYABORT; } |
    expr ADD expr  { $$ = evaluate_binary_op(ADD, $1, $3); if (!$$) YYABORT; } |
    expr SUB expr  { $$ = evaluate_binary_op(SUB, $1, $3); if (!$$) YYABORT; } |
    expr MUL expr  { $$ = evaluate_binary_op(MUL, $1, $3); if (!$$) YYABORT; } |
    expr DIV expr  { $$ = evaluate_binary_op(DIV, $1, $3); if (!$$) YYABORT; } |
    expr MOD expr  { $$ = evaluate_binary_op(MOD, $1, $3); if (!$$) YYABORT; } |
    SUB expr %prec UMINUS { $$ = evaluate_unary_op(SUB, $2); if (!$$) YYABORT; } |
    LPAREN expr RPAREN    { $$ = $2; } |
    id_opt_invoke {
        if ($1->as.expr.data_type == TYPE_VOID) {
            yyerror("Procedure cannot be used in an expression."); 
            YYABORT;
        }
        $$ = $1;
    } |
    INT_CONST { $$ = create_int_node($1); } |
    REAL_CONST {
        yyerror("real constants are not supported."); 
        YYABORT;
    } |
    STR_CONST { $$ = create_str_node($1); free($1); } |
    TRUE_KW { $$ = create_bool_node(1); } |
    FALSE_KW { $$ = create_bool_node(0); } ;

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
                    $$ = create_invoke_node(sym->type);
                }
            } else if (sym->kind == SYM_CONST) {
                if (sym->type == TYPE_INT) $$ = create_int_node(sym->as.const_.val.int_val);
                else if (sym->type == TYPE_BOOL) $$ = create_bool_node(sym->as.const_.val.bool_val);
                else if (sym->type == TYPE_STR) $$ = create_str_node(sym->as.const_.val.str_val);
                else $$ = create_runtime_node(sym->type);
            } else {
                $$ = create_runtime_node(sym->type);
            }
        } else { /* Call with parentheses */
            ASTNode* args = $2->next;
            if (sym->kind != SYM_FUNC && sym->kind != SYM_PROC) {
                char msg[256]; sprintf(msg, "'%s' is not a function/procedure.", $1); yyerror(msg);
                YYABORT;
            } else {
                ASTNode* curr_arg = args;
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
                $$ = create_invoke_node(sym->type);
            }
        }
        
        if ($2) {
            ASTNode* inner = $2->next;
            free($2);
            free_ast(inner);
        }
        
        strncpy($$->as.expr.original_id, $1, MAX_ID_LEN - 1);
        $$->as.expr.original_id[MAX_ID_LEN - 1] = '\0';
        free($1);
    } ;

opt_invoke:
    LBRACK expr RBRACK {
        yyerror("array is not supported.");
        YYABORT;
    } |
    LPAREN opt_expr_list RPAREN {
        ASTNode* head = allocate_node(AST_INVOKE, TYPE_UNKNOWN);
        head->next = $2;
        $$ = head;
    } |
    /* empty */ { $$ = NULL; } ;

opt_expr_list:
    expr_list   { $$ = $1; } |
    /* empty */ { $$ = NULL; } ;

expr_list:
    expr_list COMMA expr {
        $$ = $1;
        append_ast_node($$, $3);
    } |
    expr {
        $$ = $1;
    } ;

%%

void yyerror(const char *msg) {
    fprintf(stderr, "%02d: Semantic Error: %s\n", yylineno, msg);
}

int main(int argc, char** argv) {
    printf("/*----------------------------------------------------------------------------------------------------------*/\n");
    printf("/*                                              Java Assembly                                               */\n");
    printf("/*----------------------------------------------------------------------------------------------------------*/\n");
    if (yyparse() == 0) {
        printf("\n=> Syntax & Semantic analysis completed successfully!\n");
        return 0;
    }
    return 1;
}

ASTNode* evaluate_binary_op(int op, ASTNode* left, ASTNode* right) {
    if (left->as.expr.data_type == TYPE_STR || right->as.expr.data_type == TYPE_STR) {
        yyerror("String operations are not supported.");
        return NULL;
    }
    
    if (left->as.expr.data_type != right->as.expr.data_type && left->as.expr.data_type != TYPE_UNKNOWN && right->as.expr.data_type != TYPE_UNKNOWN) {
        yyerror("Type mismatch: operands must have the same type.");
        return NULL;
    }
    
    DataType out_type = TYPE_INT; /* Default */
    switch (op) {
        case ADD: case SUB: case MUL: case DIV: case MOD:
            out_type = TYPE_INT;
            break;
        case EQ: case NEQ: case LT: case LE: case GT: case GE:
            out_type = TYPE_BOOL;
            break;
        case AND: case OR:
            out_type = left->as.expr.data_type; /* Logical operation result type matches operands */
            break;
    }
    
    if (!(left->as.expr.is_const && right->as.expr.is_const)) {
        free_ast(left); free_ast(right);
        return create_runtime_node(out_type);
    }
    
    int l_val = (left->node_type == AST_CONST_INT) ? left->as.expr.attr.int_val : left->as.expr.attr.bool_val;
    int r_val = (right->node_type == AST_CONST_INT) ? right->as.expr.attr.int_val : right->as.expr.attr.bool_val;
                  
    ASTNode* result = NULL;
    switch (op) {
        case ADD: result = create_int_node(l_val + r_val); break;
        case SUB: result = create_int_node(l_val - r_val); break;
        case MUL: result = create_int_node(l_val * r_val); break;
        case DIV: 
            if (r_val == 0) { yyerror("Division by zero."); return NULL; }
            result = create_int_node(l_val / r_val); break;
        case MOD: 
            if (r_val == 0) { yyerror("Division by zero."); return NULL; }
            result = create_int_node(l_val % r_val); break;
        case EQ:  result = create_bool_node(l_val == r_val); break;
        case NEQ: result = create_bool_node(l_val != r_val); break;
        case LT:  result = create_bool_node(l_val < r_val); break;
        case LE:  result = create_bool_node(l_val <= r_val); break;
        case GT:  result = create_bool_node(l_val > r_val); break;
        case GE:  result = create_bool_node(l_val >= r_val); break;
        case AND: 
            if (out_type == TYPE_BOOL) result = create_bool_node(l_val && r_val); 
            else result = create_int_node(l_val & r_val); 
            break;
        case OR:  
            if (out_type == TYPE_BOOL) result = create_bool_node(l_val || r_val); 
            else result = create_int_node(l_val | r_val);
            break;
    }
    
    free_ast(left); free_ast(right);
    return result ? result : create_runtime_node(out_type);
}

ASTNode* evaluate_unary_op(int op, ASTNode* operand) {
    if (operand->as.expr.data_type == TYPE_STR) {
        yyerror("String operations are not supported.");
        return NULL;
    }
    
    DataType out_type = operand->as.expr.data_type;
    
    if (!operand->as.expr.is_const) {
        free_ast(operand);
        return create_runtime_node(out_type);
    }
    
    ASTNode* result = NULL;
    int val = (operand->node_type == AST_CONST_INT) ? operand->as.expr.attr.int_val : operand->as.expr.attr.bool_val;
    
    if (op == SUB) { 
        result = create_int_node(-val);
    } else if (op == NOT) {
        if (out_type == TYPE_BOOL) result = create_bool_node(!val);
        else result = create_int_node(~val); /* Bitwise NOT for integers */
    }
    
    free_ast(operand);
    return result ? result : create_runtime_node(out_type);
}