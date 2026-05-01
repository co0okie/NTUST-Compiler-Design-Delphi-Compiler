%{
#include "y.tab.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIST     strcat(buf, yytext)
#define token(t) { LIST; if(Opt_T) printf("<'%s'>\n", #t); return t; }
#define tokenString(t, s) { LIST; if(Opt_T) printf("<%s:%s>\n", t, s); return s; }

int Opt_T = 0; /* output token */
int Opt_S = 0; /* output source code */
char buf[256];
char string_buf[1024];
char *string_buf_ptr;
%}

%option yylineno
%option caseless

/* 處理多行註解與字串的 Start Condition */
%x COMMENT
%x STRING

%%

 /* include \r to avoid LF/CRLF problem */
[ \t\r]+    { LIST; }
\n          { 
              LIST; 
              if (Opt_S) printf("%02d: %s", yylineno - 1, buf); 
              buf[0] = '\0'; 
            }

 /* single line comment */
"//"        { LIST;
              char c; 
              while((c = input()) != '\n' && c != EOF) LIST; 
              if(c == '\n') unput(c); 
            }

 /* multi line comment */
"(*"        { LIST; BEGIN(COMMENT); }
<COMMENT>"*)" { LIST; BEGIN(INITIAL); }
<COMMENT>\n { 
              LIST; 
              if (Opt_S) printf("%02d: %s", yylineno - 1, buf); 
              buf[0] = '\0'; 
            }
<COMMENT>.  { LIST; }

"program"   token(PROGRAM);
"const"     token(CONST);
"var"       token(VAR);
"array"     token(ARRAY);
"of"        token(OF);
"integer"   token(INTEGER_TYPE);
"real"      token(REAL_TYPE);
"boolean"   token(BOOLEAN_TYPE);
"string"    token(STRING_TYPE);
"function"  token(FUNCTION);
"procedure" token(PROCEDURE);
"begin"     token(BEGIN_KW);
"end"       token(END);
"if"        token(IF);
"then"      token(THEN);
"else"      token(ELSE);
"while"     token(WHILE);
"do"        token(DO);
"for"       token(FOR);
"to"        token(TO);
"repeat"    token(REPEAT);
"until"     token(UNTIL);
"read"      token(READ);
"write"     token(WRITE);
"writeln"   token(WRITELN);
"return"    token(RETURN);
"true"      token(TRUE_KW);
"false"     token(FALSE_KW);
"mod"       token(MOD);
"and"       token(AND);
"or"        token(OR);
"not"       token(NOT);

":="        token(ASSIGN);
"<="        token(LE);
">="        token(GE);
"<>"        token(NEQ);
";"         token(SEMICOLON);
":"         token(COLON);
","         token(COMMA);
"="         token(EQ);
"<"         token(LT);
">"         token(GT);
"+"         token(ADD);
"-"         token(SUB);
"*"         token(MUL);
"/"         token(DIV);
"("         token(LPAREN);
")"         token(RPAREN);
"["         token(LBRACK);
"]"         token(RBRACK);
"."         token(DOT);

 /* identifier */
[a-zA-Z_][a-zA-Z0-9_]* { 
              LIST; 
              yylval.sval = strdup(yytext); 
              if(Opt_T) printf("<id: %s>\n", yytext); 
              return ID; 
            }

[0-9]+      { 
              LIST; 
              yylval.ival = atoi(yytext); 
              if(Opt_T) printf("<integer: %d>\n", yylval.ival); 
              return INT_CONST; 
            }
[0-9]+"."[0-9]+ { 
              LIST; 
              yylval.fval = atof(yytext); 
              if(Opt_T) printf("<real: %f>\n", yylval.fval); 
              return REAL_CONST; 
            }

 /* string */
\"          { 
              LIST; 
              string_buf_ptr = string_buf;
              BEGIN(STRING);
            }
<STRING>\"\" { 
              LIST; 
              *string_buf_ptr++ = '"';
            }
<STRING>\"  { 
              LIST; 
              *string_buf_ptr = '\0';
              BEGIN(INITIAL);
              yylval.sval = strdup(string_buf);
              if(Opt_T) printf("<string: %s>\n", string_buf);
              return STR_CONST;
            }
<STRING>\n  { 
              LIST; 
              printf("\n%02d: Lex Error: Unterminated string\n", yylineno - 1); 
              if (Opt_S) printf("%02d: %s", yylineno - 1, buf); 
              buf[0] = '\0'; 
              BEGIN(INITIAL);
            }
<STRING>.   { 
              LIST; 
              *string_buf_ptr++ = yytext[0];
            }

.           { 
              LIST; 
              printf("\n%02d: Lex Error: Unrecognized character: '%s'\n", yytext, yylineno); 
            }
%%

int yywrap() {
    return 1;
}