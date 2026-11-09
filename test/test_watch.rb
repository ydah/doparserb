# frozen_string_literal: true

require_relative "test_helper"
require "json"

class WatchTest < Test::Unit::TestCase
  include CommandTest

  class BadgeEngine
    attr_reader :badges, :open

    def initialize
      @badges = []
      @open = false
    end

    def session
      @open = true
      yield self
    ensure
      @open = false
    end

    def badge(text) = @badges << text
  end

  def setup
    @directory = Dir.mktmpdir("doparserb-watch")
    @path = File.join(@directory, "grammar.y")
    File.write(@path, "first")
    @time = 0.0
    @sleeps = 0
    @engine = BadgeEngine.new
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_initial_build_and_stable_save_run_once_each_without_an_idle_lock
    builds = []
    watcher = watch do
      assert_false(@engine.open, "watch must release the terminal while waiting for a save")
      File.write(@path, "second") if @sleeps == 1
      raise Interrupt if @sleeps == 8
    end
    assert_equal(130, watcher.run { |observe| builds << File.read(@path); observe.call(stats) })
    assert_equal(%w[first second], builds)
    assert_equal(8, @sleeps)
    assert_equal(2, @engine.badges.length)
    assert_include(@engine.badges.last, "CONFLICTS 3")
  end

  def test_atomic_replacement_with_the_same_size_and_mtime_is_detected
    original_time = File.mtime(@path)
    builds = []
    watcher = watch do
      if @sleeps == 1
        replacement = File.join(@directory, "replacement")
        File.write(replacement, "other")
        File.utime(original_time, original_time, replacement)
        File.rename(replacement, @path)
      end
      raise Interrupt if @sleeps == 7
    end
    watcher.run { |observe| builds << File.read(@path); observe.call(stats) }
    assert_equal(%w[first other], builds)
  end

  def test_bursts_debounce_until_the_last_write_is_stable
    builds = []
    watcher = watch do
      File.write(@path, "write#{@sleeps}") if (1..3).cover?(@sleeps)
      raise Interrupt if @sleeps == 9
    end
    watcher.run { |observe| builds << File.read(@path); observe.call(stats) }
    assert_equal(%w[first write3], builds)
  end

  def test_a_save_during_generation_triggers_a_followup_build
    builds = []
    watcher = watch { raise Interrupt if @sleeps == 8 }
    watcher.run do |observe|
      builds << File.read(@path)
      File.write(@path, "saved while generating") if builds.length == 1
      observe.call(stats)
    end
    assert_equal(["first", "saved while generating"], builds)
  end

  def test_temporary_deletion_waits_without_generating_until_the_file_returns
    builds = []
    watcher = watch do
      File.unlink(@path) if @sleeps == 1
      File.write(@path, "restored") if @sleeps == 4
      raise Interrupt if @sleeps == 10
    end
    watcher.run { |observe| builds << File.read(@path); observe.call(stats) }
    assert_equal(%w[first restored], builds)
  end

  def test_a_failed_build_keeps_watching_and_shows_unknown_conflicts_until_fixed
    builds = 0
    watcher = watch do
      File.write(@path, "fixed") if @sleeps == 1
      raise Interrupt if @sleeps == 8
    end
    status = watcher.run do |observe|
      builds += 1
      if builds == 1
        observe.call(stats.merge(success: false, states: 0, failure: {kind: :grammar_break}))
        raise SystemExit, 1
      end
      observe.call(stats.merge(sr_conflicts: 0))
    end
    assert_equal(130, status)
    assert_equal(2, builds)
    assert_include(@engine.badges.first, "CONFLICTS ?")
    assert_include(@engine.badges.first, "FAILED")
    assert_include(@engine.badges.last, "CONFLICTS 0")
  end

  def test_help_and_argument_errors_terminate_without_watching
    [0, 1].each do |exit_status|
      watcher = watch { flunk("an argument error or help request must not keep watching") }
      result = watcher.run do |observe|
        observe.call({success: false})
        raise SystemExit, exit_status
      end
      assert_equal(exit_status, result)
    end
    assert_empty(@engine.badges)
  end

  def test_a_file_removed_before_command_initialization_is_retried_after_restoration
    FileUtils.cp(File.join(FIXTURES, "prec.y"), @path)
    program = <<~'RUBY'
      require "doparserb"
      require "json"
      path, restore_early = ARGV
      backup = "#{path}.backup"
      clock = 0.0
      sleeps = 0
      builds = 0
      watcher = Doparserb::Watch.new(path, config: Doparserb::Config.new(mode: "off"),
        clock: -> { clock }, sleeper: ->(seconds) {
          clock += seconds
          sleeps += 1
          File.rename(backup, path) if File.exist?(backup)
          raise Interrupt if sleeps == 8
        })
      status = watcher.run do |observe|
        builds += 1
        File.rename(path, backup) if builds == 1
        bus = Doparserb::EventBus.new
        begin
          Doparserb::Command.new([path, "-o", "parser.c"], events: bus, runtime: "off").run
        ensure
          File.rename(backup, path) if restore_early == "true" && File.exist?(backup)
          bus.close
          observe.call(Doparserb::Gen::Collector.new.collect(bus).to_h)
        end
      end
      puts JSON.generate(status: status, builds: builds)
    RUBY
    [false, true].each do |restore_early|
      stdout, stderr, status = Open3.capture3(ENVIRONMENT, RbConfig.ruby, "-I#{ROOT}/lib", "-e", program,
                                             @path, restore_early.to_s, chdir: @directory)
      File.rename("#{@path}.backup", @path) if File.exist?("#{@path}.backup")
      assert_equal(0, status.exitstatus, stderr)
      assert_include(stderr, "No such file")
      assert_equal({"status" => 130, "builds" => 2}, JSON.parse(stdout), "restore_early=#{restore_early}")
      assert_path_exist(File.join(@directory, "parser.c"))
    end
  end

  def test_interruption_during_generation_unwinds_the_builder
    cleaned = false
    watcher = watch { flunk("interrupted build must not keep watching") }
    result = watcher.run do |_observe|
      begin
        raise Interrupt
      ensure
        cleaned = true
      end
    end
    assert_equal(130, result)
    assert_true(cleaned)
    assert_false(@engine.open)
  end

  def test_runtime_configuration_and_io_errors_remain_fatal
    [Doparserb::Error, IOError, Errno::EACCES].each do |error_class|
      watcher = watch { flunk("an operational failure must not keep watching") }
      error = error_class.new("fatal failure")
      actual = assert_raise(error_class) do
        watcher.run do |observe|
          observe.call(stats.merge(success: false, failure: {kind: :validation_break}))
          raise error
        end
      end
      assert_same(error, actual)
    end
    assert_empty(@engine.badges)
  end

  def test_badge_failures_do_not_stop_regeneration
    @engine.define_singleton_method(:badge) { |_| raise IOError, "broken terminal" }
    builds = 0
    watcher = watch do
      File.write(@path, "second") if @sleeps == 1
      raise Interrupt if @sleeps == 8
    end
    assert_equal(130, watcher.run { |observe| builds += 1; observe.call(stats) })
    assert_equal(2, builds)
  end

  def test_initial_input_must_be_an_existing_regular_file
    fifo = File.join(@directory, "fifo")
    File.mkfifo(fifo)
    [nil, "-", "--help", @directory, fifo, File.join(@directory, "missing")].each do |path|
      assert_raise(Doparserb::Error, path.inspect) do
        Doparserb::Watch.new(path, config: Doparserb::Config.new(env: {})).run { flunk("invalid input was opened") }
      end
    end
  end

  def test_repeated_cli_generation_retains_output_header_and_grammar_arguments
    FileUtils.cp(File.join(FIXTURES, "prec.y"), @path)
    program = <<~'RUBY'
      require "doparserb"
      require "json"
      Doparserb::Watch.prepend(Module.new do
        def run
          results = []
          2.times do |index|
            File.open(ARGV[1], "a") { |file| file.puts("/* WATCH SECOND BUILD */") } if index == 1
            yield ->(stats) { results << stats.fetch(:success) }
          end
          File.write("observed.json", JSON.generate(results))
          23
        end
      end)
      exit Doparserb::CLI.new(ARGV).run
    RUBY
    stdout, stderr, status = Open3.capture3(ENVIRONMENT, RbConfig.ruby, "-I#{ROOT}/lib", "-e", program,
                                           "watch", @path, "-d", "-o", "chosen.c", "--dopa=off", "--dopa-runtime=off", chdir: @directory)
    assert_equal(23, status.exitstatus, stderr)
    assert_empty(stdout)
    assert_path_exist(File.join(@directory, "chosen.h"))
    assert_include(File.read(File.join(@directory, "chosen.c")), "WATCH SECOND BUILD")
    assert_false(File.exist?(File.join(@directory, "y.tab.c")))
    assert_equal([true, true], JSON.parse(File.read(File.join(@directory, "observed.json"))))
  end

  private

  def watch(&on_sleep)
    Doparserb::Watch.new(@path, config: Doparserb::Config.new(env: {}), engine: @engine,
                         clock: -> { @time }, sleeper: ->(seconds) { @time += seconds; @sleeps += 1; on_sleep.call })
  end

  def stats
    {grammar: @path, success: true, states: 12, sr_conflicts: 3, rr_conflicts: 0, failure: nil}
  end
end
