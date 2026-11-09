# frozen_string_literal: true

require_relative "event"

module Doparserb
  class EventBus
    def initialize
      @queue = Queue.new
    end

    def emit(kind, strength: :small, **info)
      @queue << Event.new(kind: kind, strength: strength, info: info)
    end

    def each
      return enum_for(__method__) unless block_given?
      while (event = @queue.pop)
        yield event
      end
    end

    def drain
      events = []
      while (event = @queue.pop(true))
        events << event
      end
      events
    rescue ThreadError
      events
    end

    def close = @queue.close
    def closed? = @queue.closed?
  end
end
