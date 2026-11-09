# frozen_string_literal: true

require_relative "test_helper"
require "erb"
require "json"
require "socket"
require "timeout"
require "pty"
require "io/console"

class CRuntimeUnitTest < Test::Unit::TestCase
  ROOT = File.expand_path("..", __dir__)
  TEMPLATE = File.join(ROOT, "lib/doparserb/runtime/dopa_rt.c.erb")
  COMPILERS = ["/usr/bin/clang", "/opt/homebrew/Cellar/gcc/16.2.0/bin/gcc-16"].freeze
  METADATA = JSON.generate(v: 1, digest: "1234abcd", grammar: "harness.y", text: "abc\n" * 1300)
  ENVIRONMENT = {"DOPAPARSER" => nil, "DOPAPARSER_FD" => nil, "DOPAPARSER_FLUSH" => "batch", "TERM" => "dumb", "NO_COLOR" => "1"}.freeze

  def setup
    @directory = Dir.mktmpdir("dopa-runtime-unit")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_protocol_metadata_and_repeat_parse_ids
    compile
    packets, status = capture("repeat")
    assert_equal(0, status.exitstatus)
    assert(packets.all? { |packet| packet.bytesize <= 2048 })
    frames = packets.map { |packet| packet.lines.first }
    assert(frames.all? { |frame| frame.match?(/\AF 1234abcd \d+ [12]\n\z/) })
    assert_equal([1, 2], frames.map { |frame| frame.split.last.to_i }.uniq)
    fragments = packets.filter_map do |packet|
      packet.match(/\AF [^\n]+\nM 1234abcd (\d+) (\d+)\n(.*)\z/m)
    end
    assert_operator(fragments.length, :>, 1)
    assert_equal(METADATA, fragments.sort_by { |fragment| fragment[1].to_i }.map { |fragment| fragment[3] }.join)
    assert_equal([METADATA.bytesize], fragments.map { |fragment| fragment[2].to_i }.uniq)
    events = event_lines(packets)
    expected = ["B", "T 4 3 7", "S 4 2 1", "R 3 1 2 1", "R 5 0 3 1", "E 3 5 3 7", "P 1 0", "X 6 1", "Q 2", "I 8", "C", "S 8 9 3", "A"]
    assert_equal(expected * 2, events)
  end

  def test_compiler_warnings_custom_locations_and_compile_time_disabling
    COMPILERS.each do |compiler|
      compile(compiler: compiler, flags: ["-DCUSTOM_LOCATION"])
      packets, status = capture("all")
      assert_equal(0, status.exitstatus)
      assert_include(event_lines(packets), "T 4 0 0")
      assert_include(event_lines(packets), "E 3 5 0 0")
      ["-DDOPA_RT_DISABLE", "-D_WIN32"].each do |flag|
        compile(compiler: compiler, flags: [flag])
        packets, status = capture("all")
        assert_equal(0, status.exitstatus)
        assert_empty(packets)
        assert_not_include(File.binread(@executable), "harness.y")
      end
    end
  end

  def test_off_wins_over_a_valid_socket
    compile
    packets, status = capture("all", env: {"DOPAPARSER" => "off"})
    assert_equal(0, status.exitstatus)
    assert_empty(packets)
  end

  def test_strict_posix_feature_mode_remains_nonblocking
    COMPILERS.each do |compiler|
      compile(compiler: compiler, flags: ["-D_POSIX_C_SOURCE=200809L"], metadata: "{}")
      packets, status = drain_and_resume("overflow")
      assert_equal(0, status.exitstatus)
      assert_include(event_lines(packets), "D 8")
    end
  end

  def test_concurrently_delivered_parses_have_unique_ids_and_metadata_is_sent_at_most_once
    ["c99", "c11"].each do |standard|
      compile(flags: ["-std=#{standard}", "-pthread"], metadata: "{}", fixture: "runtime_harness_threads.c")
      packets, status = capture("all")
      assert_equal(0, status.exitstatus)
      ids = packets.select { |packet| packet.lines.include?("B\n") }.map { |packet| packet.lines.first.split.last.to_i }
      assert_operator(ids.length, :>, 1)
      assert_equal(ids.length, ids.uniq.length)
      assert(ids.all? { |id| (1..32).cover?(id) })
      assert_operator(packets.count { |packet| packet.lines[1].start_with?("M ") }, :<=, 1)
      assert_equal(ids.length, event_lines(packets).count("A"))
    end
  end

  def test_event_lines_are_never_split_when_batch_fills
    compile(metadata: "{}")
    packets, status = capture("bulk")
    assert_equal(0, status.exitstatus)
    assert_operator(packets.length, :>=, 3)
    assert(packets.all? { |packet| packet.bytesize <= 2048 })
    events = event_lines(packets)
    assert_equal(351, events.count("S 4 2 1"))
    assert(events.all? { |event| event.match?(/\A[BTSREPXQICAZO](?: -?\d+)*\z/) })
  end

  def test_closed_receiver_cannot_signal_or_block_the_parser
    compile(metadata: "{}")
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    receiver.close
    out, err, status = Timeout.timeout(3) do
      Open3.capture3(ENVIRONMENT.merge("DOPAPARSER_FD" => sender.fileno.to_s), @executable, "bulk", sender.fileno => sender)
    end
    assert_equal(0, status.exitstatus)
    assert_equal("", out + err)
  ensure
    sender&.close
  end

  def test_eager_flush_reaches_receiver_before_lexer_wait
    compile(metadata: "{}")
    packets, status = coordinated_capture("eager") do |stdin, _stdout, receiver|
      received = []
      Timeout.timeout(3) do
        received << receiver.recv(2048) until event_lines(received).include?("R 5 0 3 1")
      end
      stdin.write("x")
      stdin.flush
      received
    end
    assert_equal(0, status.exitstatus)
    assert_include(event_lines(packets), "A")
  end

  def test_backpressure_reports_dropped_events_on_recovery
    compile(metadata: "{}")
    packets, status = drain_and_resume("overflow")
    assert_equal(0, status.exitstatus)
    assert_include(event_lines(packets), "D 8")
    assert_include(event_lines(packets), "A")
  end

  def test_sends_stop_after_64_consecutive_failures
    compile(metadata: "{}")
    packets, status = drain_and_resume("cutoff")
    assert_equal(0, status.exitstatus)
    assert_not_include(event_lines(packets), "A")
    assert(event_lines(packets).none? { |event| event.start_with?("D ") })
  end

  def test_badge_counts_and_terminal_controls
    compile(metadata: "{}")
    output, status = badge("all")
    assert_equal(0, status.exitstatus)
    assert_equal(1, output.lines.length)
    ["STAGE CLEAR", "2 TOKENS", "MAX CHAIN 2", "TOWER 3F", "@3:7", "COMEBACK", "AUTO REPAIR"].each do |part|
      assert_include(output, part)
    end
    assert_not_include(output, "\e[")
    assert_include(badge("abort").first, "ABORTED")
    assert_include(badge("exhausted").first, "STACK EXHAUSTED")
    assert_equal("", badge("all", env: {"TERM" => "dumb"}).first)
    assert_equal("", badge("all", env: {"DOPAPARSER" => "off"}).first)
  end

  def test_narrow_badges_fit_without_splitting_color_sequences
    compile(metadata: "{}")
    {"all" => "COMEBACK!", "abort" => "ABORTED", "exhausted" => "STACK EXHAUSTED"}.each do |mode, outcome|
      [nil, "1"].each do |no_color|
        output, status = badge(mode, cols: 30, env: {"NO_COLOR" => no_color})
        plain = output.gsub(/\e\[[0-9;]*m/, "").strip
        assert_equal(0, status.exitstatus)
        assert(plain.ascii_only?)
        assert_operator(plain.length, :<=, 29)
        assert(plain.start_with?(outcome), plain)
        assert_equal(1, output.lines.length)
        assert_match(/\e\[0m\r?\n\z/, output) unless no_color
      end
    end
    output, = badge("all", cols: 2, env: {"NO_COLOR" => nil})
    assert_equal("C", output.gsub(/\e\[[0-9;]*m/, "").strip)
  end

  def test_fd_requires_strict_decimal_unix_datagram_socket
    compile(metadata: "{}")
    ["-1", "+3", " 3", "3junk", "99999999999999999999999999999999", "1"].each do |fd|
      packets, status = capture("all", env: {"DOPAPARSER_FD" => fd})
      assert_equal(0, status.exitstatus)
      assert_empty(packets)
    end
    receiver, sender = Socket.pair(:UNIX, :STREAM, 0)
    out, err, status = Open3.capture3(ENVIRONMENT.merge("DOPAPARSER_FD" => sender.fileno.to_s), @executable, "all", sender.fileno => sender)
    assert_equal(0, status.exitstatus)
    assert_equal("", out + err)
    assert_equal(:wait_readable, receiver.recv_nonblock(2048, exception: false))
  ensure
    receiver&.close
    sender&.close
  end

  private

  def compile(flags: [], compiler: COMPILERS.first, metadata: METADATA, fixture: "runtime_harness.c")
    assert_path_exist(TEMPLATE, "the embedded runtime template is implemented")
    source = ERB.new(File.read(TEMPLATE)).result_with_hash(metadata_literal: metadata.dump, parser_id: "1234abcd")
    File.write(File.join(@directory, "runtime.inc"), source)
    @executable = File.join(@directory, "harness")
    out, err, status = Open3.capture3(compiler, "-std=c99", "-Wall", "-Wextra", "-Werror", *flags,
      "-I#{@directory}", File.join(ROOT, "test/fixtures", fixture), "-o", @executable)
    assert_equal(0, status.exitstatus, out + err)
  end

  def capture(mode, env: {})
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    receiver.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 65_536)
    sender.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 65_536)
    packets = []
    status = nil
    Open3.popen3(ENVIRONMENT.merge("DOPAPARSER_FD" => sender.fileno.to_s).merge(env), @executable, mode, sender.fileno => sender) do |stdin, stdout, stderr, waiter|
      stdin.close
      Timeout.timeout(5) do
        loop do
          done = !waiter.alive?
          while (packet = receiver.recv_nonblock(2048, exception: false)) != :wait_readable
            packets << packet
          end
          break if done
          IO.select([receiver], nil, nil, 0.01)
        end
        status = waiter.value
      end
      assert_equal("", stdout.read)
      assert_equal("", stderr.read)
    end
    [packets, status]
  ensure
    receiver&.close
    sender&.close unless sender&.closed?
  end

  def event_lines(packets)
    packets.reject { |packet| packet.lines[1]&.start_with?("M ") }.flat_map { |packet| packet.lines.drop(1).map(&:chomp) }
  end

  def coordinated_capture(mode)
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    packets = []
    status = nil
    Open3.popen3(ENVIRONMENT.merge("DOPAPARSER_FD" => sender.fileno.to_s, "DOPAPARSER_FLUSH" => "eager"), @executable, mode, sender.fileno => sender) do |stdin, stdout, stderr, waiter|
      packets.concat(yield(stdin, stdout, receiver))
      stdin.close
      status = Timeout.timeout(3) { waiter.value }
      loop do
        packet = receiver.recv_nonblock(2048, exception: false)
        break if packet == :wait_readable
        packets << packet
      end
      assert_equal("", stderr.read)
    end
    [packets, status]
  ensure
    receiver&.close
    sender&.close unless sender&.closed?
  end

  def drain_and_resume(mode)
    coordinated_capture(mode) do |stdin, stdout, receiver|
      assert_equal("drain\n", Timeout.timeout(3) { stdout.gets })
      received = []
      loop do
        packet = receiver.recv_nonblock(2048, exception: false)
        break if packet == :wait_readable
        received << packet if packet.start_with?("F ")
      end
      stdin.write("x")
      stdin.flush
      received
    end
  end

  def badge(mode, env: {}, cols: nil)
    master, slave = PTY.open
    master.winsize = [24, cols] if cols
    status = nil
    Open3.popen2(ENVIRONMENT.merge("TERM" => "xterm").merge(env), @executable, mode, err: slave) do |stdin, stdout, waiter|
      stdin.close
      assert_equal("", stdout.read)
      status = Timeout.timeout(3) { waiter.value }
    end
    text = +""
    loop do
      chunk = master.read_nonblock(4096, exception: false)
      break if chunk == :wait_readable
      text << chunk
    end
    [text, status]
  ensure
    master&.close
    slave&.close unless slave&.closed?
  end
end
