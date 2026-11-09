# frozen_string_literal: true

module Doparserb
  module Play
    class Tower
      MAX_BLOCKS = 256
      UNKNOWN_BLOCK = {sym: nil, state: nil}.freeze

      def initialize
        reset
      end

      def consume(event, metadata: nil)
        case event[:code]
        when "B" then reset
        when "T" then @next_token = event.slice(:sym, :line, :col).freeze
        when "S"
          resize(event[:depth] - 1)
          push(sym: event[:sym], state: event[:state])
          @tokens += 1
          @chain = 0
          @next_token = nil
        when "R"
          resize(event[:depth])
          resize(event[:depth] - event[:len])
          push(sym: rule_lhs(event[:rule], metadata), state: event[:state], rule: event[:rule])
          @reductions += 1
          @chain += 1
          @max_chain = [@max_chain, @chain].max
        when "E"
          @errors += 1
          @chain = 0
        when "P" then resize(event[:depth])
        when "X"
          resize(event[:depth] - 1)
          push(sym: 1, state: event[:state])
        when "I" then @inserted += 1
        when "C" then @repairs += 1
        when "A", "Z", "O" then @outcome = event[:code].dup.freeze
        when "D"
          @discarded += event[:n]
          @approximate = true if event[:n].positive?
        end
        self
      end

      def to_h
        {blocks: @blocks.dup.freeze, next_token: @next_token, depth: @depth, max_depth: @max_depth,
         tokens: @tokens, reductions: @reductions, chain: @chain, max_chain: @max_chain,
         errors: @errors, repairs: @repairs, inserted: @inserted, outcome: @outcome,
         accepted: @outcome == "A", comeback: @outcome == "A" && @errors.positive?,
         discarded: @discarded, approximate: @approximate}.freeze
      end

      private

      def reset
        @blocks = []
        @next_token = @outcome = nil
        @depth = @max_depth = @tokens = @reductions = @chain = @max_chain = 0
        @errors = @repairs = @inserted = @discarded = 0
        @approximate = false
      end

      def resize(depth)
        @approximate = true if depth.negative?
        depth = [depth, 0].max
        if depth < @depth
          @blocks.pop([@depth - depth, @blocks.length].min)
        elsif depth > @depth
          @approximate = true
          @blocks.concat(Array.new([depth - @depth, MAX_BLOCKS].min, UNKNOWN_BLOCK))
        end
        @depth = depth
        @blocks.shift([@blocks.length - MAX_BLOCKS, 0].max)
        missing = [@depth, MAX_BLOCKS].min - @blocks.length
        @blocks.unshift(*Array.new(missing, UNKNOWN_BLOCK)) if missing.positive?
        @max_depth = [@max_depth, @depth].max
      end

      def push(**block)
        @blocks << block.freeze
        @blocks.shift if @blocks.length > MAX_BLOCKS
        @depth += 1
        @max_depth = [@max_depth, @depth].max
      end

      def rule_lhs(rule, metadata)
        return unless metadata
        unless @metadata.equal?(metadata)
          @metadata = metadata
          @rules = metadata.fetch("rules", []).to_h { |entry| [entry["id"], entry["lhs"]] }
        end
        @rules[rule]
      end
    end
  end
end
