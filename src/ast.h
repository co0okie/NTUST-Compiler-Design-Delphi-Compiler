#ifndef AST_H
#define AST_H

#define MAX_ID_LEN 50

typedef enum { 
    TYPE_INT, 
    TYPE_BOOL, 
    TYPE_STR, 
    TYPE_VOID, 
    TYPE_UNKNOWN 
} DataType;

typedef enum _NodeType {
    AST_ID,
    AST_PARAM,
    AST_CONST_INT,
    AST_CONST_BOOL,
    AST_CONST_STR,
    AST_LOCAL_VAR,
    AST_GLOBAL_VAR,
    AST_INVOKE,
    AST_BINARY_OP,
    AST_UNARY_OP,
    AST_LIST,
} NodeType;

struct _ASTNode;
typedef struct _NodeList {
    struct _ASTNode* head;
    struct _ASTNode* tail;
} NodeList;

typedef struct _ASTNode {
    NodeType node_type;
    struct _ASTNode* next;
    
    union {
        struct {
            DataType data_type;
            int is_const;
            
            union {
                // AST_CONST_INT
                int int_val;

                // AST_CONST_BOOL
                int bool_val;

                // AST_CONST_STR
                char* str_val;

                // AST_LOCAL_VAR
                int local_var_index;

                // AST_GLOBAL_VAR
                char* global_var_name;

                // AST_BINARY_OP, AST_UNARY_OP
                struct {
                    int op; // ADD, SUB, MUL, DIV, MOD, ...
                    struct _ASTNode* left;
                    struct _ASTNode* right; // NULL for unary ops
                } op;

                // AST_INVOKE
                struct {
                    char* name;
                    NodeList args;
                } invoke;
            } as;
        } expr;

        NodeList list;

        char* id;

        struct {
            char* id;
            DataType type;
        } param;
    } as;
} ASTNode;

ASTNode* new_list_node();
ASTNode* new_id_node(const char* id);
ASTNode* new_param_node(const char* id, DataType type);
ASTNode* new_expr_int_node(int val);
ASTNode* new_expr_bool_node(int val);
ASTNode* new_expr_str_node(const char* val);
ASTNode* new_expr_local_var_node(int index, DataType dt);
ASTNode* new_expr_global_var_node(const char* id, DataType dt);
ASTNode* new_expr_unary_op_node(int op, ASTNode* operand);
ASTNode* new_expr_binary_op_node(int op, ASTNode* left, ASTNode* right);
ASTNode* new_expr_invoke_node(DataType dt, const char* id, NodeList args);
NodeList new_list();
void append_ast_node(NodeList* list, ASTNode* node);
void free_ast(ASTNode* node);

#endif