# frozen_string_literal: true

module Doparserb
  module Runtime
    module Anchors
      ALL = {
        runtime: {text: "/*----------.\n| yyparse.  |\n`----------*/", position: :before,
                  hook: '<%= ::Doparserb::Runtime.c_source(output.doparserb_metadata, parser_id: output.doparserb_parser_id) %>'},
        declaration: {text: "  int yylen = 0;\n\n  YYDPRINTF ((stderr, \"Starting parse\\n\"));", position: :declaration,
                      hook: "  DOPA_DECL();"},
        begin_parse: {text: '  YYDPRINTF ((stderr, "Starting parse\n"));', hook: "  DOPA_BEGIN();"},
        token: {text: 'YY_SYMBOL_PRINT ("Next token is", yytoken, &yylval, &yylloc<%= output.user_args %>);', count: 2,
                hook: "      DOPA_TOKEN(yytoken, &yylloc);"},
        shift: {text: '  YY_SYMBOL_PRINT ("Shifting", yytoken, &yylval, &yylloc<%= output.user_args %>);',
                hook: "  DOPA_SHIFT(yytoken, yyn, yyssp - yyss + 1);"},
        reduce: {text: '  YY_REDUCE_PRINT (yyn<%= output.user_args %>);', position: :before,
                 hook: "  DOPA_REDUCE(yyn, yylen, yystate, yyssp - yyss);"},
        error: {text: "      ++yynerrs;", hook: "      DOPA_ERROR(yystate, yytoken, &yylloc);"},
        pop_rule: {text: '<%= output.after_pop_stack_function("yylen", "/* %after-pop-stack function. */") %>',
                   hook: "  DOPA_POP(yylen, yyssp - yyss);"},
        pop_one: {text: '<%= output.after_pop_stack_function(1, "/* %after-pop-stack function. */") %>',
                  hook: "      DOPA_POP(1, yyssp - yyss);"},
        error_shift: {text: '  YY_SYMBOL_PRINT ("Shifting", YY_ACCESSING_SYMBOL (yyn), yyvsp, yylsp<%= output.user_args %>);',
                      hook: "  DOPA_ERROR_SHIFT(yyn, yyssp - yyss + 1);"},
        repair_plan: {text: '      rep_terms = yyrecover (yyss, yyssp, yychar<%= output.user_args %>);',
                      hook: "      DOPA_REPAIR_PLAN(rep_terms ? rep_terms->length : 0);"},
        repair_token: {text: '              YY_SYMBOL_PRINT ("Next error recovery token is", yytoken, &yylval, &yylloc<%= output.user_args %>);',
                       hook: "              DOPA_REPAIR_TOKEN(yytoken);"},
        repair_done: {text: '              YYDPRINTF ((stderr, "Error recovery is completed\n"));',
                      hook: "              DOPA_REPAIR_DONE();"},
        accept: {text: "yyacceptlab:", hook: "  DOPA_ACCEPT();"},
        abort_parse: {text: "yyabortlab:", hook: "  DOPA_ABORT();"},
        exhausted: {text: "yyexhaustedlab:", hook: "  DOPA_EXHAUSTED();"},
        end_parse: {text: "yyreturnlab:", hook: "  DOPA_END();"},
        before_lex: {text: '      yychar = yylex <%= output.yylex_formals %>;', position: :before, hook: "      DOPA_FLUSH();"},
        eof: {text: '      YYDPRINTF ((stderr, "Now at end of input.\n"));', hook: "      DOPA_TOKEN(yytoken, &yylloc);"},
        scanner_error: {text: '      yytoken = <%= output.error_symbol.enum_name %>;', hook: "      DOPA_ERROR(yystate, yytoken, &yylloc);"},
        explicit_error: {text: "    YYERROR;\n  ++yynerrs;", hook: "  DOPA_ERROR(yystate, yytoken, &yylloc);"}
      }.transform_values(&:freeze).freeze
    end
  end
end
