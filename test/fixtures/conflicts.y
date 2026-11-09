%%
start: expression | alias;
expression: expression '+' expression | 'n';
alias: 'n';
%%
