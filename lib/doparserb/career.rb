# frozen_string_literal: true

require "date"
require "digest"

module Doparserb
  class Career
    def initialize(interactive:, profile: nil, game: nil, today: -> { Date.today })
      @interactive = interactive
      @profile = profile || Profile.new(interactive: interactive)
      @game = game || Game.new
      @today = today
    end

    def intro?
      return false unless @interactive
      @profile.update do |history|
        day = @today.call.iso8601
        show = history["intro_day"] != day
        history["intro_day"] = day
        show
      end
    rescue StandardError => error
      Doparserb.debug(error)
      false
    end

    def generation(stats)
      return unless @interactive
      return @generation if @generation
      path, digest = grammar_identity(stats[:grammar]) unless stats[:stdin]
      @generation = @profile.update do |history|
        previous = history["grammars"].fetch(path, {})
        conflicts = stats[:sr_conflicts].to_i + stats[:rr_conflicts].to_i
        records = records_for(stats, previous, conflicts, digest)
        features = stats[:success] ? Array(stats[:features]) - history["features"] : []
        result = @game.generation(stats, previous: previous, build_streak: previous.fetch("build_streak", 0) + 1,
                                  new_features: features, improved: !records.empty?)
        history["generation_runs"] += 1
        history["flawless_count"] += 1 if result[:flawless]
        history["features"] |= features
        history["grammars"][path] = {
          "digest" => digest, "states" => stats[:states].to_i, "conflicts" => conflicts,
          "duration" => stats[:duration].to_f, "success" => result[:success], "build_streak" => result[:build_streak]
        } if path
        unlocks = Achievements.unlocks(history: history, generation: stats.merge(result), previous: previous)
        advance(history, result, unlocks).merge(new_features: features.freeze, records: records.freeze).freeze
      end
    rescue StandardError => error
      Doparserb.debug(error)
      nil
    end

    def consume(event)
      return unless @interactive
      @played = true
      @game.consume(event)
    rescue StandardError => error
      Doparserb.debug(error)
      nil
    end

    def finish
      return unless @interactive && @played
      return @play if @play
      result = @game.finish
      @play = @profile.update do |history|
        history["play_runs"] += 1
        history["tokens"] += result[:tokens]
        history["best_chain"] = [history["best_chain"], result[:max_chain]].max
        history["highest_tower"] = [history["highest_tower"], result[:max_depth]].max
        unlocks = Achievements.unlocks(history: history, play: result)
        advance(history, result, unlocks).freeze
      end
    rescue StandardError => error
      Doparserb.debug(error)
      nil
    end

    def self.summary(result)
      return "" unless result
      parts = ["+#{result[:score]}  LV #{result[:level]}  RANK #{result[:rank]}", result[:title]]
      parts << "FEVER x#{Game::FEVER_MULTIPLIER}" if result[:fever]
      parts << "#{result[:bonus].to_s.upcase} x#{result[:multiplier]}" if result[:bonus]
      parts << "LLAMA DROP! ##{result[:llama]}" if result[:llama]
      parts.concat(result.fetch(:achievements, []))
      parts.join(" / ")
    end

    private

    def grammar_identity(grammar)
      return [grammar.to_s, nil] unless @profile.enabled?
      return [nil, nil] unless grammar && grammar != "-"
      path = File.realpath(grammar)
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        return [nil, nil] unless file.stat.file?
        digest = Digest::SHA256.new
        while (chunk = file.read(16_384))
          digest.update(chunk)
        end
        [path, digest.hexdigest]
      end
    rescue SystemCallError, IOError => error
      Doparserb.debug(error)
      [nil, nil]
    end

    def records_for(stats, previous, conflicts, digest)
      return [] unless stats[:success] && previous["success"]
      records = []
      if conflicts < previous.fetch("conflicts", 0)
        records << "CONFLICTS #{previous['conflicts']} -> #{conflicts}  #{conflicts.zero? ? 'FIXED!' : 'IMPROVED!'}"
      end
      records << "NEW RECORD: STATES #{stats[:states]}" if stats[:states].to_i > previous.fetch("states", 0)
      elapsed = stats[:duration].to_f
      before = previous.fetch("duration", 0)
      if digest && digest == previous["digest"] && before.positive? &&
         before - elapsed >= Game::SPEED_MIN_SECONDS && elapsed <= before * (1 - Game::SPEED_MIN_RATIO)
        records << "FASTER! -#{((1 - elapsed / before) * 100).round}%"
      end
      records
    end

    def advance(history, result, unlocks)
      previous_level = history["level"]
      history["xp"] += result[:score]
      history["level"] = Game.level(history["xp"])
      history["best_score"] = [history["best_score"], result[:score]].max
      history["achievements"] |= unlocks
      day = @today.call
      if history["last_day"] != day.iso8601
        history["daily_streak"] = history["last_day"] == (day - 1).iso8601 ? history["daily_streak"] + 1 : 1
        history["last_day"] = day.iso8601
      end
      drop = history["level"] > previous_level || result[:bonus] == :jackpot || !unlocks.empty? || @game.llama_drop?(success: result[:success])
      llama = @game.choose_llama(history["llamas"]) if drop
      history["llamas"] << llama if llama
      result.merge(level: history["level"], xp: history["xp"], achievements: unlocks.freeze, llama: llama)
    end
  end
end
