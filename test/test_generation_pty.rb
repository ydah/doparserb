# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_driver"

class GenerationPTYTest < Test::Unit::TestCase
  include CommandTest

  def test_max_show_leaves_only_upstream_output_and_one_badge
    with_grammar("prec") do |directory|
      baseline = upstream(directory)
      driver = show(directory)
      assert_equal(0, driver.wait_exit)
      %w[DOPARSERB STATES FORGED FLAWLESS].each { |label| assert_include(driver.raw_output, label) }
      assert_include(driver.raw_output, "PRECEDENCE SLASH")
      assert_equal(baseline, without_badges(driver.all_text))
      assert_equal(1, badges(driver.all_text).length)
      assert_equal({}, driver.unknown)
    ensure
      driver&.close
    end
  end

  def test_pending_key_cancels_within_fifty_milliseconds_without_consuming_it
    with_grammar("prec") do |directory|
      program = <<~'RUBY'
        begin
          load ARGV.shift
        rescue SystemExit => error
          raise unless error.success?
        end
        key = STDIN.raw { STDIN.read(1) }
        STDOUT.write("PRESERVED:#{key}\n")
      RUBY
      driver = PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", program,
                              File.join(ROOT, "exe/doparserb"), "grammar.y", "-o", "parser.c"], directory: directory)
      driver.wait_for("DOPARSERB", raw: true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until File.exist?(File.join(directory, "parser.c"))
        raise "generation did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.001
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      driver.send_keys("x")
      driver.wait_for("PRESERVED:x", timeout: 2)
      latency = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator(latency, :<=, 0.050, "cancellation took #{latency} seconds")
      assert_equal(0, driver.wait_exit)
    ensure
      driver&.close
    end
  end

  def test_warning_text_and_order_are_preserved
    with_grammar("warn") do |directory|
      baseline = upstream(directory, "-W")
      driver = show(directory, "-W")
      assert_equal(0, driver.wait_exit)
      assert_include(driver.raw_output, "WARNING")
      assert_equal(baseline, without_badges(driver.all_text))
    ensure
      driver&.close
    end
  end

  def test_grammar_break_keeps_error_text_and_status
    with_grammar("broken") do |directory|
      baseline = upstream(directory, status: 1)
      driver = show(directory)
      assert_equal(1, driver.wait_exit)
      assert_include(driver.raw_output, "GRAMMAR BREAK")
      assert_equal(baseline, without_badges(driver.all_text))
      assert_equal(1, badges(driver.all_text).length)
    ensure
      driver&.close
    end
  end

  def test_thirty_columns_leave_no_wrapped_animation_debris
    with_grammar("prec") do |directory|
      baseline = upstream(directory, cols: 30)
      driver = show(directory, cols: 30)
      assert_equal(0, driver.wait_exit)
      assert_equal(baseline, without_badges(driver.all_text))
      assert_equal(1, badges(driver.all_text).length)
      assert(driver.lines.all? { |line| line.length <= 30 })
      assert_equal({}, driver.unknown)
    ensure
      driver&.close
    end
  end

  def test_no_color_emits_no_sgr_sequences
    with_grammar("prec") do |directory|
      driver = show(directory, env: {"NO_COLOR" => "1"})
      assert_equal(0, driver.wait_exit)
      assert_no_match(/\e\[[\d;]*m/, driver.raw_output)
      assert_equal(1, badges(driver.all_text).length)
    ensure
      driver&.close
    end
  end

  def test_dumb_terminal_and_redirected_stderr_have_no_control_sequences
    with_grammar("prec") do |directory|
      driver = show(directory, env: {"TERM" => "dumb"})
      assert_equal(0, driver.wait_exit)
      assert_not_include(driver.raw_output, "\e")
      assert_empty(badges(driver.all_text))
      result = run_command(:doparserb, ["grammar.y", "-o", "parser.c"], directory: directory,
                           env: {"TERM" => "xterm-256color"})
      assert_equal(0, result[:status])
      assert_not_include(result[:stdout] + result[:stderr], "\e")
    ensure
      driver&.close
    end
  end

  def test_make_quick_effects_finish_within_point_eight_seconds
    with_grammar("prec") do |directory|
      driver = PTYDriver.doparserb("grammar.y", "-o", "parser.c", directory: directory, env: {"MAKELEVEL" => "1"})
      assert_equal(0, driver.wait_exit)
      frames = driver.records.select { |record| record[2].include?("\e") }
      assert_not_empty(frames)
      assert_operator(frames.last[0] - frames.first[0], :<=, 0.8)
      assert_not_include(driver.raw_output, "DOPARSERB")
    ensure
      driver&.close
    end
  end

  def test_parallel_generators_share_one_animated_terminal
    with_grammar("prec") do |directory|
      single = show(directory, duration: "0.3")
      assert_equal(0, single.wait_exit)
      stage_count = single.raw_output.scan("\e[?25l").length
      single.close
      program = 'pids = 2.times.map { Process.spawn(*ARGV) }; pids.each { |pid| Process.wait(pid) }'
      command = [RbConfig.ruby, "-I#{ROOT}/lib", File.join(ROOT, "exe/doparserb"),
                 "--dopa-set", "duration=0.3", "grammar.y", "-o", "parser.c"]
      driver = PTYDriver.new([RbConfig.ruby, "-e", program, *command], directory: directory)
      assert_equal(0, driver.wait_exit)
      assert_operator(stage_count, :>, 0)
      assert_equal(stage_count, driver.raw_output.scan("\e[?25l").length)
      assert_equal(2, badges(driver.all_text).length)
    ensure
      single&.close
      driver&.close
    end
  end

  def test_environment_off_matches_upstream_even_on_a_terminal
    with_grammar("prec") do |directory|
      baseline = upstream(directory)
      driver = show(directory, env: {"DOPAPARSER" => "off"})
      assert_equal(0, driver.wait_exit)
      assert_equal(baseline, driver.all_text)
      assert_not_include(driver.raw_output, "\e")
    ensure
      driver&.close
    end
  end

  def test_parallel_warnings_wait_until_the_other_show_releases_the_terminal
    with_grammar("prec") do |directory|
      FileUtils.cp(File.join(FIXTURES, "warn.y"), File.join(directory, "warn.y"))
      commands = [
        ["grammar.y", "-o", "parser.c"],
        ["warn.y", "-W", "-o", "warning.c"]
      ]
      baseline = commands.map do |arguments|
        child = PTYDriver.new([RbConfig.ruby, File.join(LRAMA_ROOT, "exe/lrama"), *arguments], directory: directory)
        assert_equal(0, child.wait_exit)
        child.all_text
      ensure
        child&.close
      end.join("\n")
      program = <<~'RUBY'
        executable = ARGV.shift
        first = Process.spawn(RbConfig.ruby, executable, "--dopa-set", "duration=0.5", "grammar.y", "-o", "parser.c")
        sleep 0.2
        second = Process.spawn(RbConfig.ruby, executable, "--dopa-set", "duration=0.1", "warn.y", "-W", "-o", "warning.c")
        [first, second].each { |pid| Process.wait(pid) }
      RUBY
      driver = PTYDriver.new([RbConfig.ruby, "-e", program, File.join(ROOT, "exe/doparserb")], directory: directory)
      assert_equal(0, driver.wait_exit)
      assert_equal(baseline, without_badges(driver.all_text))
      assert_equal(2, badges(driver.all_text).length)
    ensure
      driver&.close
    end
  end

  def test_generated_source_written_to_the_terminal_is_preserved
    with_grammar("prec") do |directory|
      args = ["grammar.y", "-o", "/dev/stdout"]
      baseline = PTYDriver.new([RbConfig.ruby, File.join(LRAMA_ROOT, "exe/lrama"), *args], directory: directory)
      assert_equal(0, baseline.wait_exit)
      driver = PTYDriver.doparserb("--dopa-runtime=off", "--dopa-set", "duration=0.1", *args, directory: directory)
      assert_equal(0, driver.wait_exit)
      assert_equal(baseline.all_text, without_badges(driver.all_text))
    ensure
      baseline&.close
      driver&.close
    end
  end

  def test_motion_off_and_trail_none
    with_grammar("prec") do |directory|
      baseline = upstream(directory)
      driver = show(directory, settings: "motion=off")
      assert_equal(0, driver.wait_exit)
      assert_equal(baseline, without_badges(driver.all_text))
      assert_equal(1, badges(driver.all_text).length)
      assert_not_include(driver.raw_output, "\e[?25l")
      driver.close
      driver = show(directory, settings: "motion=off,trail=none")
      assert_equal(0, driver.wait_exit)
      assert_equal(baseline, driver.all_text)
    ensure
      driver&.close
    end
  end

  def test_help_remains_upstream_output_on_a_terminal
    baseline = PTYDriver.new([RbConfig.ruby, File.join(LRAMA_ROOT, "exe/lrama"), "--help"])
    assert_equal(0, baseline.wait_exit)
    driver = PTYDriver.doparserb("--help")
    assert_equal(0, driver.wait_exit)
    assert_equal(baseline.raw_output, driver.raw_output)
    assert_not_include(driver.raw_output, "\e")
    assert_empty(badges(driver.all_text))
  ensure
    baseline&.close
    driver&.close
  end

  private

  def with_grammar(name)
    Dir.mktmpdir("doparserb-generation-pty") do |directory|
      FileUtils.cp(File.join(FIXTURES, "#{name}.y"), File.join(directory, "grammar.y"))
      yield directory
    end
  end

  def show(directory, *arguments, cols: 80, env: {}, duration: "0.1", settings: "")
    values = ["duration=#{duration}", settings].reject(&:empty?).join(",")
    PTYDriver.doparserb("--dopa-set", values, *arguments, "grammar.y", "-o", "parser.c",
                       directory: directory, cols: cols, env: env)
  end

  def upstream(directory, *arguments, status: 0, cols: 80)
    driver = PTYDriver.new([RbConfig.ruby, File.join(LRAMA_ROOT, "exe/lrama"), *arguments,
                            "grammar.y", "-o", "parser.c"], directory: directory, cols: cols)
    assert_equal(status, driver.wait_exit)
    driver.all_text
  ensure
    driver&.close
  end

  def badges(text) = text.lines.select { |line| line.start_with?("* ") }
  def without_badges(text) = text.lines.reject { |line| line.start_with?("* ") }.join.rstrip
end
