# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_driver"
require "json"
require "date"

class CareerPTYTest < Test::Unit::TestCase
  include CommandTest

  def setup
    @directory = Dir.mktmpdir("doparserb-career-pty")
    @grammar = File.join(@directory, "grammar.y")
    @path = File.join(@directory, "state", "profile.json")
    @drivers = []
    FileUtils.cp(File.join(FIXTURES, "prec.y"), @grammar)
  end

  def teardown
    @drivers.each(&:close)
    FileUtils.remove_entry(@directory)
  end

  def test_generation_without_motion_or_trails_persists_exactly_once
    driver = generation(settings: "motion=off,trail=none")
    assert_equal(0, driver.wait_exit)
    assert_not_include(driver.raw_output, "\e[?25l")
    assert_empty(driver.all_text.lines.select { |line| line.start_with?("* ") })
    assert_path_exist(@path)
    state = read_profile
    assert_equal(1, state.fetch("generation_runs"))
    assert_operator(state.fetch("xp"), :>, 0)
    assert_equal(1, state.fetch("grammars").fetch(File.realpath(@grammar)).fetch("build_streak"))
    second = generation(settings: "motion=off,trail=none")
    assert_equal(0, second.wait_exit)
    assert_equal(2, read_profile.fetch("generation_runs"))
  end

  def test_generation_failure_resets_the_same_grammar_streak_and_preserves_exit_status
    2.times { assert_equal(0, generation(settings: "motion=off,trail=none").wait_exit) }
    assert_path_exist(@path)
    previous = read_profile
    assert_equal(2, previous.fetch("grammars").fetch(File.realpath(@grammar)).fetch("build_streak"))
    FileUtils.cp(File.join(FIXTURES, "broken.y"), @grammar)
    baseline = run_command(:lrama, ["grammar.y", "-o", "parser.c"], directory: @directory)
    driver = generation(settings: "motion=off,trail=none")
    assert_equal(1, baseline.fetch(:status))
    assert_equal(baseline.fetch(:status), driver.wait_exit)
    state = read_profile
    assert_equal(3, state.fetch("generation_runs"))
    assert_equal(previous.fetch("xp"), state.fetch("xp"))
    grammar = state.fetch("grammars").fetch(File.realpath(@grammar))
    assert_equal(0, grammar.fetch("build_streak"))
    assert_false(grammar.fetch("success"))
  end

  def test_daily_intro_is_shared_between_cli_processes
    first = generation(settings: "intro=daily,trail=none")
    assert_equal(0, first.wait_exit)
    assert_include(first.raw_output, "DOPARSERB")
    assert_path_exist(@path)
    assert_equal(Date.today.iso8601, read_profile.fetch("intro_day"))
    second = generation(settings: "intro=daily,trail=none")
    assert_equal(0, second.wait_exit)
    assert_not_include(second.raw_output, "DOPARSERB")
    assert_equal(2, read_profile.fetch("generation_runs"))
  end

  def test_interactive_status_reads_level_and_records_without_changing_the_profile
    seed_profile
    original = profile_snapshot
    driver = terminal("status")
    assert_equal(0, driver.wait_exit)
    ["LV 3", "XP 1024", "137", "16", "64"].each do |value|
      assert_include(driver.all_text, value)
    end
    assert_equal(original, profile_snapshot)
    assert_equal(["profile.json"], Dir.children(File.dirname(@path)))
  end

  def test_status_with_redirected_stderr_does_not_read_the_selected_profile
    seed_profile
    original = profile_snapshot
    wrapper = 'STDERR.reopen(ARGV.shift, "w"); load ARGV.shift'
    driver = PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", wrapper,
                            File.join(@directory, "stderr.log"), File.join(ROOT, "exe/doparserb"), "status"],
                           directory: @directory, env: profile_environment)
    @drivers << driver
    assert_equal(0, driver.wait_exit)
    output = driver.all_text + File.read(File.join(@directory, "stderr.log"))
    assert_not_include(output, "LV 3")
    assert_not_include(output, "XP 1024")
    assert_equal(original, profile_snapshot)
    assert_equal(["profile.json"], Dir.children(File.dirname(@path)))
  end

  def test_noninteractive_commands_leave_the_selected_profile_untouched
    seed_profile
    original = profile_snapshot
    commands = [
      ["status"], ["ranch"], ["ranch", "tour"], ["demo", "--dopa-set", "motion=off,trail=none"],
      ["grammar.y", "-o", "parser.c"],
      ["play", "--", RbConfig.ruby, "-e", "puts 'CHILD OUTPUT'; exit 23"]
    ]
    commands.each do |arguments|
      result = run_command(:doparserb, arguments, directory: @directory,
                           env: profile_environment.merge("TERM" => "xterm-256color"))
      assert_equal(arguments.first == "play" ? 23 : 0, result.fetch(:status), arguments.inspect)
      assert_equal(original, profile_snapshot, arguments.inspect)
      assert_equal(["profile.json"], Dir.children(File.dirname(@path)), arguments.inspect)
      if arguments.first == "status"
        assert_not_include(result.fetch(:stdout) + result.fetch(:stderr), "XP 1024")
      elsif arguments.first == "play"
        assert_equal("CHILD OUTPUT\n", result.fetch(:stdout))
      end
    end
  end

  def test_interactive_demo_does_not_change_career
    seed_profile
    original = profile_snapshot
    driver = terminal("demo", "--dopa-set", "motion=off,trail=none")
    assert_equal(0, driver.wait_exit)
    assert_equal(original, profile_snapshot)
    assert_equal(["profile.json"], Dir.children(File.dirname(@path)))
  end

  private

  def profile_environment
    {"DOPAPARSER_PROFILE" => @path}
  end

  def terminal(*arguments)
    driver = PTYDriver.doparserb(*arguments, directory: @directory, env: profile_environment)
    @drivers << driver
    driver
  end

  def generation(settings:)
    terminal("--dopa-runtime=off", "--dopa-set", "duration=0.1,#{settings}", "grammar.y", "-o", "parser.c")
  end

  def read_profile
    JSON.parse(File.binread(@path))
  end

  def seed_profile
    state = Doparserb::Profile.new(interactive: false, env: {}).read.merge(
      "xp" => 1024, "level" => 3, "best_score" => 137, "best_chain" => 16, "highest_tower" => 64
    )
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, JSON.generate(state))
    File.utime(Time.at(1_000_000_000), Time.at(1_000_000_000), @path)
  end

  def profile_snapshot
    [File.binread(@path), File.stat(@path).mtime]
  end
end
