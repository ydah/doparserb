# frozen_string_literal: true

module Doparserb
  class Game
    STATE_POINTS = 100
    PRECEDENCE_POINTS = 50
    EXPECT_POINTS = 500
    FLAWLESS_POINTS = 1000
    IMPROVEMENT_POINTS = 2000
    FEATURE_POINTS = 300
    TOKEN_POINTS = 10
    ACCEPT_POINTS = 500
    REPAIR_POINTS = 300
    COMEBACK_POINTS = 1000
    CHAIN_BONUSES = {3 => 30, 5 => 50, 8 => 100, 16 => 300, 32 => 1000}.freeze
    FEVER_THRESHOLD = 10
    FEVER_MULTIPLIER = 2
    CRITICAL_ODDS = 10
    CRITICAL_MULTIPLIERS = [2, 4, 8].freeze
    JACKPOT_ODDS = 67
    JACKPOT_MULTIPLIER = 16
    LLAMA_DROP_ODDS = 50
    LLAMA_COUNT = 64
    LEVEL_TWO_XP = 512
    RANK_THRESHOLDS = {"S" => 16_384, "A" => 4096, "B" => 1024, "C" => 0}.freeze
    TITLES = {"S" => "LEGENDARY LLAMA", "A" => "GRAMMAR HERO", "B" => "PARSER PILOT", "C" => "STACK ROOKIE"}.freeze
    MAX_PARSES = 128
    FLAWLESS_ACHIEVEMENT = 10
    TOWER_ACHIEVEMENT = 64
    CHAIN_ACHIEVEMENT = 16
    TOKENS_ACHIEVEMENT = 1_000_000
    SPEED_MIN_SECONDS = 0.005
    SPEED_MIN_RATIO = 0.10
    PLAY_CODES = %w[B T S R E P X Q I C A Z O D].freeze

    def self.level(xp)
      [xp.to_i.bit_length - LEVEL_TWO_XP.bit_length + 2, 1].max
    end

    def self.rank(score)
      RANK_THRESHOLDS.find { |_, minimum| score >= minimum }&.first || "C"
    end

    def initialize(seed: ENV["DOPAPARSER_SEED"], rng: nil)
      seed = Integer(seed, exception: false)
      @rng = rng || (seed ? Random.new(seed) : Random.new)
      @parses = {}
      @score = @combo = @acceptances = @failures = 0
      @bonus = nil
      @multiplier = 1
      @totals = {tokens: 0, reductions: 0, max_chain: 0, max_depth: 0, errors: 0,
                 repairs: 0, comeback: false, approximate: false}
    end

    def generation(stats, previous: {}, build_streak: 1, new_features: [], improved: false)
      success = stats[:success] == true
      flawless = success && (stats[:expect_matched] || (stats[:sr_conflicts].to_i.zero? && stats[:rr_conflicts].to_i.zero?))
      streak = success ? [build_streak, 1].max : 0
      fever = streak >= FEVER_THRESHOLD
      bonus, multiplier = success ? random_bonus : [nil, 1]
      points = STATE_POINTS * Math.log2(stats[:states].to_i + 1)
      points += PRECEDENCE_POINTS * stats[:resolved_conflicts].to_i
      points += EXPECT_POINTS if stats[:expect_matched]
      points += FLAWLESS_POINTS if flawless
      points += IMPROVEMENT_POINTS if improved
      points += FEATURE_POINTS * new_features.uniq.length
      score = success ? points.floor * multiplier * (fever ? FEVER_MULTIPLIER : 1) : 0
      rank = self.class.rank(score)
      {score: score, rank: rank, title: TITLES.fetch(rank), success: success, flawless: !!flawless,
       build_streak: streak, fever: fever, bonus: bonus, multiplier: multiplier}.freeze
    end

    def consume(event)
      return if @finished || !PLAY_CODES.include?(event[:code])

      if event[:code] == "D"
        @totals[:approximate] = true if event[:n].positive?
        return result.merge(points: 0, bonus: nil, multiplier: 1, comeback: false).freeze
      end

      key = event.values_at(:parser, :pid, :parse_id)
      code = event[:code]
      if code == "B" && @parses.delete(key)
        @totals[:approximate] = true
        @failures += 1
      end
      state = @parses[key] ||= begin_parse(code)
      points = 0
      comeback = false
      bonus = nil
      multiplier = 1
      case code
      when "S"
        points = token_points(state, 1)
        state[:chain] = 0
        @totals[:tokens] += 1
      when "R"
        points = token_points(state, event[:len])
        state[:chain] += 1
        @totals[:max_chain] = [@totals[:max_chain], state[:chain]].max
        @totals[:reductions] += 1
        points += CHAIN_BONUSES.fetch(state[:chain], 0)
        bonus, multiplier = random_bonus
      when "E"
        @combo = state[:chain] = 0
        state[:error] = true
        @totals[:errors] += 1
      when "C"
        @totals[:repairs] += 1
        points = REPAIR_POINTS
      when "A"
        comeback = state[:error]
        @totals[:comeback] ||= comeback
        @combo = comeback ? 1 : @combo + 1
        @acceptances += 1
        points = ACCEPT_POINTS + (comeback ? COMEBACK_POINTS : 0)
        @parses.delete(key)
      when "Z", "O"
        @failures += 1
        @combo = 0
        @parses.delete(key)
      end
      track_depth(event)
      points *= multiplier * (@combo >= FEVER_THRESHOLD ? FEVER_MULTIPLIER : 1)
      @score += points
      if multiplier > @multiplier
        @bonus = bonus
        @multiplier = multiplier
      end
      result.merge(points: points, bonus: bonus, multiplier: multiplier, comeback: comeback).freeze
    end

    def finish
      return @finished if @finished

      unless @parses.empty?
        @totals[:approximate] = true
        @failures += @parses.length
        @parses.clear
      end
      @finished = result.freeze
    end

    def llama_drop?(success:)
      success && @rng.rand(LLAMA_DROP_ODDS).zero?
    end

    def choose_llama(owned)
      available = (0...LLAMA_COUNT).to_a - owned
      available[@rng.rand(available.length)] unless available.empty?
    end

    private

    def random_bonus
      return [:jackpot, JACKPOT_MULTIPLIER] if @rng.rand(JACKPOT_ODDS).zero?
      return [nil, 1] unless @rng.rand(CRITICAL_ODDS).zero?

      [:critical, CRITICAL_MULTIPLIERS[@rng.rand(CRITICAL_MULTIPLIERS.length)]]
    end

    def begin_parse(code)
      if @parses.length >= MAX_PARSES
        @parses.shift
        @failures += 1
        @totals[:approximate] = true
      end
      @totals[:approximate] = true unless code == "B"
      {units: 0, chain: 0, error: false}
    end

    def token_points(state, units)
      before = (TOKEN_POINTS * Math.sqrt(state[:units])).floor
      state[:units] += units
      (TOKEN_POINTS * Math.sqrt(state[:units])).floor - before
    end

    def track_depth(event)
      return unless event.key?(:depth)

      depth = event[:depth]
      if event[:code] == "R"
        reduced = depth - event[:len] + 1
        @totals[:approximate] = true if event[:len] > depth
        depth = [depth, reduced].max
      end
      @totals[:max_depth] = [@totals[:max_depth], depth].max
    end

    def result
      rank = self.class.rank(@score)
      @totals.merge(score: @score, rank: rank, title: TITLES.fetch(rank), combo: @combo,
                    fever: @combo >= FEVER_THRESHOLD, acceptances: @acceptances,
                    success: @acceptances.positive? && @failures.zero?, bonus: @bonus, multiplier: @multiplier)
    end
  end
end
