# frozen_string_literal: true

require_relative "support/runtime_helpers"
require_relative "support/pty_driver"

class PlayPTYTest < Test::Unit::TestCase
  include RuntimeHelpers

  EVENT_PRELUDE = <<~'RUBY'
    require "socket"
    socket = Socket.for_fd(Integer(ENV.fetch("DOPAPARSER_FD")))
    socket.autoclose = false
    def events(socket, id = 1)
      socket.send("F 0123abcd #{Process.pid} #{id}\nB\nT 3 1 1\nS 3 1 1\nR 2 1 0 1\nA\n", 0)
    end
    STDOUT.sync = STDERR.sync = true
  RUBY

  def teardown = cleanup_runtime

  def test_p1_interactive_calculator_preserves_output_and_clears_temporary_frames
    build = build_parser("runtime_calc")
    baseline = PTYDriver.new([build[:executable]], env: {"DOPAPARSER" => "off", "PARSER_READY" => "1"})
    drive_calculator(baseline)
    expected = baseline.all_text
    baseline.close
    driver = play(build[:executable], env: {"PARSER_READY" => "1"})
    driver.wait_for("CALC READY")
    driver.send_keys("1+2*3\n")
    driver.wait_for("=> 7")
    driver.wait_for("SHIFT", raw: true, timeout: 3)
    offset = driver.raw_output.bytesize
    driver.send_keys("(1+2)*3\n")
    driver.wait_for("=> 9")
    Timeout.timeout(3) { sleep 0.005 until driver.raw_output.byteslice(offset..).include?("SHIFT") }
    driver.send_keys("\x04")
    assert_equal(0, driver.wait_exit)
    assert_equal(expected, without_badges(driver.all_text))
    assert_include(driver.raw_output, "STACK TOWER")
    assert_include(driver.raw_output, "STAGE CLEAR")
    assert_equal({}, driver.unknown)
  ensure
    baseline&.close
    driver&.close
  end

  def test_p2_unicode_input_during_replay_reaches_child_without_lost_bytes
    bytes = "alpha λ あ 123"
    program = EVENT_PRELUDE + <<~RUBY
      require "io/console"
      puts "READY"
      events(socket)
      received = STDIN.raw { STDIN.read(#{bytes.bytesize}) }
      puts "BYTES:" + received.unpack1("H*")
    RUBY
    driver = play(RbConfig.ruby, "-e", program, replay: "full", speed: 2)
    driver.wait_for("READY")
    driver.wait_for("STACK TOWER", raw: true)
    driver.send_keys(bytes)
    driver.wait_for("BYTES:#{bytes.unpack1('H*')}")
    assert_equal(0, driver.wait_exit)
    assert_include(driver.all_text, "BYTES:#{bytes.unpack1('H*')}")
  ensure
    driver&.close
  end

  def test_partial_prompt_survives_until_child_finishes_its_line
    program = EVENT_PRELUDE + <<~'RUBY'
      STDOUT.write("PROMPT> ")
      events(socket)
      value = STDIN.gets
      puts "RECEIVED:" + value.to_s.strip
    RUBY
    driver = play(RbConfig.ruby, "-e", program)
    driver.wait_for("PROMPT>")
    sleep 0.15
    assert_include(driver.all_text, "PROMPT>")
    driver.send_keys("hello\n")
    assert_equal(0, driver.wait_exit)
    assert_include(driver.all_text, "PROMPT> hello")
    assert_include(driver.all_text, "RECEIVED:hello")
  ensure
    driver&.close
  end

  def test_p3_control_c_reaches_child_and_play_terminates_with_sigint
    program = <<~'RUBY'
      STDOUT.sync = true
      Signal.trap("INT") do
        puts "GOT INT"
        Signal.trap("INT", "DEFAULT")
        Process.kill("INT", Process.pid)
      end
      puts "READY"
      sleep
    RUBY
    driver = play(RbConfig.ruby, "-e", program)
    driver.wait_for("READY")
    driver.send_keys("\x03")
    assert_equal(130, driver.wait_exit)
    assert_include(driver.all_text, "GOT INT")
    assert_equal(2, driver.status.termsig)
  ensure
    driver&.close
  end

  def test_p4_child_exit_codes_and_signals_are_preserved
    driver = nil
    [0, 1, 37].each do |code|
      driver = play(RbConfig.ruby, "-e", "puts 'CHILD OUTPUT'; exit #{code}")
      assert_equal(code, driver.wait_exit)
      assert_equal("CHILD OUTPUT", driver.all_text)
      driver.close
    end
    driver = play(RbConfig.ruby, "-e", 'Process.kill("TERM", Process.pid)')
    assert_equal(143, driver.wait_exit)
    assert_equal(15, driver.status.termsig)
  ensure
    driver&.close
  end

  def test_p5_redirected_stdin_preserves_bytes_and_eof
    Dir.mktmpdir("doparserb-play-input") do |directory|
      path = File.join(directory, "input.bin")
      bytes = "a\0b\n\xFF".b
      File.binwrite(path, bytes)
      wrapper = 'STDIN.reopen(ARGV.shift); load ARGV.shift'
      driver = PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", wrapper, path, File.join(ROOT, "exe/doparserb"),
                              "play", "--", RbConfig.ruby, "-e", 'puts STDIN.read.unpack1("H*")'])
      assert_equal(0, driver.wait_exit)
      assert_equal(bytes.unpack1("H*"), driver.all_text)
    ensure
      driver&.close
    end
  end

  def test_p6_redirected_stdout_remains_exact_while_stderr_and_events_are_relayed
    Dir.mktmpdir("doparserb-play-output") do |directory|
      path = File.join(directory, "output.bin")
      wrapper = 'STDOUT.reopen(ARGV.shift, "wb"); load ARGV.shift'
      program = EVENT_PRELUDE + <<~'RUBY'
        STDOUT.binmode
        STDOUT.write([0, 255, 10, 27, 91, 50, 74].pack("C*"))
        STDERR.puts "DIAGNOSTIC"
        events(socket)
      RUBY
      driver = PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", wrapper, path, File.join(ROOT, "exe/doparserb"),
                              "play", "--dopa-set", "duration=0.1", "--", RbConfig.ruby, "-e", program])
      assert_equal(0, driver.wait_exit)
      assert_equal([0, 255, 10, 27, 91, 50, 74].pack("C*"), File.binread(path))
      assert_include(driver.all_text, "DIAGNOSTIC")
      assert_include(driver.raw_output, "STAGE CLEAR")
    ensure
      driver&.close
    end
  end

  def test_p7_resize_reaches_child_and_later_frames_use_new_width
    program = EVENT_PRELUDE + <<~'RUBY'
      require "io/console"
      Signal.trap("WINCH") { puts "WINDOW:" + STDOUT.winsize.join("x") }
      puts "READY"
      value = STDIN.gets
      puts "VALUE:" + value.to_s.strip
      events(socket)
    RUBY
    driver = play(RbConfig.ruby, "-e", program)
    driver.wait_for("READY")
    driver.resize(rows: 24, cols: 30)
    driver.wait_for("WINDOW:24x30")
    driver.send_keys("frame\n")
    assert_equal(0, driver.wait_exit)
    assert_include(driver.all_text, "VALUE:frame")
    assert_include(driver.raw_output, "STACK TOWER")
    assert_equal({}, driver.unknown)
    assert(driver.lines.all? { |line| line.length <= 30 })
  ensure
    driver&.close
  end

  def test_redirecting_both_outputs_does_not_write_terminal_echo_into_either_file
    driver = nil
    Dir.mktmpdir("doparserb-play-stdin-only") do |directory|
      output_path = File.join(directory, "output.txt")
      error_path = File.join(directory, "error.txt")
      ready_path = File.join(directory, "ready")
      wrapper = 'STDOUT.reopen(ARGV.shift, "w"); STDERR.reopen(ARGV.shift, "w"); load ARGV.shift'
      program = 'File.write(ARGV.shift, "ready"); value = STDIN.gets; STDOUT.write("VALUE:" + value); STDERR.write("DIAGNOSTIC\n")'
      driver = PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", wrapper, output_path, error_path,
                              File.join(ROOT, "exe/doparserb"), "play", "--", RbConfig.ruby, "-e", program, ready_path])
      Timeout.timeout(5) { sleep 0.005 until File.exist?(ready_path) }
      driver.send_keys("hello\n")
      assert_equal(0, driver.wait_exit)
      assert_equal("VALUE:hello\n", File.read(output_path))
      assert_equal("DIAGNOSTIC\n", File.read(error_path))
    end
  ensure
    driver&.close
  end

  def test_p8_full_replay_at_twenty_events_per_second_preserves_every_depth
    build = build_parser("runtime_calc")
    input = "1\n"
    result, chunks = capture_events(build, input)
    assert_equal(0, result.last)
    protocol = Doparserb::Play::Protocol.new(executable: build[:executable])
    tower = Doparserb::Play::Tower.new
    expected = chunks.flat_map do |chunk|
      protocol.consume(chunk).map do |event|
        tower.consume(event, metadata: protocol.metadata(event[:parser], event[:pid]))
        [event[:code], tower.to_h[:depth]]
      end
    end
    input_path = File.join(build[:directory], "input.txt")
    frames_path = File.join(build[:directory], "frames.jsonl")
    File.write(input_path, input)
    wrapper = <<~'RUBY'
      require "json"
      require "doparserb"
      STDIN.reopen(ARGV.shift)
      path = ARGV.shift
      Doparserb::Engine.prepend(Module.new do
        define_method(:frame) do |kind, **options|
          data = options.fetch(:data, {})
          if event = data[:event]
            File.open(path, "a") do |file|
              file.puts(JSON.generate([event[:code], data[:depth], Process.clock_gettime(Process::CLOCK_MONOTONIC)]))
            end
          end
          super(kind, **options)
        end
      end)
      load ARGV.shift
    RUBY
    driver = PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", wrapper, input_path, frames_path,
                            File.join(ROOT, "exe/doparserb"), "play", "--replay=full", "--speed=20", "--", build[:executable]])
    assert_equal(0, driver.wait_exit)
    frames = File.readlines(frames_path).map { |line| JSON.parse(line) }
    assert_equal(expected, frames.map { |code, depth, _| [code, depth] })
    assert_operator(frames.last.last - frames.first.last, :>=, (frames.length - 1) / 20.0 * 0.85)
    assert_include(driver.all_text, "STAGE CLEAR")
  ensure
    driver&.close
  end

  private

  def play(*command, env: {}, replay: "highlight", speed: 30)
    PTYDriver.doparserb("play", "--replay=#{replay}", "--speed=#{speed}", "--dopa-set", "duration=0.1", "--", *command, env: env)
  end

  def drive_calculator(driver)
    driver.wait_for("CALC READY")
    driver.send_keys("1+2*3\n")
    driver.wait_for("=> 7")
    driver.send_keys("(1+2)*3\n")
    driver.wait_for("=> 9")
    driver.send_keys("\x04")
    assert_equal(0, driver.wait_exit)
  end

  def without_badges(text)
    text.lines.reject { |line| line.start_with?("* ") }.join.rstrip
  end
end
