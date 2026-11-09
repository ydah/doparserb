# frozen_string_literal: true

require_relative "game"

module Doparserb
  module Achievements
    def self.unlocks(history:, generation: nil, play: nil, previous: nil)
      generation = (generation || {}).transform_keys(&:to_sym)
      play = (play || {}).transform_keys(&:to_sym)
      previous = (previous || {}).transform_keys(&:to_sym)
      success = generation[:success] == true
      features = history.fetch("features", []) | (success ? generation.fetch(:features, []) : [])
      previous_conflicts = previous.fetch(:conflicts) { previous[:sr_conflicts].to_i + previous[:rr_conflicts].to_i }
      conflicts = generation[:sr_conflicts].to_i + generation[:rr_conflicts].to_i
      conditions = {
        "FIRST FORGE" => success,
        "FLAWLESS x10" => history["flawless_count"].to_i >= Game::FLAWLESS_ACHIEVEMENT,
        "IELR MASTER" => features.include?("ielr"),
        "INLINE ALCHEMIST" => features.include?("inline") || (success && generation[:inline_expansions].to_i.positive?),
        "EVOLUTIONIST" => features.include?("parameterized") || (success && generation[:parameterized].to_i.positive?),
        "BOSS TAMER" => success && generation[:expect_matched],
        "CONFLICT SLAYER" => success && previous_conflicts.positive? && conflicts.zero?,
        "TOWER 64F" => [history["highest_tower"].to_i, play[:max_depth].to_i].max >= Game::TOWER_ACHIEVEMENT,
        "CHAIN 16" => [history["best_chain"].to_i, play[:max_chain].to_i].max >= Game::CHAIN_ACHIEVEMENT,
        "AUTO REPAIRED" => play[:repairs].to_i.positive?,
        "1M TOKENS" => history["tokens"].to_i >= Game::TOKENS_ACHIEVEMENT
      }
      conditions.select { |_, unlocked| unlocked }.keys - history.fetch("achievements", [])
    end
  end
end
