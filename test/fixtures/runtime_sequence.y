%{
#include <stdio.h>
%}
%code provides {
static int yylex(YYSTYPE *value, YYLTYPE *location);
static int yyerror(YYLTYPE *location, const char *message);
}
%locations
%%
start: '(' items ')';
items: %empty | items 'a';
%%
static int yylex(YYSTYPE *value, YYLTYPE *location)
{
  int token = getchar();
  (void)value;
  if (token == '|') {
    fputs("READY\n", stdout);
    fflush(stdout);
    if (getchar() != '!') return YYerror;
    token = getchar();
  }
  location->first_line = location->last_line = 1;
  location->first_column = location->last_column = 1;
  return token == EOF ? 0 : token;
}
static int yyerror(YYLTYPE *location, const char *message)
{
  (void)location;
  fprintf(stderr, "%s\n", message);
  return 0;
}
#ifndef DOPA_TEST_NO_MAIN
int main(void) { return yyparse(); }
#endif
