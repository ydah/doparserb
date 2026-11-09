%left '+' '-'
%left '*' '/'
%right '^'
%%
expression: 'n'
          | expression '+' expression
          | expression '-' expression
          | expression '*' expression
          | expression '/' expression
          | expression '^' expression;
%%
