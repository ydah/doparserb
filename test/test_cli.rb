# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Test::Unit::TestCase
  include CommandTest

  def test_help_and_version_are_upstream_output
    Dir.mktmpdir("doparserb-cli") do |directory|
      %w[--help --version].each do |flag|
        assert_equal(run_command(:lrama, [flag], directory: directory),
                     run_command(:doparserb, [flag], directory: directory))
      end
    end
  end

  def test_own_help_is_separate
    Dir.mktmpdir("doparserb-cli") do |directory|
      result = run_command(:doparserb, ["--dopa-help"], directory: directory)
      assert_equal(0, result[:status])
      assert_include(result[:stdout], "--dopa-runtime")
      assert_not_include(result[:stdout], "--dopa-debug-events")
      assert_equal("", result[:stderr])
    end
  end

  def test_dopa_options_are_removed_without_changing_lrama_arguments
    Dir.mktmpdir("doparserb-cli") do |directory|
      FileUtils.cp(File.join(FIXTURES, "prec.y"), File.join(directory, "grammar.y"))
      expected = run_command(:lrama, ["-d", "grammar.y", "-o", "result.c"], directory: directory)
      options = ["--dopa=off", "-d", "--dopa-runtime", "off", "grammar.y", "--dopa-meta=embed",
                 "--dopa-set", "flash=off,sound=off", "-o", "result.c"]
      assert_equal(expected, run_command(:doparserb, options, directory: directory))
      assert_path_exist(File.join(directory, "result.h"))
    end
  end

  def test_delimiter_preserves_a_dopa_named_grammar
    Dir.mktmpdir("doparserb-cli") do |directory|
      FileUtils.cp(File.join(FIXTURES, "prec.y"), File.join(directory, "--dopa=off"))
      args = ["--", "--dopa=off"]
      assert_equal(run_command(:lrama, args, directory: directory),
                   run_command(:doparserb, args, directory: directory))
    end
  end

  def test_relative_path_does_not_select_a_subcommand
    Dir.mktmpdir("doparserb-cli") do |directory|
      FileUtils.cp(File.join(FIXTURES, "prec.y"), File.join(directory, "play"))
      args = ["./play"]
      assert_equal(run_command(:lrama, args, directory: directory),
                   run_command(:doparserb, args, directory: directory))
    end
  end

  def test_lrama_option_values_are_not_treated_as_dopa_options
    Dir.mktmpdir("doparserb-cli") do |directory|
      FileUtils.cp(File.join(FIXTURES, "prec.y"), File.join(directory, "grammar.y"))
      args = ["-o", "--dopa=off", "grammar.y"]
      expected = run_command(:lrama, args, directory: directory)
      assert_equal(expected, run_command(:doparserb, args, directory: directory))
      assert_path_exist(File.join(directory, "--dopa=off"))
    end
  end

  def test_attached_header_names_are_not_scanned_as_short_options
    Dir.mktmpdir("doparserb-cli") do |directory|
      FileUtils.cp(File.join(FIXTURES, "prec.y"), File.join(directory, "grammar.y"))
      %w[r o D S].each do |header|
        flag = "-H#{header}"
        expected = run_command(:lrama, [flag, "grammar.y"], directory: directory)
        actual = run_command(:doparserb, [flag, "--dopa=off", "grammar.y"], directory: directory)
        assert_equal(expected, actual, flag)
        assert_path_exist(File.join(directory, header))
      end
    end
  end

  def test_invalid_own_options_fail_without_creating_output
    Dir.mktmpdir("doparserb-cli") do |directory|
      ["--dopa=unknown", "--dopa-runtime=invalid", "--dopa-meta=invalid", "--dopa-missing", "--dopa-set", "--dopa-set="].each do |flag|
        result = run_command(:doparserb, [flag], directory: directory)
        assert_equal(1, result[:status], flag)
        assert_include(result[:stderr], "doparserb:", flag)
        assert_equal([], Dir.children(directory), flag)
      end
    end
  end
end
