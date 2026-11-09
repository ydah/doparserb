%define lr.type ielr
%%
start: 'a' left 'd' | 'b' left 'e' | 'a' right 'e' | 'b' right 'd';
left: 'c';
right: 'c';
%%
