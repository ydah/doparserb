# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "lrama"
require "pathname"

class RuntimeWeavingTest < Test::Unit::TestCase
  include CommandTest

  def test_every_anchor_rejects_missing_and_duplicate_matches_before_weaving
    runtime = runtime_module
    template = skeleton
    runtime::Anchors::ALL.each do |name, anchor|
      text = anchor.fetch(:text)
      [template.sub(text, ""), template + "\n" + text].each do |unsupported|
        original = unsupported.dup
        error = assert_raise(Doparserb::Error, name.to_s) { runtime::Weaver.new(unsupported).weave }
        assert_include(error.message, name.to_s)
        assert_include(error.message, "--dopa-runtime=off")
        assert_equal(original, unsupported)
      end
    end
  end

  def test_hooks_use_the_documented_state_and_depth_and_repair_branches
    woven = runtime_module::Weaver.new(skeleton).weave
    assert_equal(1, woven.scan("DOPA_DECL();").length)
    assert_include(woven, "int yylen = 0;\n  DOPA_DECL();")
    assert_include(woven, "DOPA_SHIFT(yytoken, yyn, yyssp - yyss + 1);")
    assert_include(woven, "DOPA_REDUCE(yyn, yylen, yystate, yyssp - yyss);")
    assert_include(woven, "DOPA_REPAIR_PLAN(rep_terms ? rep_terms->length : 0);")
    assert_equal(3, woven.scan("DOPA_ERROR(").length)
    assert_equal(3, woven.scan("DOPA_TOKEN(").length)
    assert_match(/DOPA_FLUSH\(\);\n\s+yychar = yylex/, woven)
    assert_match(/DOPA_REDUCE[^\n]+\n  YY_REDUCE_PRINT/, woven)
    assert_operator(woven.index("::Doparserb::Runtime.c_source"), :<, woven.index("| yyparse.  |"))
  end

  def test_temporary_template_keeps_the_basename_and_is_removed
    saved = nil
    runtime_module::Weaver.new(skeleton).with_template do |path|
      saved = path
      assert_equal("yacc.c", File.basename(path))
      assert_path_exist(path)
      assert_include(File.read(path), "DOPA_BEGIN();")
    end
    assert_false(File.exist?(saved))
  end

  def test_metadata_digest_and_sidecar_stub_are_deterministic_and_path_free
    meta = runtime_module::Meta.new(metadata_data)
    data = JSON.parse(meta.json)
    digest = data.delete("digest")
    assert_equal(Digest::SHA256.hexdigest(JSON.generate(data)), digest)
    assert_equal("grammar.y", data.fetch("grammar"))
    assert_equal(digest[0, 8], meta.parser_id)
    assert_equal(meta.json, runtime_module::Meta.new(metadata_data).json)
    stub = JSON.parse(meta.stub_json)
    assert_equal(%w[digest generator grammar v], stub.keys.sort)
    assert_equal(digest, stub.fetch("digest"))
    assert_not_include(meta.json, "/private/")
  end

  def test_c_literal_preserves_quotes_controls_utf8_and_trigraphs
    value = "quote\" slash\\ newline\n tab\t nul\0 \u03bb ??/ <%= raise 'unsafe' %>"
    literal = runtime_module::Meta.c_literal(value)
    assert_match(/\A"(?:\\[0-7]{3})*"\z/, literal)
    Dir.mktmpdir("doparserb-literal") do |directory|
      File.write(File.join(directory, "literal.c"), <<~C)
        #include <stdio.h>
        static const char value[] = #{literal};
        int main(void) { return fwrite(value, 1, sizeof(value) - 1, stdout) != sizeof(value) - 1; }
      C
      _out, err, status = Open3.capture3("clang", "-std=c99", "-Wall", "-Wextra", "-Werror", "literal.c", "-o", "literal", chdir: directory)
      assert_predicate(status, :success?, err)
      out, err, status = Open3.capture3(File.join(directory, "literal"))
      assert_predicate(status, :success?, err)
      assert_equal(value.b, out.b)
    end
  end

  def test_runtime_source_rejects_non_hex_parser_identifiers
    runtime = runtime_module
    assert_raise(ArgumentError) { runtime.c_source("{}", parser_id: '"; #error unsafe') }
    assert_raise(ArgumentError) { runtime.c_source("{}", parser_id: "abcd") }
  end

  def test_runtime_source_does_not_emit_ruby_warnings
    program = 'Doparserb::Runtime.c_source("{}", parser_id: "0123abcd")'
    _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I#{ROOT}/lib", "-rdoparserb", "-e", program)
    assert_predicate(status, :success?, err)
    assert_equal("", err)
  end

  def test_runtime_is_on_when_generation_effects_and_environment_are_off
    with_grammar do |directory|
      baseline = run_command(:lrama, ["grammar.y", "-o", "parser.c"], directory: directory)
      result = run_command(:doparserb, ["--dopa=off", "grammar.y", "-o", "parser.c"], directory: directory,
                           env: {"DOPAPARSER" => "off", "DOPAPARSER_RUNTIME" => "off"})
      assert_equal(0, result[:status], result[:stderr])
      assert_include(File.read(File.join(directory, "parser.c")), "DOPA_BEGIN();")
      assert_equal(baseline[:stderr], result[:stderr])
    end
  end

  def test_full_off_artifacts_match_upstream_even_with_sidecar_requested
    with_grammar do |directory|
      args = ["-d", "grammar.y", "-o", "parser.c"]
      expected = run_command(:lrama, args, directory: directory)
      files = generated_files(directory, "grammar.y")
      actual = run_command(:doparserb, ["--dopa=off", "--dopa-runtime=off", "--dopa-meta=sidecar", *args], directory: directory)
      assert_equal(expected, actual)
      assert_equal(files, generated_files(directory, "grammar.y"))
    end
  end

  def test_sidecar_mapping_matches_c_rule_numbers_and_internal_symbols
    with_grammar do |directory|
      result = run_command(:doparserb, ["--dopa=off", "--dopa-meta=sidecar", "-d", "grammar.y", "-o", "parser.c"], directory: directory)
      assert_equal(0, result[:status], result[:stderr])
      path = File.join(directory, "parser.c.dopa.json")
      assert_path_exist(path)
      data = JSON.parse(File.read(path))
      command = Lrama::Command.new([File.join(directory, "grammar.y")])
      grammar = command.send(:build_grammar, command.send(:read_input))
      states, context = command.send(:compute_status, grammar)
      assert_equal(states.states.length, data.fetch("states"))
      assert_equal(grammar.symbols.map(&:number).sort, data.fetch("symbols").map { |symbol| symbol.fetch("id") })
      data.fetch("rules").each do |rule|
        assert_equal(context.yyr1.fetch(rule.fetch("id")), rule.fetch("lhs"))
        assert_equal(context.yyr2.fetch(rule.fetch("id")), rule.fetch("rhs").length)
        original = grammar.rules.find { |item| item.id + 1 == rule.fetch("id") }
        assert_equal(original.rhs.map(&:number), rule.fetch("rhs"))
      end
      assert_not_include(data.to_json, directory)
    end
  end

  def test_generated_bytes_and_headers_do_not_depend_on_generation_settings
    with_grammar do |directory|
      args = ["grammar.y", "-d", "-o", "parser.c"]
      run_command(:lrama, args, directory: directory)
      header = File.binread(File.join(directory, "parser.h"))
      result = run_command(:doparserb, ["--dopa=off", *args], directory: directory)
      assert_equal(0, result[:status], result[:stderr])
      expected = File.binread(File.join(directory, "parser.c"))
      result = run_command(:doparserb, ["--dopa=party", *args], directory: directory,
                           env: {"DOPAPARSER" => "party", "DOPAPARSER_SEED" => "9876", "TERM" => "xterm", "NO_COLOR" => nil})
      assert_equal(0, result[:status], result[:stderr])
      assert_equal(expected, File.binread(File.join(directory, "parser.c")))
      assert_equal(header, File.binread(File.join(directory, "parser.h")))
    end
  end

  def test_repair_hooks_are_emitted_only_with_error_recovery
    with_grammar do |directory|
      [[], ["-e"]].each do |options|
        result = run_command(:doparserb, ["--dopa=off", *options, "grammar.y", "-o", "parser.c"], directory: directory)
        assert_equal(0, result[:status], result[:stderr])
        source = File.read(File.join(directory, "parser.c"))
        assert_equal(options.empty? ? 0 : 1, source.scan("DOPA_REPAIR_PLAN(rep_terms").length)
        assert_equal(options.empty? ? 0 : 1, source.scan("DOPA_REPAIR_TOKEN(yytoken);").length)
        assert_equal(1, source.scan("  DOPA_DECL();").length)
      end
    end
  end

  def test_unsupported_skeleton_leaves_existing_output_untouched_and_can_be_disabled
    with_grammar do |directory|
      path = File.join(directory, "custom.c")
      File.write(path, skeleton.sub("yyacceptlab:", "yyacceptlab :"))
      relative = Pathname.new(path).relative_path_from(Pathname.new(File.join(LRAMA_ROOT, "template"))).to_s
      File.write(File.join(directory, "parser.c"), "existing output")
      args = ["--dopa=off", "--skeleton", relative, "grammar.y", "-o", "parser.c"]
      result = run_command(:doparserb, args, directory: directory)
      assert_equal(1, result[:status])
      assert_include(result[:stderr], "--dopa-runtime=off")
      assert_equal("existing output", File.read(File.join(directory, "parser.c")))
      result = run_command(:doparserb, ["--dopa-runtime=off", *args], directory: directory)
      assert_equal(0, result[:status], result[:stderr])
      assert_not_include(File.read(File.join(directory, "parser.c")), "DOPA_BEGIN();")
    end
  end

  def test_embedded_metadata_is_rendered_as_data_even_with_erb_syntax_in_names
    with_grammar do |directory|
      File.write(File.join(directory, "grammar.y"), <<~'GRAMMAR')
        %code provides {
        int yylex(YYSTYPE *value, YYLTYPE *location);
        int yyerror(YYLTYPE *location, const char *message);
        }
        %locations
        %token SPECIAL "<%= raise 'unsafe' %> \\\" lambda:λ"
        %%
        start: SPECIAL;
        %%
        int yylex(YYSTYPE *value, YYLTYPE *location) { (void) value; (void) location; return 0; }
        int yyerror(YYLTYPE *location, const char *message) { (void) location; (void) message; return 0; }
        int main(void) { return yyparse(); }
      GRAMMAR
      [[], ["-e"]].each do |options|
        result = run_command(:doparserb, ["--dopa=off", *options, "grammar.y", "-o", "parser.c"], directory: directory)
        assert_equal(0, result[:status], result[:stderr])
        source = File.read(File.join(directory, "parser.c"))
        literal = source[/static const char yydopa_metadata\[\] = "((?:\\[0-7]{3})*)";/, 1]
        assert_not_nil(literal)
        metadata = JSON.parse(literal.scan(/\\([0-7]{3})/).map { |octal| octal.first.to_i(8) }.pack("C*"))
        assert_include(metadata.fetch("symbols").map { |symbol| symbol.fetch("name") }.join, "<%= raise 'unsafe' %>")
        _out, err, status = Open3.capture3("clang", "-std=c99", "-Wall", "-Wextra", "-c", "parser.c", "-o", "parser.o", chdir: directory)
        assert_predicate(status, :success?, err)
      end
    end
  end

  def test_runtime_context_is_restored_without_an_event_bus
    runtime_module
    with_grammar do |directory|
      previous = Thread.current[:doparserb_command]
      command = Doparserb::Command.new([File.join(directory, "grammar.y"), "-o", File.join(directory, "parser.c")])
      command.run
      assert_same(previous, Thread.current[:doparserb_command])
      assert_include(File.read(File.join(directory, "parser.c")), "DOPA_BEGIN();")
    end
  end

  def test_failed_generation_does_not_write_sidecar
    Dir.mktmpdir("doparserb-failed-meta") do |directory|
      result = run_command(:doparserb, ["--dopa=off", "--dopa-meta=sidecar", File.join(FIXTURES, "expect_ng.y"), "-o", "parser.c"], directory: directory)
      assert_equal(1, result[:status])
      assert_false(File.exist?(File.join(directory, "parser.c.dopa.json")))
    end
  end

  private

  def runtime_module
    assert_const_defined(Doparserb, :Runtime)
    Doparserb::Runtime
  end

  def skeleton
    File.read(File.join(LRAMA_ROOT, "template/bison/yacc.c"))
  end

  def metadata_data
    {grammar: "/private/build/grammar.y", generator: "test", states: 3,
     symbols: [{id: 0, name: "EOF", term: true}], rules: [{id: 1, lhs: 1, rhs: [0], text: "start: EOF"}]}
  end

  def with_grammar
    Dir.mktmpdir("doparserb-weaving") do |directory|
      FileUtils.cp(File.join(FIXTURES, "prec.y"), File.join(directory, "grammar.y"))
      yield directory
    end
  end
end
