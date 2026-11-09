# frozen_string_literal: true

require "pty"
require "socket"
require "io/console"
require "rbconfig"

module Doparserb
  module Play
    class Launcher
      POLL_INTERVAL = 0.005
      READ_SIZE = 65_536
      EVENT_BATCH = 32
      EVENT_BUDGET = 0.001
      STARTUP_TIMEOUT = 5
      SIGNALS = %w[WINCH INT TERM HUP].freeze
      CHILD_BOOTSTRAP = <<~'RUBY'
        begin
          slave_path, ready_fd = ARGV.shift(2)
          %w[RUBYOPT RUBYLIB].each do |name|
            present, value = ARGV.shift(2)
            ENV[name] = present == "1" ? value : nil
          end
          Process.setsid
          File.open(slave_path, File::RDWR | File::NONBLOCK) {}
          ready = IO.for_fd(Integer(ready_fd))
          ready.write("1")
          ready.close
          event_fd = Integer(ENV.fetch("DOPAPARSER_FD"))
          exec([ARGV.first, ARGV.first], *ARGV.drop(1), event_fd => event_fd)
        rescue Errno::ENOENT
          STDERR.puts("doparserb: command not found: #{ARGV.first}")
          exit 127
        end
      RUBY

      def initialize(command, config:)
        @command = command
        @config = config
      end

      def run
        raise Error, "play requires -- followed by a command" if @command.empty?
        @terminals = [$stdin, $stdout, $stderr].map(&:tty?)
        return exec([@command.first, @command.first], *@command.drop(1)) unless @terminals.any?

        @output = @terminals[1] ? $stdout : @terminals[2] ? $stderr : nil
        @signals = []
        with_signals do
          with_presentation do
            launch
            if @terminals.first
              $stdin.raw(intr: false) { relay }
            else
              relay
            end
          end
        end
        status = @status
        cleanup
        return status.exitstatus if status.exited?

        begin
          Signal.trap(status.termsig, "SYSTEM_DEFAULT")
        rescue ArgumentError
          nil
        end
        Process.kill(status.termsig, Process.pid)
        128 + status.termsig
      rescue Errno::ENOENT
        $stderr.puts("doparserb: command not found: #{@command.first}")
        127
      ensure
        cleanup
      end

      private

      def launch
        @master, @slave = PTY.open
        @slave.console_mode = $stdin.console_mode if @terminals.first
        resize
        @events, sender = Socket.pair(:UNIX, :DGRAM, 0)
        ready, notify = IO.pipe
        environment = {"DOPAPARSER_FD" => sender.fileno.to_s, "DOPAPARSER_FLUSH" => @terminals.first ? "eager" : "batch",
                       "RUBYOPT" => nil, "RUBYLIB" => nil}
        ruby_environment = %w[RUBYOPT RUBYLIB].flat_map { |name| [ENV.key?(name) ? "1" : "0", ENV.fetch(name, "")] }
        descriptors = [$stdin, $stdout, $stderr].each_with_index.map { |io, index| @terminals[index] ? @slave : io }
        @pid = Process.spawn(environment, RbConfig.ruby, "--disable-gems", "-e", CHILD_BOOTSTRAP, "--",
                             @slave.path, notify.fileno.to_s, *ruby_environment, *@command,
                             in: descriptors[0], out: descriptors[1], err: descriptors[2], sender.fileno => sender, notify.fileno => notify)
        notify.close
        await_terminal(ready)
      ensure
        sender&.close
        ready&.close
        notify&.close unless notify&.closed?
      end

      def await_terminal(ready)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STARTUP_TIMEOUT
        loop do
          forward_signals
          @status ||= Process.waitpid2(@pid, Process::WNOHANG)&.last
          return if @status
          if IO.select([ready], nil, nil, POLL_INTERVAL)
            ready.read(1)
            return
          end
          raise Error, "child terminal initialization timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        end
      end

      def with_presentation
        return yield if @config.off?
        started = false
        relay_error = nil
        begin
          engine = Engine.new(@config, output: $stderr, preserve_input: true)
          engine.session do
            started = true
            begin
              @protocol = Protocol.new(executable: @command.first, directory: Dir.pwd)
              @show = Show.new(config: @config, engine: engine)
              present(:start)
            rescue StandardError => error
              Doparserb.debug(error)
              @show = nil
            end
            begin
              yield
            rescue StandardError => error
              relay_error = error
              raise
            end
          end
        rescue StandardError => error
          raise if error.equal?(relay_error)
          Doparserb.debug(error)
          yield unless started
        end
      end

      def relay
        @master_open = @events_open = true
        relay_output
        @slave.close
        @slave = nil
        input_open = @terminals.first
        pending_input = +"".b
        finished = false
        loop do
          forward_signals
          readers = []
          readers << @master if @master_open
          readers << @events if @events_open
          readers << $stdin if input_open && pending_input.bytesize < READ_SIZE
          writers = @master_open && !pending_input.empty? ? [@master] : []
          readable, = IO.select(readers, writers, nil, POLL_INTERVAL)
          relay_output if readable&.include?(@master)
          if readable&.include?($stdin)
            bytes = $stdin.read_nonblock(READ_SIZE, exception: false)
            if bytes.nil?
              input_open = false
            elsif bytes != :wait_readable
              present(:cancel)
              pending_input << bytes if @master_open && !@status
            end
          end
          pending_input = relay_input(pending_input) if @master_open && !pending_input.empty?
          pending_input.clear unless @master_open
          events_empty = receive_events
          receive_metadata
          @status ||= Process.waitpid2(@pid, Process::WNOHANG)&.last
          if @status && !@master_open && events_empty && !finished
            present(:finish)
            finished = true
          end
          present(:tick)
          break if finished && (!@show || present(:done?))
        end
      end

      def relay_output
        bytes = @master.read_nonblock(READ_SIZE, exception: false)
        if bytes.nil?
          @master_open = false
        elsif bytes != :wait_readable
          if @output
            present(:yield_to_output, bytes)
            @output.write(bytes)
            @output.flush
          end
        end
      rescue Errno::EIO, Errno::ECONNRESET
        @master_open = false
      end

      def relay_input(bytes)
        count = @master.write_nonblock(bytes, exception: false)
        count.is_a?(Integer) ? bytes.byteslice(count..) : bytes
      rescue Errno::EIO, Errno::ECONNRESET
        @master_open = false
        +"".b
      end

      def receive_events
        return true unless @events_open
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + EVENT_BUDGET
        EVENT_BATCH.times do
          relay_output if @master_open
          datagram = @events.recv_nonblock(READ_SIZE, exception: false)
          return true if datagram == :wait_readable
          next unless @show
          begin
            @protocol.consume(datagram).each do |event|
              present(:consume, event, metadata: @protocol.metadata(event[:parser], event[:pid]))
            end
          rescue StandardError => error
            Doparserb.debug(error)
          end
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        end
        false
      rescue Errno::ECONNRESET, Errno::EIO
        @events_open = false
        true
      end

      def present(method, *arguments, **keywords)
        @show&.public_send(method, *arguments, **keywords)
      rescue StandardError => error
        Doparserb.debug(error)
        @show = nil
      end

      def receive_metadata
        @protocol&.drain_updates&.each do |parser, pid, metadata|
          present(:metadata_available, parser, pid, metadata)
        end
      rescue StandardError => error
        Doparserb.debug(error)
      end

      def with_signals
        previous = {}
        SIGNALS.each { |signal| previous[signal] = Signal.trap(signal) { @signals << signal } }
        yield
      ensure
        previous&.each { |signal, handler| Signal.trap(signal, handler) }
      end

      def forward_signals
        until @signals.empty?
          signal = @signals.shift
          if signal == "WINCH"
            resize
          else
            present(:cancel)
            signal_child(signal)
          end
        end
      end

      def signal_child(signal)
        return unless @pid && !@status
        begin
          Process.kill(signal, -@pid)
        rescue Errno::ESRCH
          Process.kill(signal, @pid)
        end
      rescue Errno::ESRCH
        nil
      end

      def resize
        terminal = [$stdout, $stderr, $stdin].find(&:tty?)
        @master.winsize = terminal.winsize if @master && terminal
        signal_child("WINCH")
      rescue IOError, SystemCallError
        nil
      end

      def cleanup
        if @pid && !@status
          signal_child("KILL")
          @status = Process.waitpid2(@pid).last
        end
      rescue Errno::ECHILD
        nil
      ensure
        begin
          @protocol&.close
        rescue StandardError => error
          Doparserb.debug(error)
        ensure
          @protocol = nil
        end
        [@master, @slave, @events].compact.each { |io| io.close unless io.closed? }
      end
    end
  end
end
