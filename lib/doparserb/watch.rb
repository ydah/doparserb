# frozen_string_literal: true

module Doparserb
  class Watch
    POLL_INTERVAL = 0.1
    SETTLE_TIME = 0.15

    def initialize(path, config:, engine: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep seconds })
      @path, @config, @engine, @clock, @sleeper = path, config, engine, clock, sleeper
    end

    def run
      unless @path && !@path.start_with?("-") && (previous = fingerprint)
        raise Error, "watch requires an existing regular grammar file first: watch FILE [lrama options]"
      end
      loop do
        @stats = nil
        begin
          yield ->(stats) { @stats = stats }
        rescue SystemExit => error
          return error.status if error.success? || (!@stats&.dig(:grammar) && fingerprint == previous)
        rescue Errno::ENOENT, Errno::ENOTDIR
          raise if fingerprint
        rescue Error, IOError, SystemCallError
          raise
        rescue StandardError => error
          raise unless %i[grammar_break validation_break].include?(@stats&.dig(:failure, :kind))
          $stderr.write(error.full_message)
        end
        show_status if @stats && @stats[:grammar]
        previous = wait_for_change(previous)
      end
    rescue Interrupt
      130
    end

    private

    def fingerprint
      stat = File.stat(@path)
      [stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime] if stat.file?
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
      nil
    end

    def wait_for_change(previous)
      candidate = previous
      changed_at = @clock.call
      loop do
        @sleeper.call(POLL_INTERVAL)
        current = fingerprint
        if current != candidate
          candidate = current
          changed_at = @clock.call
        elsif candidate && candidate != previous && @clock.call - changed_at >= SETTLE_TIME
          return candidate
        end
      end
    end

    def show_status
      @engine ||= Engine.new(@config, preserve_input: true)
      conflicts = @stats[:states].to_i.positive? ? @stats[:sr_conflicts].to_i + @stats[:rr_conflicts].to_i : "?"
      result = @stats[:success] ? "READY" : "FAILED"
      @engine.session do
        @engine.badge("* WATCH * CONFLICTS #{conflicts}  #{result}  #{File.basename(@path)}  SAVE TO REBUILD")
      end
    rescue StandardError => error
      Doparserb.debug(error)
    end
  end
end
