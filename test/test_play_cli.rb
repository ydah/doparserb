# frozen_string_literal: true

require_relative "test_helper"

class PlayCLITest < Test::Unit::TestCase
  include CommandTest

  def test_play_preserves_child_arguments_and_exit_status
    code = 'puts ARGV.inspect; exit 23'
    arguments = ["--dopa=off", "--replay=invalid", "--speed=bad", "--", "two words"]
    result = run_command(:doparserb, ["play", "--replay=full", "--speed=20", "--", RbConfig.ruby, "-e", code, "--", *arguments], directory: ROOT)
    assert_equal(23, result[:status])
    assert_equal("#{arguments.inspect}\n", result[:stdout])
    assert_equal("", result[:stderr])
  end

  def test_play_accepts_separate_option_values_and_presentation_settings
    result = run_command(:doparserb, ["play", "--replay", "off", "--speed", "20", "--dopa=calm", "--dopa-set", "sound=off", "--", RbConfig.ruby, "-e", "exit 0"], directory: ROOT)
    assert_equal({stdout: "", stderr: "", status: 0}, result)
  end

  def test_play_requires_a_delimiter_and_command
    [["play"], ["play", "--"], ["play", RbConfig.ruby]].each do |arguments|
      result = run_command(:doparserb, arguments, directory: ROOT)
      assert_equal(1, result[:status], arguments.inspect)
      assert_include(result[:stderr], "play requires -- followed by a command")
    end
  end

  def test_play_rejects_invalid_replay_and_speed
    %w[--replay=invalid --replay=full,speed=20 --speed=0 --speed=2001 --speed=NaN --speed=Infinity
       --speed=1.5 --speed=20,sound=off --dopa-runtime=off --dopa-meta=embed --unknown].each do |option|
      result = run_command(:doparserb, ["play", option, "--", RbConfig.ruby, "-e", 'puts "CHILD"'], directory: ROOT)
      assert_equal(1, result[:status], option)
      assert_equal("", result[:stdout], option)
      assert_include(result[:stderr], "doparserb:", option)
    end
  end

  def test_play_reports_missing_executable
    result = run_command(:doparserb, ["play", "--", "/doparserb/no-such-executable"], directory: ROOT)
    assert_equal(127, result[:status])
    assert_include(result[:stderr], "/doparserb/no-such-executable")
    assert_include(result[:stderr], "not found")
  end
end
