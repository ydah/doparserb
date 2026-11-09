# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_driver"

class GenerationStdinTest < Test::Unit::TestCase
  include CommandTest

  def test_help_and_version_with_stdin_argument_preserve_every_byte
    %w[--help --version].each do |flag|
      upstream = PTYDriver.new([RbConfig.ruby, File.join(LRAMA_ROOT, "exe/lrama"), flag, "-"])
      show = PTYDriver.doparserb(flag, "-")
      assert_equal(0, upstream.wait_exit)
      assert_equal(0, show.wait_exit)
      assert_equal(upstream.raw_output, show.raw_output, flag)
    ensure
      upstream&.close
      show&.close
    end
  end

  def test_terminal_grammar_input_keeps_canonical_eof_and_generated_output
    Dir.mktmpdir("doparserb-stdin") do |directory|
      grammar = File.read(File.join(FIXTURES, "prec.y"))
      upstream = stdin_driver(File.join(LRAMA_ROOT, "exe/lrama"), directory)
      upstream.wait_for("READING GRAMMAR")
      upstream.send_keys(grammar + "\x04")
      assert_equal(0, upstream.wait_exit(timeout: 3), upstream.all_text)
      expected_source = File.binread(File.join(directory, "parser.c"))
      expected_text = upstream.all_text
      upstream.close

      show = stdin_driver(File.join(ROOT, "exe/doparserb"), directory, "--dopa-runtime=off", "--dopa-set", "duration=0.1")
      show.wait_for("READING GRAMMAR")
      show.send_keys(grammar + "\x04")
      assert_nothing_raised { assert_equal(0, show.wait_exit(timeout: 3)) }
      assert_equal(expected_source, File.binread(File.join(directory, "parser.c")))
      assert_equal(expected_text, show.all_text.lines.reject { |line| line.start_with?("* ") }.join.rstrip)
      assert_equal(1, show.all_text.lines.count { |line| line.start_with?("* ") })
    ensure
      upstream&.close
      show&.close
    end
  end

  private

  def stdin_driver(executable, directory, *options)
    program = <<~RUBY
      require "lrama"
      Lrama::Command.prepend(Module.new do
        def read_input
          STDERR.write("READING GRAMMAR\\n")
          super
        end
      end)
      load ARGV.shift
    RUBY
    PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", program, executable,
                   *options, "-o", "parser.c", "-", "grammar.y"], directory: directory)
  end
end
