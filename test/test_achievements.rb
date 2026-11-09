# frozen_string_literal: true

require_relative "test_helper"
require "doparserb/achievements"

class AchievementsTest < Test::Unit::TestCase
  def test_empty_history_and_failed_generation_unlock_nothing
    assert_empty(unlocks)
    assert_empty(unlocks(generation: {success: false, features: %w[ielr inline parameterized],
                                      expect_matched: true, sr_conflicts: 0, rr_conflicts: 0},
                         previous: {sr_conflicts: 2, rr_conflicts: 1}))
  end

  def test_first_forge_unlocks_once_after_first_success
    result = unlocks(generation: {success: true})
    assert_equal(["FIRST FORGE"], result)
    assert_empty(unlocks(history: {"achievements" => result}, generation: {success: true}))
    assert_empty(unlocks(history: {"generation_runs" => 1}))
    assert_empty(unlocks(history: {"generation_runs" => 1}, generation: {success: false}))
  end

  def test_each_lifetime_threshold_unlocks_at_its_exact_boundary
    {"FLAWLESS x10" => ["flawless_count", 10], "TOWER 64F" => ["highest_tower", 64],
     "CHAIN 16" => ["best_chain", 16], "1M TOKENS" => ["tokens", 1_000_000]}.each do |id, (key, threshold)|
      assert_empty(unlocks(history: {key => threshold - 1}), id)
      assert_equal([id], unlocks(history: {key => threshold}), id)
      assert_empty(unlocks(history: {key => threshold + 1, "achievements" => [id]}), id)
    end
  end

  def test_each_grammar_feature_unlocks_its_achievement_once
    {"ielr" => "IELR MASTER", "inline" => "INLINE ALCHEMIST", "parameterized" => "EVOLUTIONIST"}.each do |feature, id|
      history = {"features" => [feature]}
      assert_equal([id], unlocks(history: history))
      assert_empty(unlocks(history: history.merge("achievements" => [id])))
      assert_equal(["FIRST FORGE", id], unlocks(generation: {success: true, features: [feature]}))
    end
  end

  def test_feature_counters_also_recognize_successful_grammar_features
    assert_equal(["FIRST FORGE", "INLINE ALCHEMIST", "EVOLUTIONIST"],
                 unlocks(generation: {success: true, inline_expansions: 1, parameterized: 2}))
  end

  def test_boss_tamer_requires_matching_expect
    assert_equal(["BOSS TAMER"], unlocks(history: {"achievements" => ["FIRST FORGE"]},
                                         generation: {success: true, expect_matched: true}))
    assert_empty(unlocks(history: {"achievements" => ["FIRST FORGE", "BOSS TAMER"]},
                         generation: {success: true, expect_matched: true}))
    assert_empty(unlocks(history: {"achievements" => ["FIRST FORGE"]},
                         generation: {success: true, expect: 2, expect_matched: false}))
  end

  def test_conflict_slayer_requires_previous_nonzero_and_current_zero_conflicts
    clean = {success: true, sr_conflicts: 0, rr_conflicts: 0}
    history = {"achievements" => ["FIRST FORGE"]}
    [{"sr_conflicts" => 2, "rr_conflicts" => 0}, {sr_conflicts: 0, rr_conflicts: 2},
     {"conflicts" => 3}].each do |previous|
      assert_equal(["CONFLICT SLAYER"], unlocks(history: history, generation: clean, previous: previous))
    end
    assert_empty(unlocks(history: history, generation: clean))
    assert_empty(unlocks(history: history, generation: clean, previous: clean))
    assert_empty(unlocks(history: history, generation: clean.merge(rr_conflicts: 1), previous: {sr_conflicts: 2}))
    assert_empty(unlocks(history: {"achievements" => ["FIRST FORGE", "CONFLICT SLAYER"]},
                         generation: clean, previous: {sr_conflicts: 2}))
  end

  def test_play_milestones_and_repair_unlock_without_acceptance
    assert_equal(["TOWER 64F", "CHAIN 16", "AUTO REPAIRED"],
                 unlocks(play: {success: false, max_depth: 64, max_chain: 16, repairs: 1}))
    assert_empty(unlocks(play: {max_depth: 63, max_chain: 15, repairs: 0}))
    assert_empty(unlocks(history: {"achievements" => ["AUTO REPAIRED"]}, play: {repairs: 1}))
  end

  def test_string_result_keys_are_accepted_without_mutating_inputs
    history = {"achievements" => ["FIRST FORGE"]}.freeze
    generation = {"success" => true, "features" => ["ielr"], "expect_matched" => true}.freeze
    assert_equal(["IELR MASTER", "BOSS TAMER"], unlocks(history: history, generation: generation))
    assert_equal(["FIRST FORGE"], history["achievements"])
  end

  def test_all_eleven_achievements_are_distinct_and_repeated_calls_unlock_none
    history = {"generation_runs" => 10, "flawless_count" => 10, "tokens" => 1_000_000,
               "highest_tower" => 64, "best_chain" => 16, "features" => %w[ielr inline parameterized]}
    generation = {success: true, sr_conflicts: 0, rr_conflicts: 0, expect_matched: true}
    args = {history: history, generation: generation, previous: {sr_conflicts: 1}, play: {repairs: 1}}
    ids = unlocks(**args)
    assert_equal(11, ids.uniq.length)
    assert_empty(unlocks(**args.merge(history: history.merge("achievements" => ids))))
  end

  private

  def unlocks(history: {}, **args)
    Doparserb::Achievements.unlocks(history: history, **args)
  end
end
