# frozen_string_literal: true

require_relative "support/runtime_helpers"
require_relative "support/pty_driver"

class RuntimeIntegrationTest < Test::Unit::TestCase
  include RuntimeHelpers

  def teardown = cleanup_runtime

  def test_default_generation_embeds_hooks_even_without_presentation
    build = build_parser("runtime_calc")
    assert(build[:source].include?("DOPA_BEGIN"), "runtime hook missing from generated C")
    result, chunks = capture_events(build, "1+2*3\n")
    assert_equal(["=> 7\n", "", 0], result)
    assert_include(event_lines(chunks).map(&:first), "A")
  end

  def test_c1_samples_preserve_outputs_and_status_with_both_compilers
    COMPILERS.each do |compiler|
      SAMPLE_INPUTS.each do |name, inputs|
        baseline = build_parser(name, runtime: false, compiler: compiler)
        observed = build_parser(name, compiler: compiler)
        assert_operator(observed[:warnings].scan("warning:").length, :<=,
                        baseline[:warnings].scan("warning:").length, observed[:warnings])
        inputs.each do |input|
          result, = capture_events(observed, input)
          assert_equal(run_parser(baseline, input), result, "#{compiler}: #{name} #{input.inspect}")
        end
      end
    end
  end

  def test_c3_shift_reduce_events_match_debug_output_and_stack_depth
    build = build_parser("runtime_calc", flags: ["-DYYDEBUG=1"])
    result, chunks = capture_events(build, "1+2*3\n(4+5)*6\n", env: {"PARSER_DEBUG" => "1"})
    assert_equal(0, result.last)
    events = event_lines(chunks)
    assert_equal("B", events.first.first)
    assert_equal("A", events.last.first)
    assert_equal(result[1].scan(/^Shifting token /).length, events.count { |event| event.first == "S" })
    assert_equal(result[1].scan(/^Reducing stack by rule /).length, events.count { |event| event.first == "R" })
    depth = 0
    events.each do |code, *values|
      case code
      when "S"
        assert_equal(depth + 1, values.last.to_i)
        depth += 1
      when "R"
        _, length, _, previous = values.map(&:to_i)
        assert_equal(depth, previous)
        depth = previous - length + 1
      end
      assert_operator(depth, :>=, 0)
    end
    assert_equal(2, depth)
    assert(events.any? { |event| event[0] == "R" && event[2] == "0" }, "empty reduction missing")
    assert(events.any? { |event| event[0] == "T" && event[1] == "0" }, "EOF preview missing")
  end

  def test_error_recovery_explicit_actions_and_scanner_errors_preserve_behavior
    baseline = build_parser("runtime_calc", runtime: false)
    observed = build_parser("runtime_calc")
    {"1+\n2\n" => %w[E P X A], "!\n2\n" => %w[E P X A],
     "#\n2\n" => %w[E X A], "@" => %w[Z], "?" => %w[A]}.each do |input, expected|
      result, chunks = capture_events(observed, input)
      assert_equal(run_parser(baseline, input), result)
      events = event_lines(chunks)
      expected.each { |code| assert_include(events.map(&:first), code, input.inspect) }
      events.select { |event| %w[S P X].include?(event.first) }.each do |event|
        assert_operator(event.last.to_i, :>=, 0)
      end
    end
  end

  def test_repair_hooks_compile_without_extra_warnings_and_report_insertions
    COMPILERS.each do |compiler|
      baseline = build_parser("runtime_sequence", runtime: false, repair: true, compiler: compiler)
      observed = build_parser("runtime_sequence", repair: true, compiler: compiler)
      assert_operator(observed[:warnings].scan("warning:").length, :<=,
                      baseline[:warnings].scan("warning:").length, observed[:warnings])
      result, chunks = capture_events(observed, "(aaa")
      assert_equal(run_parser(baseline, "(aaa"), result)
      codes = event_lines(chunks).map(&:first)
      %w[E Q I C A].each { |code| assert_include(codes, code) }
    end
  end

  def test_c4_closed_receiver_does_not_change_exit_or_output
    baseline = build_parser("runtime_calc", runtime: false)
    observed = build_parser("runtime_calc")
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    receiver.close
    assert_equal(run_parser(baseline, "1+2\n"), run_parser(observed, "1+2\n", socket: sender))
  ensure
    sender&.close
  end

  def test_c5_backpressure_drops_events_then_reports_loss_without_blocking
    build = build_parser("runtime_sequence")
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    sender.setsockopt(:SOCKET, :SNDBUF, 4096)
    chunks = []
    env = ENVIRONMENT.merge("DOPAPARSER_FD" => sender.fileno.to_s, "DOPAPARSER_FLUSH" => "batch")
    Timeout.timeout(5) do
      Open3.popen3(env, build[:executable], sender.fileno => sender) do |input, output, error, waiter|
        input.write("(" + "a" * 1024 + "|")
        input.flush
        assert_equal("READY\n", output.gets, "parser blocked before reaching the lexer barrier")
        drained = Queue.new
        reader = Thread.new do
          loop do
            chunks << receiver.recv_nonblock(2048)
          rescue IO::WaitReadable
            break
          end
          drained << true
          loop do
            chunk = receiver.recv(2048)
            break if chunk == "DONE"
            chunks << chunk
          end
        end
        drained.pop
        input.write("!a)")
        input.close
        assert_equal(0, waiter.value.exitstatus)
        assert_equal("", error.read)
        sender.send("DONE", 0)
        reader.join
      ensure
        receiver.close unless receiver.closed?
        reader&.join
      end
    end
    drops = event_lines(chunks).select { |event| event.first == "D" }.sum { |event| event[1].to_i }
    assert_operator(drops, :>, 0)
  ensure
    receiver&.close unless receiver&.closed?
    sender&.close
  end

  def test_c6_compile_time_disable_removes_runtime_symbols_and_metadata
    COMPILERS.each do |compiler|
      build = build_parser("runtime_calc", compiler: compiler, flags: ["-DDOPA_RT_DISABLE", "-O2"])
      symbols, error, status = Open3.capture3("nm", build[:executable])
      assert_equal(0, status.exitstatus, error)
      assert_not_include(symbols, "yydopa_")
      bytes = File.binread(build[:executable])
      assert(!bytes.include?('"generator":"doparserb'), "metadata remained in disabled binary")
      assert_equal(["=> 3\n", "", 0], run_parser(build, "1+2\n"))
    end
  end

  def test_c7_two_macro_renamed_parsers_link_and_run
    first = build_parser("runtime_calc")
    second = build_parser("runtime_sequence")
    directory = first[:directory]
    [[first, "parse_one", "first.o"], [second, "parse_two", "second.o"]].each do |build, name, file|
      _, error, status = Open3.capture3(COMPILERS.first, "-std=c99", "-DDOPA_TEST_NO_MAIN", "-Dyyparse=#{name}",
                                       "-c", File.join(build[:directory], "parser.c"), "-o", File.join(directory, file))
      assert_equal(0, status.exitstatus, error)
    end
    File.write(File.join(directory, "driver.c"), <<~C)
      #include <stdio.h>
      int parse_one(void);
      int parse_two(void);
      int main(int argc, char **argv) {
        int first, second;
        if (argc != 3 || !freopen(argv[1], "r", stdin)) return 2;
        first = parse_one();
        if (!freopen(argv[2], "r", stdin)) return 2;
        second = parse_two();
        return first || second;
      }
    C
    _, error, status = Open3.capture3(COMPILERS.first, "-std=c99", "driver.c", "first.o", "second.o", "-o", "both", chdir: directory)
    assert_equal(0, status.exitstatus, error)
    File.write(File.join(directory, "first.input"), "1+2\n")
    File.write(File.join(directory, "second.input"), "(aa)")
    output, error, status = Open3.capture3(ENVIRONMENT, "./both", "first.input", "second.input", chdir: directory)
    assert_equal(["=> 3\n", "", 0], [output, error, status.exitstatus])
  end

  def test_c8_badge_sink_respects_terminal_color_and_off_settings
    driver = nil
    build = build_parser("runtime_calc")
    input = File.join(build[:directory], "input.txt")
    File.write(input, "1+2*3\n")
    program = 'file = File.open(ARGV.shift); exec(ARGV.shift, in: file)'
    [{"NO_COLOR" => "1"}, {"TERM" => "dumb"}, {"DOPAPARSER" => "off"}].each do |env|
      driver = PTYDriver.new([RbConfig.ruby, "-e", program, input, build[:executable]], env: env)
      assert_equal(0, driver.wait_exit)
      assert_equal(env.key?("NO_COLOR") ? 1 : 0, driver.all_text.lines.count { |line| line.include?("STAGE CLEAR") })
      assert_not_include(driver.raw_output, "\e")
      assert_match(/\A=> 7\r?\n/, driver.raw_output)
      driver.close
    end
    assert_equal(["=> 7\n", "", 0], run_parser(build, "1+2*3\n", env: {"TERM" => "xterm"}))
  ensure
    driver&.close
  end

  def test_badge_fits_a_narrow_terminal_without_wrapping
    build = build_parser("runtime_calc")
    input = File.join(build[:directory], "input.txt")
    File.write(input, "1+2*3\n")
    program = 'file = File.open(ARGV.shift); exec(ARGV.shift, in: file)'
    driver = PTYDriver.new([RbConfig.ruby, "-e", program, input, build[:executable]], cols: 30, env: {"NO_COLOR" => "1"})
    assert_equal(0, driver.wait_exit)
    assert_equal(2, driver.all_text.lines.length, driver.all_text)
    assert_include(driver.all_text, "STAGE CLEAR")
  ensure
    driver&.close
  end

  def test_runtime_artifacts_are_identical_across_real_terminal_and_repeat_runs
    driver = nil
    Dir.mktmpdir("doparserb-runtime-determinism") do |directory|
      FileUtils.cp(File.join(FIXTURES, "runtime_calc.y"), File.join(directory, "grammar.y"))
      %w[embed sidecar].each do |mode|
        args = ["--dopa-meta=#{mode}", "--dopa-set", "duration=0.1,intro=off", "-d", "grammar.y", "-o", "parser.c"]
        result = run_command(:doparserb, args, directory: directory)
        assert_equal(0, result[:status], result[:stderr])
        expected = generated_files(directory, "grammar.y")
        driver = PTYDriver.doparserb(*args, directory: directory, env: {"DOPAPARSER_SEED" => "97531"})
        assert_equal(0, driver.wait_exit)
        assert(expected == generated_files(directory, "grammar.y"), "#{mode} artifacts depend on terminal availability")
        driver.close
        result = run_command(:doparserb, args, directory: directory)
        assert_equal(0, result[:status], result[:stderr])
        assert(expected == generated_files(directory, "grammar.y"), "#{mode} artifacts changed on repeat generation")
      end
    end
  ensure
    driver&.close
  end
end
