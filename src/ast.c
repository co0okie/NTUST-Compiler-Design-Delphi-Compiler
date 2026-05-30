#include "ast.h"
#include "y.tab.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void yyerror(const char *msg);

NodeList new_list() {
    NodeList list;
    list.head = NULL;
    list.tail = NULL;
    return list;
}

void append_ast_node(NodeList* list, ASTNode* node) {
    if (!list || !node) return;
    if (!list->tail) {
        list->head = node;
        list->tail = node;
    } else {
        list->tail->next = node;
        list->tail = node;
    }
}

void free_list(NodeList list) {
    for (ASTNode* node = list.head, *next = NULL; node; node = next) {
        next = node->next;
        free_ast(node);
    }
}

ASTNode* new_node(NodeType nt) {
    ASTNode* node = (ASTNode*)malloc(sizeof(ASTNode));
    node->node_type = nt;
    node->next = NULL;
    return node;
}

ASTNode* new_id_node(const char* id) {
    ASTNode* node = new_node(AST_ID);
    node->as.id = strdup(id);
    return node;
}

ASTNode* new_param_node(const char* id, DataType type) {
    ASTNode* node = new_node(AST_PARAM);
    node->as.param.id = strdup(id);
    node->as.param.type = type;
    return node;
}

ASTNode* new_list_node() {
    ASTNode* node = new_node(AST_LIST);
    node->as.list = new_list();
    return node;
}

ASTNode* new_expr_node(NodeType nt, DataType dt, int is_const) {
    ASTNode* node = new_node(nt);
    node->as.expr.data_type = dt;
    node->as.expr.is_const = is_const;
    return node;
}

ASTNode* new_expr_int_node(int val) {
    ASTNode* node = new_expr_node(AST_CONST_INT, TYPE_INT, 1);
    node->as.expr.as.int_val = val;
    return node;
}

ASTNode* new_expr_bool_node(int val) {
    ASTNode* node = new_expr_node(AST_CONST_BOOL, TYPE_BOOL, 1);
    node->as.expr.as.bool_val = val;
    return node;
}

ASTNode* new_expr_str_node(const char* val) {
    ASTNode* node = new_expr_node(AST_CONST_STR, TYPE_STR, 1);
    node->as.expr.as.str_val = strdup(val);
    return node;
}

ASTNode* new_expr_local_var_node(int index, DataType dt) {
    ASTNode* node = new_expr_node(AST_LOCAL_VAR, dt, 0);
    node->as.expr.as.local_var_index = index;
    return node;
}

ASTNode* new_expr_global_var_node(const char* id, DataType dt) {
    ASTNode* node = new_expr_node(AST_GLOBAL_VAR, dt, 0);
    node->as.expr.as.global_var_name = strdup(id);
    return node;
}

ASTNode* new_expr_unary_op_node(int op, ASTNode* operand) {
    return new_expr_binary_op_node(op, operand, NULL);
}

ASTNode* new_expr_binary_op_node(int op, ASTNode* left, ASTNode* right) {
    
    if (left->as.expr.data_type == TYPE_STR || (right && right->as.expr.data_type == TYPE_STR)) {
        yyerror("String operations are not supported.");
        return NULL;
    }
    
    if (right && left->as.expr.data_type != right->as.expr.data_type && left->as.expr.data_type != TYPE_UNKNOWN && right->as.expr.data_type != TYPE_UNKNOWN) {
        yyerror("Type mismatch: operands must have the same type.");
        return NULL;
    }
    
    DataType out_type = TYPE_INT; /* Default */
    switch (op) {
        case ADD: case SUB: case MUL: case DIV: case MOD: case NEG:
            out_type = TYPE_INT;
            break;
        case EQ: case NEQ: case LT: case LE: case GT: case GE:
            out_type = TYPE_BOOL;
            break;
        case AND: case OR: case NOT:
            out_type = left->as.expr.data_type; /* Logical operation result type matches operands */
            break;
    }
    
    if (!left->as.expr.is_const || (right && !right->as.expr.is_const)) {
        NodeType type = (op == NOT || op == NEG) ? AST_UNARY_OP : AST_BINARY_OP;
        ASTNode* node = new_expr_node(type, out_type, 0);
        node->as.expr.as.op.op = op;
        node->as.expr.as.op.left = left;
        node->as.expr.as.op.right = right;
        return node;
    }
    

    /* compile time constexpr evaluation */
    int l_val = (left->as.expr.data_type == TYPE_INT) ? left->as.expr.as.int_val : left->as.expr.as.bool_val;
    int r_val = !right ? 0 : (right->as.expr.data_type == TYPE_INT) ? right->as.expr.as.int_val : right->as.expr.as.bool_val;
                  
    ASTNode* node = NULL;
    switch (op) {
        case ADD: node = new_expr_int_node(l_val + r_val); break;
        case SUB: node = new_expr_int_node(l_val - r_val); break;
        case MUL: node = new_expr_int_node(l_val * r_val); break;
        case DIV: 
            if (r_val == 0) { yyerror("Division by zero."); return NULL; }
            node = new_expr_int_node(l_val / r_val); break;
        case MOD: 
            if (r_val == 0) { yyerror("Division by zero."); return NULL; }
            node = new_expr_int_node(l_val % r_val); break;
        case NEG: node = new_expr_int_node(-l_val); break;
        case EQ:  node = new_expr_bool_node(l_val == r_val); break;
        case NEQ: node = new_expr_bool_node(l_val != r_val); break;
        case LT:  node = new_expr_bool_node(l_val < r_val); break;
        case LE:  node = new_expr_bool_node(l_val <= r_val); break;
        case GT:  node = new_expr_bool_node(l_val > r_val); break;
        case GE:  node = new_expr_bool_node(l_val >= r_val); break;
        case AND:
            node = out_type == TYPE_BOOL ? new_expr_bool_node(l_val && r_val) : new_expr_int_node(l_val & r_val);
            break;
        case OR:
            node = out_type == TYPE_BOOL ? new_expr_bool_node(l_val || r_val) : new_expr_int_node(l_val | r_val);
            break;
        case NOT: node = out_type == TYPE_BOOL ? new_expr_bool_node(!l_val) : new_expr_int_node(~l_val);
            break;
    }
    
    free_ast(left); if (right) free_ast(right);
    return node;
}

ASTNode* new_expr_invoke_node(DataType dt, const char* id, NodeList args) {
    ASTNode* node = new_expr_node(AST_INVOKE, dt, 0);
    node->as.expr.as.invoke.name = strdup(id);
    node->as.expr.as.invoke.args = args;
    return node;
}

void free_ast(ASTNode* node) {
    if (!node) return;
    switch (node->node_type) {
        case AST_ID: free(node->as.id); break;
        case AST_CONST_STR: free(node->as.expr.as.str_val); break;
        case AST_LIST: free_list(node->as.list); break;
        case AST_INVOKE: 
            free(node->as.expr.as.invoke.name);
            free_list(node->as.expr.as.invoke.args);
            break;
        case AST_BINARY_OP: free_ast(node->as.expr.as.op.right);
        case AST_UNARY_OP: free_ast(node->as.expr.as.op.left); break;
    }
    free(node);
}