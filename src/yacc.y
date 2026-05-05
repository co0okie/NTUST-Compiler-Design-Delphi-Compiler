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

typedef enum { 
    TYPE_INT, 
    TYPE_REAL, 
    TYPE_BOOL, 
    TYPE_STR, 
    TYPE_VOID,    /* For procedure */
    TYPE_ARRAY,   /* For array variable */
    TYPE_UNKNOWN 
} DataType;

/* 參數型別串列節點：取代原本固定長度的 param_types 陣列 */
typedef struct _ParamNode {
    DataType type;
    struct _ParamNode *next;
} ParamNode;

/* 定義 Symbol 的身分種類 */
typedef enum {
    SYM_VAR,        /* 一般變數 */
    SYM_CONST,      /* 常數 */
    SYM_ARRAY,      /* 陣列變數 */
    SYM_FUNC,       /* 函式 */
    SYM_PROC        /* 程序 */
} SymbolKind;

typedef struct _Entry {
    char name[MAX_ID_LEN];
    SymbolKind kind;         /* 取代原本的 is_const 與 is_function */
    DataType type;           /* 變數型別、常數型別，或函式的回傳型別 */
    
    /* 專屬屬性區 (Union 讓不同身分的欄位共用記憶體) */
    union {
        /* 1. 常數專屬資訊 */
        struct {
            union {
                int int_val;
                float real_val;
                int bool_val;
                char* str_val;
            } val;
        } const_;
        
        /* 2. 陣列專屬資訊 */
        struct {
            int start;
            int end;
            DataType element_type;
        } array;
        
        /* 3. 函式/程序專屬資訊 */
        struct {
            ParamNode* param_list;  /* 參數串列的開頭 */
        } subprog;
    } as;
    
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
            } else if (curr->kind == SYM_ARRAY) {
                printf("    %s: array [%d, %d] of %s\n", curr->name, curr->as.array.start, curr->as.array.end, type_to_string(curr->as.array.element_type));
            } else if (curr->kind == SYM_CONST) {
                /* 特別標註並印出常數的值 */
                printf("    %s: const %s ", curr->name, type_to_string(curr->type));
                if (curr->type == TYPE_INT) {
                    printf("%d\n", curr->as.const_.val.int_val);
                } else if (curr->type == TYPE_REAL) {
                    printf("%g\n", curr->as.const_.val.real_val); /* 使用 %g 去除尾數多餘的 0 */
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
            
            /* 釋放常數型別的字串記憶體 */
            if (curr->kind == SYM_CONST && curr->type == TYPE_STR && curr->as.const_.val.str_val != NULL) {
                free(curr->as.const_.val.str_val);
            }
            /* 釋放參數串列記憶體 */
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
    
    /* 根據身分類別初始化專屬記憶體區塊 */
    if (kind == SYM_ARRAY) {
        new_entry->as.array.start = 0;
        new_entry->as.array.end = 0;
        new_entry->as.array.element_type = TYPE_UNKNOWN;
    } else if (kind == SYM_FUNC || kind == SYM_PROC) {
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
 * Abstract Syntax Tree (AST) & Constant Folding
 *======================================================*/
typedef enum _NodeType {
    AST_ID,             /* 單一變數名稱 (未解析前，用於宣告列表) */
    AST_CONST_INT,      /* 編譯期可決定的整數常數 */
    AST_CONST_REAL,     /* 編譯期可決定的浮點數常數 */
    AST_CONST_BOOL,     /* 編譯期可決定的布林常數 */
    AST_CONST_STR,      /* 編譯期可決定的字串常數 */
    AST_RUNTIME_EXPR,   /* 編譯期未知數值，但具有 DataType 的 Runtime 表達式 */
    AST_INVOKE          /* Function 或 Procedure 呼叫節點標記 */
} NodeType;

typedef struct _ASTNode {
    NodeType node_type;
    DataType data_type;       /* 該節點推導出的回傳型別 */
    int is_const;             /* 擴充：一次性判斷是否為常數節點 */
    struct _ASTNode* next;    /* 用於 id_list 與 expr_list 的串接 */
    
    union {
        char id_name[MAX_ID_LEN]; 
        int int_val;              
        float real_val;           
        int bool_val;             
        char* str_val;            
    } as;
} ASTNode;

ASTNode* allocate_node(NodeType nt, DataType dt) {
    ASTNode* node = (ASTNode*)malloc(sizeof(ASTNode));
    node->node_type = nt;
    node->data_type = dt;
    /* 透過 NodeType 一次性賦予 is_const 旗標 */
    node->is_const = (nt == AST_CONST_INT || nt == AST_CONST_REAL || nt == AST_CONST_BOOL || nt == AST_CONST_STR);
    node->next = NULL;
    return node;
}

ASTNode* create_id_node(const char* name) {
    ASTNode* node = allocate_node(AST_ID, TYPE_UNKNOWN);
    strncpy(node->as.id_name, name, MAX_ID_LEN - 1);
    node->as.id_name[MAX_ID_LEN - 1] = '\0';
    return node;
}

ASTNode* create_int_node(int val) {
    ASTNode* node = allocate_node(AST_CONST_INT, TYPE_INT);
    node->as.int_val = val;
    return node;
}

ASTNode* create_real_node(float val) {
    ASTNode* node = allocate_node(AST_CONST_REAL, TYPE_REAL);
    node->as.real_val = val;
    return node;
}

ASTNode* create_bool_node(int val) {
    ASTNode* node = allocate_node(AST_CONST_BOOL, TYPE_BOOL);
    node->as.bool_val = val;
    return node;
}

ASTNode* create_str_node(const char* val) {
    ASTNode* node = allocate_node(AST_CONST_STR, TYPE_STR);
    node->as.str_val = strdup(val);
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
        if (node->node_type == AST_CONST_STR && node->as.str_val != NULL) {
            free(node->as.str_val);
        }
        free(node);
        node = next;
    }
}

ASTNode* evaluate_binary_op(int op, ASTNode* left, ASTNode* right);
ASTNode* evaluate_unary_op(int op, ASTNode* operand);

/* 參數比對機制 (已優化：雙串列齊步走，優雅判斷多寡與型別) */
void check_arguments(const char* func_name, Entry* sym, ASTNode* args) {
    if (sym == NULL) return;
    
    ASTNode* curr_arg = args;
    ParamNode* curr_param = sym->as.subprog.param_list;
    int arg_index = 1;
    
    while (curr_param != NULL) {
        /* 呼叫者提供的參數提早見底 (太少) */
        if (curr_arg == NULL) {
            char msg[256];
            sprintf(msg, "Too few arguments in call to '%s'.", func_name);
            yyerror(msg);
            return;
        }
        
        /* 檢查型別相容性 */
        if (curr_param->type != curr_arg->data_type && curr_arg->data_type != TYPE_UNKNOWN) {
            if (curr_param->type == TYPE_REAL && curr_arg->data_type == TYPE_INT) {
                printf("%02d: Semantic Warning: Implicit conversion from int to real in function argument.\n", yylineno);
            } else {
                char msg[256];
                sprintf(msg, "Argument %d of '%s' expects %s, but got %s.",
                        arg_index, func_name, type_to_string(curr_param->type), type_to_string(curr_arg->data_type));
                yyerror(msg);
            }
        }
        curr_param = curr_param->next;
        curr_arg = curr_arg->next;
        arg_index++;
    }
    
    /* 宣告定義的參數走完了，但呼叫者提供的參數還有剩 (太多) */
    if (curr_arg != NULL) {
        char msg[256];
        sprintf(msg, "Too many arguments in call to '%s'.", func_name);
        yyerror(msg);
        return;
    }
}

%}

%union {
    int ival;
    float fval;
    char* sval;
    int type_val; 
    struct _ASTNode* ast_node; /* 全面啟用統一的 AST 節點 */
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
%type <ast_node> expr opt_expr_list expr_list id_list opt_formal_args formal_args formal_arg opt_init id_eval opt_invoke

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
            yyerror("Program end identifier does not match start identifier.");
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
        if (!$4->is_const) {
            yyerror("Const expression must be evaluated at compile time.");
            YYABORT;
        }
        
        Entry* sym = insert_symbol($2, SYM_CONST, $4->data_type);
        if (sym != NULL) {
            if ($4->data_type == TYPE_INT) sym->as.const_.val.int_val = $4->as.int_val;
            else if ($4->data_type == TYPE_REAL) sym->as.const_.val.real_val = $4->as.real_val;
            else if ($4->data_type == TYPE_BOOL) sym->as.const_.val.bool_val = $4->as.bool_val;
            else if ($4->data_type == TYPE_STR) sym->as.const_.val.str_val = strdup($4->as.str_val);
        }
        free($2);
        free_ast($4);
    } ;

var_decl:
    VAR id_list COLON type opt_init SEMICOLON {
        Reduce("var_decl", "VAR id_list : type opt_init ;");
        ASTNode* curr = $2;
        while (curr != NULL) {
            insert_symbol(curr->as.id_name, SYM_VAR, (DataType)$4);
            curr = curr->next;
        }
        free_ast($2); 
        if ($5) free_ast($5);
    } |
    VAR id_list COLON ARRAY LBRACK INT_CONST COMMA INT_CONST RBRACK OF type SEMICOLON {
        Reduce("var_decl", "VAR id_list : ARRAY [ INT , INT ] OF type ;");
        ASTNode* curr = $2;
        while (curr != NULL) {
            Entry* sym = insert_symbol(curr->as.id_name, SYM_ARRAY, TYPE_ARRAY);
            if (sym != NULL) {
                sym->as.array.start = $6;
                sym->as.array.end = $8;
                sym->as.array.element_type = (DataType)$11;
            }
            curr = curr->next;
        }
        free_ast($2);
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
        insert_symbol($2, SYM_FUNC, TYPE_UNKNOWN);
        push_scope();
    }
    opt_formal_args COLON type SEMICOLON {
        Entry* sym = lookup_symbol($2);
        if (sym != NULL) {
            sym->type = (DataType)$6; 
            ASTNode* curr = $4;
            /* 透過指標的指標 (**tail) 來進行串列的末端新增，代碼會非常優雅 */
            ParamNode** tail = &(sym->as.subprog.param_list);
            while (curr != NULL) {
                *tail = (ParamNode*)malloc(sizeof(ParamNode));
                (*tail)->type = curr->data_type;
                (*tail)->next = NULL;
                tail = &((*tail)->next);
                
                curr = curr->next;
            }
        }
    }
    decls 
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        Reduce("func_decl", "FUNCTION ID opt_formal_args : type ; decls BEGIN stmts END ID ;");
        if (strcmp($2, $13) != 0) {
            yyerror("Function end identifier does not match.");
        }
        pop_scope();
        free($2); free($13);
        if ($4) free_ast($4);
    } ;

proc_decl:
    PROCEDURE ID  { 
        insert_symbol($2, SYM_PROC, TYPE_VOID); 
        push_scope(); 
    }
    opt_formal_args SEMICOLON {
        Entry* sym = lookup_symbol($2);
        if (sym != NULL) {
            ASTNode* curr = $4;
            ParamNode** tail = &(sym->as.subprog.param_list);
            while (curr != NULL) {
                *tail = (ParamNode*)malloc(sizeof(ParamNode));
                (*tail)->type = curr->data_type;
                (*tail)->next = NULL;
                tail = &((*tail)->next);
                
                curr = curr->next;
            }
        }
    }
    decls 
    BEGIN_KW 
    stmts 
    END ID SEMICOLON {
        Reduce("proc_decl", "PROCEDURE ID opt_formal_args : type ; decls BEGIN stmts END ID ;");
        if (strcmp($2, $11) != 0) {
            yyerror("Procedure end identifier does not match.");
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
        insert_symbol($1, SYM_VAR, (DataType)$3);
        $$ = create_id_node($1);
        $$->data_type = (DataType)$3;
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
    loop_stmt |
    procedure_invoke ;

/* 統一的 Subprogram & ID 分析引擎 */
id_eval:
    ID opt_invoke {
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256]; sprintf(msg, "Undeclared identifier '%s'.", $1); yyerror(msg);
            $$ = create_runtime_node(TYPE_UNKNOWN);
        } else if (sym->kind == SYM_FUNC || sym->kind == SYM_PROC) {
            /* 若定義為函式或程序，取出傳遞上來的參數名單 (略過 head dummy 節點) */
            ASTNode* args = ($2 != NULL) ? $2->next : NULL;
            check_arguments($1, sym, args);
            $$ = create_invoke_node(sym->type);
        } else {
            /* 一般變數或常數 */
            if ($2 != NULL) {
                char msg[256]; sprintf(msg, "'%s' is not a function/procedure.", $1); yyerror(msg);
                $$ = create_runtime_node(TYPE_UNKNOWN);
            } else {
                /* 原地解壓縮常數 */
                if (sym->kind == SYM_CONST) {
                    if (sym->type == TYPE_INT) $$ = create_int_node(sym->as.const_.val.int_val);
                    else if (sym->type == TYPE_REAL) $$ = create_real_node(sym->as.const_.val.real_val);
                    else if (sym->type == TYPE_BOOL) $$ = create_bool_node(sym->as.const_.val.bool_val);
                    else if (sym->type == TYPE_STR) $$ = create_str_node(sym->as.const_.val.str_val);
                    else $$ = create_runtime_node(sym->type);
                } else {
                    $$ = create_runtime_node(sym->type);
                }
            }
        }
        /* 釋放參數串列與 dummy 節點的記憶體 */
        if ($2) {
            ASTNode* args = $2->next;
            free($2);
            free_ast(args);
        }
        free($1);
    } ;

opt_invoke:
    LPAREN opt_expr_list RPAREN {
        /* 使用一個 dummy 的 AST_INVOKE 節點作為 Head */
        ASTNode* head = allocate_node(AST_INVOKE, TYPE_UNKNOWN);
        head->next = $2;
        $$ = head;
    } |
    /* empty */ { $$ = NULL; } ;

procedure_invoke:
    id_eval SEMICOLON {
        Reduce("procedure_invoke", "id_eval ;");
        if ($1->data_type != TYPE_VOID && $1->data_type != TYPE_UNKNOWN) {
            yyerror("Only procedures can be called as statements.");
        }
        free_ast($1);
    } ;

simple_stmt:
    ID ASSIGN expr SEMICOLON {
        Reduce("simple_stmt", "ID := expr ;");
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256]; sprintf(msg, "Undeclared identifier '%s'.", $1); yyerror(msg);
        } else if (sym->kind == SYM_CONST) {
            char msg[256]; sprintf(msg, "Cannot assign to constant '%s'.", $1); yyerror(msg);
        } else if (sym->type != $3->data_type && $3->data_type != TYPE_UNKNOWN) {
            if (sym->type == TYPE_REAL && $3->data_type == TYPE_INT) {
                printf("%02d: Semantic Warning: Implicit conversion from int to real in assignment.\n", yylineno);
            } else {
                char msg[256];
                sprintf(msg, "Cannot assign expression of type %s to '%s' of type %s.", type_to_string($3->data_type), $1, type_to_string(sym->type));
                yyerror(msg);
            }
        }
        free($1); free_ast($3);
    } |
    ID LBRACK expr RBRACK ASSIGN expr SEMICOLON { 
        Reduce("simple_stmt", "ID [ expr ] := expr ;");
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256]; sprintf(msg, "Undeclared identifier '%s'.", $1); yyerror(msg);
        } else if (sym->kind != SYM_ARRAY) {
            char msg[256]; sprintf(msg, "'%s' is not an array.", $1); yyerror(msg);
        } else {
            if ($3->data_type != TYPE_INT && $3->data_type != TYPE_UNKNOWN) {
                char msg[256]; sprintf(msg, "Array index must be integer, got %s.", type_to_string($3->data_type)); yyerror(msg);
            }
            if (sym->as.array.element_type != $6->data_type && $6->data_type != TYPE_UNKNOWN) {
                if (sym->as.array.element_type == TYPE_REAL && $6->data_type == TYPE_INT) {
                    printf("%02d: Semantic Warning: Implicit conversion from int to real in array assignment.\n", yylineno);
                } else {
                    char msg[256]; sprintf(msg, "Cannot assign expression of type %s to array element of type %s.", type_to_string($6->data_type), type_to_string(sym->as.array.element_type)); yyerror(msg);
                }
            }
        }
        free($1); free_ast($3); free_ast($6);
    } |
    WRITE expr SEMICOLON { free_ast($2); } |
    WRITELN expr SEMICOLON { free_ast($2); } |
    READ ID SEMICOLON { free($2); } |
    RETURN SEMICOLON |
    RETURN expr SEMICOLON { free_ast($2); } ;

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

conditional_stmt:
    IF expr THEN stmt %prec LOWER_THAN_ELSE { free_ast($2); } |
    IF expr THEN stmt ELSE stmt { free_ast($2); } ;

loop_stmt:
    REPEAT stmts UNTIL expr SEMICOLON { free_ast($4); } |
    WHILE expr DO stmt { free_ast($2); } |
    FOR ID ASSIGN expr TO expr DO stmt {
        Entry* sym = lookup_symbol($2);
        if (sym == NULL) yyerror("For-loop counter undeclared.");
        free($2); free_ast($4); free_ast($6);
    } ;

/*=========================
 * Expressions
 *=========================*/
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
    id_eval {
        if ($1->data_type == TYPE_VOID) {
            yyerror("Procedure cannot be used in an expression.");
            $$ = create_runtime_node(TYPE_UNKNOWN);
            free_ast($1);
        } else {
            $$ = $1;
        }
    } |
    ID LBRACK expr RBRACK { 
        Entry* sym = lookup_symbol($1);
        if (sym == NULL) {
            char msg[256]; sprintf(msg, "Undeclared identifier '%s'.", $1); yyerror(msg);
            $$ = create_runtime_node(TYPE_UNKNOWN);
        } else if (sym->kind != SYM_ARRAY) {
            char msg[256]; sprintf(msg, "'%s' is not an array.", $1); yyerror(msg);
            $$ = create_runtime_node(TYPE_UNKNOWN);
        } else {
            if ($3->data_type != TYPE_INT && $3->data_type != TYPE_UNKNOWN) {
                char msg[256]; sprintf(msg, "Array index must be integer, got %s.", type_to_string($3->data_type)); yyerror(msg);
            }
            $$ = create_runtime_node(sym->as.array.element_type);
        }
        free($1); free_ast($3);
    } |
    INT_CONST { $$ = create_int_node($1); } |
    REAL_CONST { $$ = create_real_node($1); } |
    STR_CONST { $$ = create_str_node($1); free($1); } |
    TRUE_KW { $$ = create_bool_node(1); } |
    FALSE_KW { $$ = create_bool_node(0); } ;

%%

void yyerror(const char *msg) {
    fprintf(stderr, "%02d: Semantic Error: %s\n", yylineno, msg);
    error_count++;
}

int main(int argc, char** argv) {
    if (yyparse() == 0 && error_count == 0) {
        printf("\n=> Syntax & Semantic analysis completed successfully!\n");
        return 0;
    } else {
        printf("\n=> Parsing failed. Total errors: %d\n", error_count);
        return 1;
    }
}

ASTNode* evaluate_binary_op(int op, ASTNode* left, ASTNode* right) {
    if (left->data_type == TYPE_STR || right->data_type == TYPE_STR) {
        yyerror("String operations are not supported.");
        return NULL;
    }
    
    /* 確定推導後的型別 */
    DataType out_type = TYPE_INT;
    if (left->data_type == TYPE_REAL || right->data_type == TYPE_REAL) {
        out_type = TYPE_REAL;
    }
    
    /* 依據 Token 動態調整型別 */
    if (op == DIV) {
        out_type = TYPE_REAL;
    }
    if (op == OR || op == AND || op == EQ || op == NEQ || op == LT || op == LE || op == GT || op == GE) {
        out_type = TYPE_BOOL;
    }
    
    /* 檢查是否能進行 Compile-time Constant Folding */
    if (!(left->is_const && right->is_const)) {
        /* 若涉及變數，直接印 Warning 後回傳 Runtime 型別 */
        if (out_type == TYPE_REAL && (left->data_type == TYPE_INT || right->data_type == TYPE_INT)) {
            printf("%02d: Semantic Warning: Implicit conversion from int to real.\n", yylineno);
        }
        free_ast(left); free_ast(right);
        return create_runtime_node(out_type);
    }
    
    /* 正式執行 Constant Folding */
    float l_val = (left->node_type == AST_CONST_INT) ? left->as.int_val :
                  (left->node_type == AST_CONST_REAL) ? left->as.real_val : left->as.bool_val;
    float r_val = (right->node_type == AST_CONST_INT) ? right->as.int_val :
                  (right->node_type == AST_CONST_REAL) ? right->as.real_val : right->as.bool_val;
                  
    if (out_type == TYPE_REAL && (left->node_type == AST_CONST_INT || right->node_type == AST_CONST_INT)) {
        printf("%02d: Semantic Warning: Implicit conversion from int to real.\n", yylineno);
    }

    ASTNode* result = NULL;
    switch (op) {
        case ADD: result = (out_type == TYPE_REAL) ? create_real_node(l_val + r_val) : create_int_node((int)l_val + (int)r_val); break;
        case SUB: result = (out_type == TYPE_REAL) ? create_real_node(l_val - r_val) : create_int_node((int)l_val - (int)r_val); break;
        case MUL: result = (out_type == TYPE_REAL) ? create_real_node(l_val * r_val) : create_int_node((int)l_val * (int)r_val); break;
        case DIV: 
            if (r_val == 0) { yyerror("Division by zero."); return NULL; }
            result = create_real_node(l_val / r_val); break;
        case MOD: 
            if ((int)r_val == 0) { yyerror("Division by zero."); return NULL; }
            result = create_int_node((int)l_val % (int)r_val); break;
        case EQ:  result = create_bool_node(l_val == r_val); break;
        case NEQ: result = create_bool_node(l_val != r_val); break;
        case LT:  result = create_bool_node(l_val < r_val); break;
        case LE:  result = create_bool_node(l_val <= r_val); break;
        case GT:  result = create_bool_node(l_val > r_val); break;
        case GE:  result = create_bool_node(l_val >= r_val); break;
        case AND: result = create_bool_node((int)l_val && (int)r_val); break;
        case OR:  result = create_bool_node((int)l_val || (int)r_val); break;
    }
    
    free_ast(left); free_ast(right);
    return result ? result : create_runtime_node(out_type);
}

ASTNode* evaluate_unary_op(int op, ASTNode* operand) {
    if (operand->data_type == TYPE_STR) {
        yyerror("String operations are not supported.");
        return NULL;
    }
    
    if (!operand->is_const) {
        DataType dt = operand->data_type;
        free_ast(operand);
        return create_runtime_node(dt);
    }
    
    ASTNode* result = NULL;
    if (op == SUB) { /* Unary Minus 與 SUB 共用 Token */
        if (operand->node_type == AST_CONST_INT) result = create_int_node(-operand->as.int_val);
        else if (operand->node_type == AST_CONST_REAL) result = create_real_node(-operand->as.real_val);
    } else if (op == NOT) {
        int val = (operand->node_type == AST_CONST_INT) ? operand->as.int_val :
                  (operand->node_type == AST_CONST_REAL) ? operand->as.real_val : operand->as.bool_val;
        result = create_bool_node(!val);
    }
    
    free_ast(operand);
    return result ? result : create_runtime_node(TYPE_INT);
}