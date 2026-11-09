%{
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
%}
%code provides {
static int yylex(YYSTYPE *value, YYLTYPE *location);
static int yyerror(YYLTYPE *location, const char *message);
}
%union { int number; }
%token <number> NUMBER
%type <number> expression
%left '+'
%left '*'
%locations
%%
input: %empty | input line;
line: expression '\n' { printf("=> %d\n", $1); }
    | error '\n' { yyerrok; }
    | '!' { YYERROR; }
    | '@' { YYABORT; }
    | '?' { YYACCEPT; };
expression: NUMBER
          | expression '+' expression { $$ = $1 + $3; }
          | expression '*' expression { $$ = $1 * $3; }
          | '(' expression ')' { $$ = $2; };
%%
static int yylex(YYSTYPE *value, YYLTYPE *location)
{
  static int line = 1, column = 0;
  int token;
  do { token = getchar(); column++; } while (token == ' ' || token == '\t');
  location->first_line = location->last_line = line;
  location->first_column = location->last_column = column;
  if (token == '\n') { line++; column = 0; }
  if (token == EOF) return 0;
  if (isdigit(token)) { value->number = token - '0'; return NUMBER; }
  if (token == '#') { fputs("scanner error\n", stderr); return YYerror; }
  return token;
}
static int yyerror(YYLTYPE *location, const char *message)
{
  fprintf(stderr, "%d:%d: %s\n", location->first_line, location->first_column, message);
  return 0;
}
#ifndef DOPA_TEST_NO_MAIN
int main(void)
{
  if (getenv("PARSER_READY")) { puts("CALC READY"); fflush(stdout); }
#if YYDEBUG
  yydebug = getenv("PARSER_DEBUG") != NULL;
#endif
  return yyparse();
}
#endif
