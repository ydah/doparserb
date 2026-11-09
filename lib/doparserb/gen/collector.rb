# frozen_string_literal: true

module Doparserb
  module Gen
    class Collector
      def initialize
        @stats = {
          tokens: 0, token_types: {}, rules: 0, terms: 0, nterms: 0,
          parameterized: 0, inline_expansions: 0, states: 0, split_states: 0,
          sr_conflicts: 0, rr_conflicts: 0, resolved_conflicts: 0, expect: nil,
          expect_matched: false, phases: {}, output_lines: 0, output_bytes: 0,
          extras: [], warnings: 0, errors: 0, warnings_complete: false,
          features: [], success: false, failure: nil, duration: 0.0
        }
      end

      def consume(event)
        info = event.info
        case event.kind
        when :start, :scan, :loaded, :conflicts, :forge, :complete
          @stats.merge!(info)
        when :states
          @stats[:states] = info[:count]
        when :phase_end
          name = info.fetch(:name).to_s
          @stats[:phases][name] = @stats[:phases].fetch(name, 0.0) + info.fetch(:duration)
        when :split
          @stats[:split_states] += info[:count]
        when :extra
          @stats[:extras] |= [info[:kind]]
        when :warning, :error
          @stats[event.kind == :warning ? :warnings : :errors] += 1
        when :warnings_complete
          @stats[:warnings_complete] = true
        when :grammar_break, :expect_mismatch, :validation_break
          @stats[:failure] = {kind: event.kind, **info}
          @stats[:success] = false
        end
        self
      end

      def collect(bus)
        bus.each { |event| consume(event) }
        self
      end

      def to_h = @stats
    end
  end
end
