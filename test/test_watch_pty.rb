# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_driver"
require "json"
require "pathname"

class WatchPTYTest < Test::Unit::TestCase
  include CommandTest

  def setup
    @directory = Dir.mktmpdir("doparserb-watch-pty")
    @grammar = File.join(@directory, "grammar.y")
    @output = File.join(@directory, "parser.c")
    @profile = File.join(@directory, "profile.json")
    @debug = File.join(@directory, "debug.log")
    @drivers = []
    write_grammar("prec", "INITIAL")
  end

  def teardown
    @drivers.each(&:close)
    FileUtils.remove_entry(@directory)
  end

  def test_save_updates_conflict_hud_and_keeps_header_and_output_options
    write_grammar("conflicts", "INITIAL")
    baseline = run_command(:doparserb, ["--dopa-debug-events", "grammar.y", "-o", "baseline.c"], directory: @directory)
    stats = JSON.parse(baseline[:stderr].lines.last)
    count = stats.fetch("sr_conflicts") + stats.fetch("rr_conflicts")
    assert_operator(count, :>, 0)
    driver = watcher
    driver.wait_for("* WATCH * CONFLICTS #{count}  READY")
    assert_path_exist(File.join(@directory, "parser.h"))
    replacement = File.join(@directory, "replacement.y")
    File.write(replacement, File.read(File.join(FIXTURES, "prec.y")) + "\n/* SAVED ATOMICALLY */\n")
    File.rename(replacement, @grammar)
    driver.wait_for("* WATCH * CONFLICTS 0  READY")
    assert_include(File.read(@output), "SAVED ATOMICALLY")
    assert_path_exist(File.join(@directory, "parser.h"))
    assert_false(File.exist?(File.join(@directory, "y.tab.c")))
    driver.send_keys("\x03")
    assert_equal(130, driver.wait_exit)
    assert_not_include(driver.all_text, "Interrupt")
    assert_empty(driver.unknown)
  end

  def test_grammar_failure_keeps_original_diagnostics_and_recovers_after_save
    write_grammar("broken", "BROKEN")
    baseline = PTYDriver.doparserb("--dopa=off", "--dopa-runtime=off", "grammar.y", "-o", "parser.c", directory: @directory)
    @drivers << baseline
    assert_equal(1, baseline.wait_exit)
    driver = watcher
    driver.wait_for("* WATCH * CONFLICTS ?  FAILED")
    baseline.all_text.lines.map(&:strip).reject(&:empty?).each do |line|
      assert_include(driver.all_text, line)
    end
    write_grammar("prec", "FIXED")
    driver.wait_for("* WATCH * CONFLICTS 0  READY")
    assert_include(File.read(@output), "FIXED")
    driver.send_keys("\x03")
    assert_equal(130, driver.wait_exit)
    assert_empty(driver.unknown)
  end

  def test_debug_validation_failure_recovers_after_save
    write_grammar("validation", "INVALID")
    File.write(@grammar, "%no-stdlib\n" + File.read(@grammar))
    driver = PTYDriver.doparserb("watch", "grammar.y", "-t", "-o", "parser.c", "--dopa-runtime=off",
                                "--dopa-set", "motion=off,intro=off", directory: @directory)
    @drivers << driver
    driver.wait_for("* WATCH * CONFLICTS ?  FAILED")
    assert_include(driver.raw_output, "redeclaration")
    write_grammar("prec", "VALIDATED")
    File.write(@grammar, "%no-stdlib\n" + File.read(@grammar))
    driver.wait_for("* WATCH * CONFLICTS 0  READY")
    assert_include(File.read(@output), "VALIDATED")
    driver.send_keys("\x03")
    assert_equal(130, driver.wait_exit)
    assert_empty(driver.unknown)
  end

  def test_an_idle_watcher_does_not_hold_the_terminal_against_another_generator
    marker = File.join(@directory, "run-second")
    program = <<~'RUBY'
      require "doparserb"
      root, marker = ARGV.shift(2)
      watcher = fork do
        exit Doparserb::CLI.new(["watch", "grammar.y", "-o", "parser.c", "--dopa-runtime=off", "--dopa-set", "motion=off"]).run
      end
      begin
        sleep 0.01 until File.exist?(marker)
        second = Process.spawn(RbConfig.ruby, "-I#{root}/lib", "#{root}/exe/doparserb", "grammar.y", "-o", "second.c", "--dopa-runtime=off", "--dopa-set", "motion=off")
        _, status = Process.waitpid2(second)
        puts "SECOND GENERATOR EXIT:#{status.exitstatus}"
        Process.kill("INT", watcher)
        _, status = Process.waitpid2(watcher)
        watcher = nil
        exit status.exitstatus
      ensure
        Process.kill("KILL", watcher) if watcher
      end
    RUBY
    driver = PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", program, ROOT, marker], directory: @directory)
    @drivers << driver
    driver.wait_for("* WATCH * CONFLICTS 0  READY")
    File.write(marker, "go")
    driver.wait_for("SECOND GENERATOR EXIT:0", timeout: 3)
    assert_equal(130, driver.wait_exit)
    assert_path_exist(File.join(@directory, "second.c"))
    assert_empty(driver.unknown)
  end

  def test_noninteractive_watch_has_no_hud_and_never_reads_or_updates_profile
    File.write(@profile, "preserve this invalid profile")
    original = [File.read(@profile), File.mtime(@profile)]
    env = ENVIRONMENT.merge("TERM" => "xterm-256color", "DOPAPARSER_PROFILE" => @profile, "DOPAPARSER_DEBUG" => @debug)
    command = [RbConfig.ruby, "-I#{ROOT}/lib", File.join(ROOT, "exe/doparserb"), "watch", "grammar.y", "-d", "-o", "parser.c", "--dopa-runtime=off"]
    stdin, stdout, stderr, process = Open3.popen3(env, *command, chdir: @directory)
    stdin.close
    readers = [stdout, stderr].map { |io| Thread.new { io.read } }
    wait_until { File.file?(@output) && File.read(@output).include?("INITIAL") }
    write_grammar("prec", "SECOND NONINTERACTIVE BUILD")
    wait_until { File.read(@output).include?("SECOND NONINTERACTIVE BUILD") }
    Process.kill("INT", process.pid)
    status = Timeout.timeout(3) { process.value }
    output, errors = readers.map(&:value)
    assert_equal(130, status.exitstatus)
    assert_empty(output)
    assert_not_include(errors, "WATCH")
    assert_not_include(errors, "\e")
    assert_equal(original, [File.read(@profile), File.mtime(@profile)])
    assert_false(File.exist?("#{@profile}.lock"))
    assert_false(File.exist?(@debug), "reading the invalid profile would have logged an error")
  ensure
    Process.kill("KILL", process.pid) if process&.alive?
    process&.join
    [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
    readers&.each(&:join)
  end

  def test_dumb_and_off_watchers_are_quiet_and_leave_profiles_untouched
    File.write(@profile, "preserve this invalid profile")
    original = [File.read(@profile), File.mtime(@profile)]
    [{"TERM" => "dumb"}, {"DOPAPARSER" => "off"}].each_with_index do |env, index|
      write_grammar("prec", "INITIAL #{index}")
      driver = watcher(env: env.merge("DOPAPARSER_PROFILE" => @profile, "DOPAPARSER_DEBUG" => @debug))
      wait_until { File.file?(@output) && File.read(@output).include?("INITIAL #{index}") }
      write_grammar("prec", "QUIET SAVE #{index}")
      wait_until { File.read(@output).include?("QUIET SAVE #{index}") }
      driver.send_keys("\x03")
      assert_equal(130, driver.wait_exit)
      assert_not_include(driver.raw_output, "\e")
      assert_not_include(driver.all_text, "WATCH")
      assert_equal(original, [File.read(@profile), File.mtime(@profile)])
      assert_false(File.exist?("#{@profile}.lock"))
      assert_false(File.exist?(@debug))
    end
  end

  def test_help_and_unknown_options_exit_instead_of_waiting_for_an_edit
    [[%w[watch --help], 0], [%w[watch grammar.y --help], 0], [%w[watch grammar.y --definitely-invalid], 1], [%w[watch - grammar.y], 1]].each do |arguments, expected|
      result = Timeout.timeout(3) { run_command(:doparserb, arguments, directory: @directory) }
      assert_equal(expected, result[:status], result[:stderr])
      assert_not_include(result[:stderr], "* WATCH *")
    end
  end

  def test_unsupported_runtime_skeleton_exits_without_replacing_existing_output
    skeleton = File.join(@directory, "unsupported.c")
    File.write(skeleton, File.read(File.join(LRAMA_ROOT, "template/bison/yacc.c")).sub("yyacceptlab:", "yyacceptlab :"))
    relative = Pathname.new(skeleton).relative_path_from(Pathname.new(File.join(LRAMA_ROOT, "template"))).to_s
    File.write(@output, "existing parser")
    arguments = ["watch", "grammar.y", "--skeleton", relative, "-o", "parser.c", "--dopa=off"]
    result = Timeout.timeout(3) { run_command(:doparserb, arguments, directory: @directory) }
    assert_equal(1, result[:status], result[:stderr])
    assert_include(result[:stderr], "--dopa-runtime=off")
    assert_equal("existing parser", File.read(@output))
  end

  private

  def write_grammar(name, marker)
    File.write(@grammar, File.read(File.join(FIXTURES, "#{name}.y")) + "\n/* #{marker} */\n")
  end

  def watcher(env: {})
    driver = PTYDriver.doparserb("watch", "grammar.y", "-d", "-o", "parser.c", "--dopa-runtime=off", "--dopa-set", "motion=off,intro=off", directory: @directory, env: env)
    @drivers << driver
    driver
  end

  def wait_until
    Timeout.timeout(5) { sleep 0.01 until yield }
  end
end
