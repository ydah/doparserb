# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_driver"
require "pty"
require "io/console"
require "json"
require "socket"
require "tempfile"
require "timeout"
require "stringio"

class PlayLauncherTest < Test::Unit::TestCase
  include CommandTest

  def test_no_terminal_executes_in_place_without_changing_descriptors_or_environment
    launcher = <<~RUBY
      require "doparserb"
      $stdout.sync = true
      puts Process.pid
      exit Doparserb::Play::Launcher.new(ARGV, config: Doparserb::Config.new).run
    RUBY
    child = 'puts Process.pid; print STDIN.read; warn [ENV["DOPAPARSER_FD"], ENV["DOPAPARSER_FLUSH"], STDIN.tty?, STDOUT.tty?, STDERR.tty?].inspect; exit 19'
    output, error, status = Open3.capture3(
      ENVIRONMENT.merge("DOPAPARSER_FD" => "inherited", "DOPAPARSER_FLUSH" => "untouched"),
      RbConfig.ruby, "-I#{ROOT}/lib", "-e", launcher, "--", RbConfig.ruby, "-e", child,
      stdin_data: "input\0bytes\n"
    )
    parent_pid, child_pid, rest = output.split("\n", 3)
    assert_equal(19, status.exitstatus, error)
    assert_equal(parent_pid, child_pid)
    assert_equal("input\0bytes\n", rest)
    assert_equal("[\"inherited\", \"untouched\", false, false, false]\n", error)
  end

  def test_terminal_descriptors_and_event_socket_are_assigned_independently
    [[false, false, true], [false, true, false], [false, true, true],
     [true, false, false], [true, false, true], [true, true, false], [true, true, true]].each do |terminals|
      Dir.mktmpdir("doparserb-launcher") do |directory|
        result_path = File.join(directory, "result.json")
        code = <<~'RUBY'
          require "json"
          require "socket"
          socket = Socket.for_fd(Integer(ENV.fetch("DOPAPARSER_FD")))
          File.write(ARGV.fetch(0), JSON.generate(
            tty: [STDIN.tty?, STDOUT.tty?, STDERR.tty?],
            flush: ENV["DOPAPARSER_FLUSH"], socket_type: socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_TYPE).int,
            input: STDIN.tty? ? nil : STDIN.read
          ))
          STDOUT.write("stdout\0bytes\n")
          STDERR.write("stderr\0bytes\n")
          exit 17
        RUBY
        result = launch_with_terminals(terminals, [RbConfig.ruby, "-e", code, result_path])
        assert_equal(17, result[:status].exitstatus, result.inspect)
        details = JSON.parse(File.read(result_path))
        assert_equal(terminals, details.fetch("tty"))
        assert_equal(terminals.first ? "eager" : "batch", details.fetch("flush"))
        assert_equal(Socket::SOCK_DGRAM, details.fetch("socket_type"))
        assert_equal("file input\0\n", details.fetch("input")) unless terminals.first
        assert_equal("stdout\0bytes\n", result[:stdout]) unless terminals[1]
        assert_equal("stderr\0bytes\n", result[:stderr]) unless terminals[2]
      end
    end
  end

  def test_terminal_child_signal_is_preserved
    result = launch_with_terminals([false, false, true], [RbConfig.ruby, "-e", 'Process.kill("TERM", Process.pid)'])
    assert_predicate(result[:status], :signaled?, result.inspect)
    assert_equal(Signal.list.fetch("TERM"), result[:status].termsig)
  end

  def test_event_consumer_is_initialized_before_the_child_starts
    Dir.mktmpdir("doparserb-consumer-ready") do |directory|
      ready = File.join(directory, "ready")
      wrapper = <<~'RUBY'
        require "doparserb"
        Doparserb::Play::Show.prepend(Module.new do
          def start
            sleep 0.1
            File.write(ENV.fetch("CONSUMER_READY"), "ready")
            super
          end
        end)
        exit Doparserb::Play::Launcher.new(ARGV, config: Doparserb::Config.new).run
      RUBY
      child = <<~'RUBY'
        unless File.exist?(ENV.fetch("CONSUMER_READY"))
          warn "event consumer was not ready"
          exit 43
        end
        require "socket"
        Socket.for_fd(Integer(ENV.fetch("DOPAPARSER_FD"))).send("F 0123abcd #{Process.pid} 1\nB\nS 3 1 1\nA\n", 0)
      RUBY
      result = launch_with_terminals([false, false, true], [RbConfig.ruby, "-e", child], wrapper: wrapper,
                                    env: {"CONSUMER_READY" => ready, "TERM" => "xterm", "DOPAPARSER" => "sound=off,replay=full,speed=2000"})
      assert_equal(0, result[:status].exitstatus, result.inspect)
      assert_include(result[:terminal], "STAGE CLEAR")
    end
  end

  def test_terminal_stdout_receives_no_effects_when_stderr_is_redirected
    code = <<~'RUBY'
      require "socket"
      socket = Socket.for_fd(Integer(ENV.fetch("DOPAPARSER_FD")))
      socket.send("F 0123abcd #{Process.pid} 1\nB\nS 3 1 1\nA\n", 0)
      puts "child output"
    RUBY
    result = launch_with_terminals([false, true, false], [RbConfig.ruby, "-e", code],
                                  options: [], env: {"TERM" => "xterm-256color", "DOPAPARSER" => "sound=off"})
    assert_equal(0, result[:status].exitstatus, result.inspect)
    assert_equal("child output\n", result[:terminal].delete("\r"))
    assert_equal("", result[:stderr])
  end

  def test_presentation_failures_are_logged_without_changing_child_status
    %w[start tick finish].each do |method|
      Dir.mktmpdir("doparserb-presentation-error") do |directory|
        log = File.join(directory, "error.log")
        wrapper = <<~RUBY
          require "doparserb"
          Doparserb::Play::Show.class_eval do
            define_method(:#{method}) { |*args, **keywords| raise "presentation failed: #{method}" }
          end
          exit Doparserb::Play::Launcher.new(ARGV, config: Doparserb::Config.new).run
        RUBY
        result = launch_with_terminals([false, false, true], [RbConfig.ruby, "-e", 'puts "child output"; exit 29'],
                                      wrapper: wrapper, env: {"DOPAPARSER_DEBUG" => log})
        assert_equal(29, result[:status].exitstatus, result.inspect)
        assert_equal("child output\n", result[:stdout])
        assert_include(File.read(log), "presentation failed: #{method}")
      end
    end
  end

  def test_launcher_closes_descriptors_reaps_child_and_restores_signal_handler
    wrapper = <<~'RUBY'
      require "doparserb"
      require "json"
      Doparserb::Play::Launcher
      handler = ->(signal) {}
      Signal.trap("TERM", handler)
      descriptors = -> { ObjectSpace.each_object(IO).reject(&:closed?).map(&:fileno) }
      before = descriptors.call
      status = Doparserb::Play::Launcher.new(ARGV, config: Doparserb::Config.new(mode: "off")).run
      extra = descriptors.call - before
      restored = Signal.trap("TERM", "DEFAULT").equal?(handler)
      child_left = begin
        Process.waitpid(-1, Process::WNOHANG)
        true
      rescue Errno::ECHILD
        false
      end
      STDERR.puts(JSON.generate(status: status, extra: extra, restored: restored, child_left: child_left))
    RUBY
    result = launch_with_terminals([false, true, false], [RbConfig.ruby, "-e", "exit 31"], wrapper: wrapper)
    assert_equal(0, result[:status].exitstatus, result.inspect)
    assert_equal({"status" => 31, "extra" => [], "restored" => true, "child_left" => false}, JSON.parse(result[:stderr]))
  end

  def test_empty_datagram_does_not_discard_later_events
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    seen = []
    show = Object.new
    show.define_singleton_method(:consume) { |event, metadata:| seen << event[:code] }
    launcher = Doparserb::Play::Launcher.new([RbConfig.ruby], config: Doparserb::Config.new)
    launcher.instance_variable_set(:@events, receiver)
    launcher.instance_variable_set(:@events_open, true)
    launcher.instance_variable_set(:@show, show)
    launcher.instance_variable_set(:@protocol, Doparserb::Play::Protocol.new(executable: RbConfig.ruby))
    sender.send("", 0)
    sender.send("F 0123abcd 42 1\nB\nA\n", 0)
    2.times { launcher.send(:receive_events) }
    assert_equal(%w[B A], seen)
  ensure
    receiver&.close
    sender&.close
  end

  def test_child_output_is_relayed_between_event_datagrams
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    master, child_output = IO.pipe
    seen = []
    output = StringIO.new
    show = Object.new
    show.define_singleton_method(:yield_to_output) { |bytes| seen << :output }
    show.define_singleton_method(:consume) do |event, metadata:|
      if event[:parse_id] == 1
        child_output.write("child output\n")
      else
        seen << :second_datagram
      end
    end
    launcher = Doparserb::Play::Launcher.new([RbConfig.ruby], config: Doparserb::Config.new)
    {events: receiver, events_open: true, master: master, master_open: true, output: output, show: show,
     protocol: Doparserb::Play::Protocol.new(executable: RbConfig.ruby)}.each do |name, value|
      launcher.instance_variable_set("@#{name}", value)
    end
    sender.send("F 0123abcd 42 1\nB\n", 0)
    sender.send("F 0123abcd 42 2\nB\n", 0)
    2.times { launcher.send(:receive_events) }
    assert_equal([:output, :second_datagram], seen)
    assert_equal("child output\n", output.string)
  ensure
    [receiver, sender, master, child_output].compact.each(&:close)
  end

  def test_child_preserves_disabled_echo_and_canonical_input
    wrapper = 'require "io/console"; STDIN.echo = false; exec(*ARGV)'
    child = 'STDOUT.sync = true; puts "READY"; first = STDIN.read(1); puts "FIRST"; puts "BYTES:#{(first + STDIN.gets).bytesize}"'
    driver = PTYDriver.new([RbConfig.ruby, "-e", wrapper, "--", RbConfig.ruby, "-I#{ROOT}/lib", "#{ROOT}/exe/doparserb",
                            "play", "--dopa=off", "--", RbConfig.ruby, "-e", child])
    driver.wait_for("READY")
    driver.send_keys("secret-input")
    sleep 0.03
    assert_not_include(driver.all_text, "FIRST")
    driver.send_keys("\n")
    assert_equal(0, driver.wait_exit)
    assert_include(driver.all_text, "BYTES:13")
    assert_not_include(driver.raw_output, "secret-input")
  ensure
    driver&.close
  end

  def test_child_preserves_noncanonical_input
    wrapper = 'require "io/console"; STDIN.raw!; exec(*ARGV)'
    child = 'STDOUT.sync = true; puts "READY"; puts "BYTES:#{STDIN.read(3).unpack1("H*")}"'
    driver = PTYDriver.new([RbConfig.ruby, "-e", wrapper, "--", RbConfig.ruby, "-I#{ROOT}/lib", "#{ROOT}/exe/doparserb",
                            "play", "--dopa=off", "--", RbConfig.ruby, "-e", child])
    driver.wait_for("READY")
    driver.send_keys("abc")
    assert_nothing_raised { driver.wait_for("BYTES:616263", timeout: 1) }
    assert_equal(0, driver.wait_exit)
    assert_not_include(driver.raw_output, "abc")
  ensure
    driver&.close
  end

  def test_raw_child_receives_interrupt_byte_as_data
    child = <<~'RUBY'
      require "io/console"
      STDOUT.sync = true
      STDIN.raw(intr: false) do
        puts "READY"
        puts "BYTES:#{STDIN.read(1).unpack1('H*')}"
      end
    RUBY
    driver = PTYDriver.doparserb("play", "--dopa=off", "--", RbConfig.ruby, "-e", child)
    driver.wait_for("READY")
    driver.send_keys("\x03")
    assert_equal(0, driver.wait_exit)
    assert_include(driver.all_text, "BYTES:03")
  ensure
    driver&.close
  end

  def test_bootstrap_does_not_run_ruby_hooks_and_restores_child_environment
    Dir.mktmpdir("doparserb-ruby-hook") do |directory|
      hook = File.join(directory, "hook.rb")
      log = File.join(directory, "hook.log")
      File.write(hook, 'File.open(ENV.fetch("DOPA_HOOK_LOG"), "a") { |file| file.puts(Process.pid) }')
      rubyopt = "-r#{hook}"
      rubylib = "#{directory}:/original/path"
      wrapper = <<~RUBY
        require "doparserb"
        Doparserb::Play::Launcher
        ENV["RUBYOPT"] = #{rubyopt.dump}
        ENV["RUBYLIB"] = #{rubylib.dump}
        exit Doparserb::Play::Launcher.new(ARGV, config: Doparserb::Config.new(mode: "off")).run
      RUBY
      result = launch_with_terminals([false, false, true], ["/bin/sh", "-c", 'printf "%s\n%s\n" "$RUBYOPT" "$RUBYLIB"'],
                                    wrapper: wrapper, env: {"RUBYOPT" => rubyopt, "RUBYLIB" => rubylib, "DOPA_HOOK_LOG" => log})
      assert_equal(0, result[:status].exitstatus, result.inspect)
      assert_equal("#{rubyopt}\n#{rubylib}\n", result[:stdout])
      assert_equal(1, File.readlines(log).length)
    end
  end

  def test_bootstrap_preserves_absent_and_empty_ruby_environment_values
    [nil, ""].each do |value|
      child = 'if [ "${RUBYOPT+x}" = x ]; then printf "<%s>\n" "$RUBYOPT"; else printf "absent\n"; fi; if [ "${RUBYLIB+x}" = x ]; then printf "<%s>\n" "$RUBYLIB"; else printf "absent\n"; fi'
      wrapper = <<~RUBY
        require "doparserb"
        Doparserb::Play::Launcher
        ENV["RUBYOPT"] = #{value.inspect}
        ENV["RUBYLIB"] = #{value.inspect}
        exit Doparserb::Play::Launcher.new(ARGV, config: Doparserb::Config.new(mode: "off")).run
      RUBY
      result = launch_with_terminals([false, false, true], ["/bin/sh", "-c", child],
                                    wrapper: wrapper, env: {"RUBYOPT" => value, "RUBYLIB" => value})
      assert_equal(0, result[:status].exitstatus, result.inspect)
      assert_equal(value.nil? ? "absent\nabsent\n" : "<>\n<>\n", result[:stdout])
    end
  end

  def test_bootstrap_reports_missing_executable
    result = launch_with_terminals([false, false, true], ["/doparserb/no-such-executable"])
    assert_equal(127, result[:status].exitstatus)
    assert_include(result[:terminal], "command not found: /doparserb/no-such-executable")
  end

  def test_bootstrap_failure_before_readiness_preserves_status
    wrapper = <<~'RUBY'
      require "doparserb"
      Doparserb::Play::Launcher.send(:remove_const, :CHILD_BOOTSTRAP)
      Doparserb::Play::Launcher.const_set(:CHILD_BOOTSTRAP, 'warn "BOOTSTRAP FAILED"; exit 37')
      exit Doparserb::Play::Launcher.new(ARGV, config: Doparserb::Config.new(mode: "off")).run
    RUBY
    result = launch_with_terminals([false, false, true], [RbConfig.ruby, "-e", 'puts "TARGET"'], wrapper: wrapper)
    assert_equal(37, result[:status].exitstatus)
    assert_equal("", result[:stdout])
    assert_include(result[:terminal], "BOOTSTRAP FAILED")
  end

  def test_startup_timeout_kills_and_reaps_child_before_it_has_a_process_group
    Dir.mktmpdir("doparserb-bootstrap-timeout") do |directory|
      path = File.join(directory, "child.pid")
      bootstrap = "File.write(#{path.dump}, Process.pid); sleep 30"
      wrapper = <<~RUBY
        require "doparserb"
        Doparserb::Play::Launcher.send(:remove_const, :CHILD_BOOTSTRAP)
        Doparserb::Play::Launcher.const_set(:CHILD_BOOTSTRAP, #{bootstrap.dump})
        Doparserb::Play::Launcher.send(:remove_const, :STARTUP_TIMEOUT)
        Doparserb::Play::Launcher.const_set(:STARTUP_TIMEOUT, 0.2)
        exit Doparserb::CLI.new(["play", "--dopa=off", "--", *ARGV]).run
      RUBY
      result = launch_with_terminals([false, false, true], [RbConfig.ruby, "-e", 'puts "TARGET"'], wrapper: wrapper)
      assert_equal(1, result[:status].exitstatus)
      assert_equal("", result[:stdout])
      assert_include(result[:terminal], "child terminal initialization timed out")
      assert_path_exist(path)
      assert_raise(Errno::ESRCH) { Process.kill(0, Integer(File.read(path))) }
    end
  end

  def test_completed_metadata_is_delivered_without_waiting_for_another_event
    Dir.mktmpdir("doparserb-metadata-ready") do |directory|
      path = File.join(directory, "metadata.json")
      wrapper = <<~RUBY
        require "doparserb"
        require "json"
        calls = 0
        Doparserb::Play::Protocol.class_eval do
          define_method(:drain_updates) do
            calls += 1
            calls == 2 ? [["0123abcd", 42, {"ready" => true}]] : []
          end
        end
        Doparserb::Play::Show.class_eval do
          define_method(:metadata_available) do |parser, pid, metadata|
            File.write(#{path.dump}, JSON.generate([parser, pid, metadata]))
          end
        end
        exit Doparserb::Play::Launcher.new(ARGV, config: Doparserb::Config.new).run
      RUBY
      result = launch_with_terminals([false, false, true], [RbConfig.ruby, "-e", "sleep 0.05; exit 17"], wrapper: wrapper)
      assert_equal(17, result[:status].exitstatus, result.inspect)
      assert_path_exist(path)
      assert_equal(["0123abcd", 42, {"ready" => true}], JSON.parse(File.read(path)))
    end
  end

  def test_protocol_cleanup_failure_does_not_prevent_descriptor_cleanup
    receiver, sender = IO.pipe
    calls = 0
    protocol = Object.new
    protocol.define_singleton_method(:close) { calls += 1; raise "metadata cleanup failed" }
    launcher = Doparserb::Play::Launcher.new([RbConfig.ruby], config: Doparserb::Config.new)
    launcher.instance_variable_set(:@protocol, protocol)
    launcher.instance_variable_set(:@master, receiver)
    launcher.instance_variable_set(:@events, sender)
    assert_nothing_raised { 2.times { launcher.send(:cleanup) } }
    assert_equal(1, calls)
    assert_predicate(receiver, :closed?)
    assert_predicate(sender, :closed?)
  ensure
    [receiver, sender].compact.each { |io| io.close unless io.closed? }
  end

  private

  def launch_with_terminals(terminals, command, options: ["--dopa=off"], env: {}, wrapper: nil)
    master, slave = PTY.open
    slave.winsize = [24, 80]
    input = Tempfile.new("doparserb-input")
    input.binmode
    input.write("file input\0\n")
    input.rewind
    stdout_read, stdout_write = IO.pipe
    stderr_read, stderr_write = IO.pipe
    descriptors = [input, stdout_write, stderr_write].each_with_index.map { |io, index| terminals[index] ? slave : io }
    launcher = wrapper ? ["-e", wrapper, "--"] : ["#{ROOT}/exe/doparserb", "play", *options, "--"]
    pid = Process.spawn(ENVIRONMENT.merge(env), RbConfig.ruby, "-I#{ROOT}/lib", *launcher, *command,
                        in: descriptors[0], out: descriptors[1], err: descriptors[2])
    slave.close
    stdout_write.close
    stderr_write.close
    readers = [master, stdout_read, stderr_read].map do |io|
      Thread.new do
        bytes = +"".b
        begin
          loop { bytes << io.readpartial(65_536) }
        rescue EOFError, Errno::EIO, Errno::ECONNRESET
          bytes
        end
      end
    end
    _, status = Timeout.timeout(10) { Process.waitpid2(pid) }
    terminal, stdout, stderr = readers.map { |reader| Timeout.timeout(10) { reader.value } }
    {terminal: terminal, stdout: stdout, stderr: stderr, status: status}
  ensure
    [master, slave, stdout_read, stdout_write, stderr_read, stderr_write].compact.each { |io| io.close unless io.closed? }
    input&.close!
    if pid && !status
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
  end
end
