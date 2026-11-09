# frozen_string_literal: true

require "pty"
require "io/console"
require "timeout"
require_relative "vt"

class PTYDriver
  ROOT = File.expand_path("../..", __dir__)
  ENVIRONMENT = {
    "TERM" => "xterm-256color", "COLORTERM" => "truecolor", "NO_COLOR" => nil,
    "DOPAPARSER" => "sound=off", "DOPAPARSER_PROFILE" => "off", "DOPAPARSER_SEED" => "1",
    "DOPAPARSER_FD" => nil, "DOPAPARSER_DEBUG" => nil, "MAKELEVEL" => nil
  }.freeze

  attr_reader :pid, :status

  def self.doparserb(*arguments, **options)
    new([RbConfig.ruby, "-I#{ROOT}/lib", "#{ROOT}/exe/doparserb", *arguments], **options)
  end

  def initialize(command, rows: 24, cols: 80, env: {}, directory: ROOT)
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @mutex = Mutex.new
    @raw = +"".b
    @records = []
    @vt = VT.new(rows, cols)
    environment = ENVIRONMENT.merge("LINES" => rows.to_s, "COLUMNS" => cols.to_s).merge(env)
    @output, @input, @pid = PTY.spawn(environment, *command, chdir: directory)
    @output.winsize = [rows, cols]
    @reader = Thread.new do
      loop do
        bytes = @output.readpartial(65_536)
        @mutex.synchronize do
          @raw << bytes
          @records << [elapsed, "o", bytes.dup]
          @vt.feed(bytes)
        end
      end
    rescue EOFError, Errno::EIO, IOError
      nil
    end
  end

  def elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
  def raw_output = @mutex.synchronize { @raw.dup.force_encoding(Encoding::UTF_8) }
  def all_text = @mutex.synchronize { @vt.all_text }
  def text = @mutex.synchronize { @vt.text }
  def lines = @mutex.synchronize { @vt.lines }
  def records = @mutex.synchronize { @records.map(&:dup) }
  def unknown = @mutex.synchronize { @vt.unknown.dup }

  def send_keys(text)
    @input.write(text)
    @input.flush
  end

  def resize(rows:, cols:)
    @mutex.synchronize do
      @vt.resize(rows, cols)
      @output.winsize = [rows, cols]
    end
    Process.kill("WINCH", @pid)
  end

  def wait_for(pattern, timeout: 10, raw: false)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      current = raw ? raw_output : all_text
      return current if pattern.is_a?(Regexp) ? pattern.match?(current) : current.include?(pattern)
      raise Timeout::Error, "waiting for #{pattern.inspect}; screen:\n#{all_text}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.005
    end
  end

  def wait_exit(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until @status
      result = Process.waitpid2(@pid, Process::WNOHANG)
      @status = result.last if result
      if !@status && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Timeout::Error, "process did not exit; screen:\n#{all_text}"
      end
      sleep 0.005 unless @status
    end
    remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
    raise Timeout::Error, "child output remained open" unless @reader.join(remaining)
    @reader.value
    @status.exitstatus || 128 + @status.termsig
  end

  def close
    unless @status
      result = Process.waitpid2(@pid, Process::WNOHANG)
      @status = result.last if result
      unless @status
        Process.kill("KILL", -@pid)
        _, @status = Process.waitpid2(@pid)
      end
    end
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  ensure
    @input&.close unless @input&.closed?
    @output&.close unless @output&.closed?
    @reader&.join(1)
  end
end
