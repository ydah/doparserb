# frozen_string_literal: true

require_relative "test_helper"
require "date"
require "json"
require "timeout"

class CareerTest < Test::Unit::TestCase
  class OrdinaryRandom
    def rand(limit) = limit - 1
  end

  def setup
    @directory = Dir.mktmpdir("doparserb-career")
    @grammar = File.join(@directory, "grammar.y")
    @path = File.join(@directory, "state", "profile.json")
    File.write(@grammar, "first grammar")
    @today = Date.new(2026, 11, 9)
    @profile = Doparserb::Profile.new(interactive: true, env: {"DOPAPARSER_PROFILE" => @path})
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_generation_scores_updates_and_awards_only_once
    career = build
    result = career.generation(stats)
    assert_same(result, career.generation(stats))
    state = @profile.read
    assert_equal(1, state["generation_runs"])
    assert_equal(result[:score], state["xp"])
    assert_equal(Doparserb::Game.level(result[:score]), state["level"])
    assert_equal(["FIRST FORGE"], result[:achievements])
    assert_equal(1, state["llamas"].length)
    assert_equal(state["llamas"].first, result[:llama])
    assert_equal(1, state["grammars"][File.realpath(@grammar)]["build_streak"])
    assert_match(/\A[0-9a-f]{64}\z/, state["grammars"][File.realpath(@grammar)]["digest"])
  end

  def test_build_streak_is_per_grammar_and_failure_resets_it
    9.times { build.generation(stats) }
    other = File.join(@directory, "other.y")
    File.write(other, "other grammar")
    assert_equal(1, build.generation(stats.merge(grammar: other))[:build_streak])
    assert_true(build.generation(stats)[:fever])
    failed = build.generation(stats.merge(success: false, failure: {kind: :grammar_break}))
    assert_equal(0, failed[:score])
    assert_equal(0, failed[:build_streak])
    assert_equal(1, build.generation(stats)[:build_streak])
  end

  def test_failed_first_generation_does_not_unlock_first_forge
    result = build.generation(stats.merge(success: false))
    assert_empty(result[:achievements])
    assert_nil(result[:llama])
    assert_equal(1, @profile.read["generation_runs"])
  end

  def test_records_compare_conflicts_across_edits_but_timing_only_for_same_digest
    build.generation(stats.merge(sr_conflicts: 3, duration: 0.1))
    File.write(@grammar, "fixed grammar")
    fixed = build.generation(stats.merge(duration: 0.05))
    assert_include(fixed[:records], "CONFLICTS 3 -> 0  FIXED!")
    assert_include(fixed[:achievements], "CONFLICT SLAYER")
    assert_false(fixed[:records].any? { |record| record.include?("FASTER") })
    faster = build.generation(stats.merge(duration: 0.04))
    assert_include(faster[:records], "FASTER! -20%")
    assert_empty(build.generation(stats.merge(duration: 0.038))[:records])
  end

  def test_speed_record_requires_both_ten_percent_and_five_milliseconds
    build.generation(stats.merge(duration: 0.02))
    assert_empty(build.generation(stats.merge(duration: 0.016))[:records])
    build.generation(stats.merge(duration: 0.2))
    assert_empty(build.generation(stats.merge(duration: 0.19))[:records])
  end

  def test_new_abilities_are_awarded_once_and_failure_does_not_unlock_them
    failed = build.generation(stats.merge(success: false, features: ["ielr"]))
    assert_empty(failed[:new_features])
    first = build.generation(stats.merge(features: ["ielr", "inline"]))
    assert_equal(%w[ielr inline], first[:new_features])
    assert_include(first[:achievements], "IELR MASTER")
    assert_empty(build.generation(stats.merge(features: ["ielr", "inline"]))[:new_features])
  end

  def test_daily_intro_and_streak_are_shared_and_do_not_increment_twice_per_day
    assert_true(build.intro?)
    assert_false(build.intro?)
    build.generation(stats)
    build.generation(stats)
    assert_equal(1, @profile.read["daily_streak"])
    @today += 1
    assert_true(build.intro?)
    build.generation(stats)
    assert_equal(2, @profile.read["daily_streak"])
    @today += 2
    build.generation(stats)
    assert_equal(1, @profile.read["daily_streak"])
  end

  def test_play_collects_raw_events_and_persists_once_at_finish
    career = build
    %w[B S R E C A].each do |code|
      career.consume(parser: "12345678", pid: 1, parse_id: 1, code: code, len: 1, depth: 64)
    end
    result = career.finish
    assert_same(result, career.finish)
    state = @profile.read
    assert_equal(1, state["play_runs"])
    assert_equal(1, state["tokens"])
    assert_equal(64, state["highest_tower"])
    assert_equal(1, state["best_chain"])
    assert_equal(result[:score], state["xp"])
    assert_include(result[:achievements], "TOWER 64F")
    assert_include(result[:achievements], "AUTO REPAIRED")
    assert_true(result[:comeback])
  end

  def test_empty_play_session_does_not_create_a_profile
    assert_nil(build.finish)
    assert_false(File.exist?(@path))
  end

  def test_fifo_and_stdin_grammars_are_never_reopened_for_digesting
    fifo = File.join(@directory, "input.fifo")
    File.mkfifo(fifo)
    result = Timeout.timeout(0.2) { build.generation(stats.merge(grammar: fifo)) }
    assert_operator(result[:score], :>, 0)
    assert_empty(@profile.read["grammars"])
    build.generation(stats.merge(stdin: true))
    assert_empty(@profile.read["grammars"])
  end

  def test_noninteractive_career_does_not_read_or_write_profile_or_grammar
    career = Doparserb::Career.new(interactive: false, profile: @profile)
    assert_nil(career.generation(stats.merge(grammar: "/missing/grammar")))
    assert_nil(career.consume(code: "A"))
    assert_nil(career.finish)
    assert_false(career.intro?)
    assert_false(File.exist?(@path))
  end

  def test_disabled_storage_scores_without_resolving_grammar_paths
    profile = Doparserb::Profile.new(interactive: true, env: {"DOPAPARSER_PROFILE" => "off"})
    career = build(profile: profile)
    result = career.generation(stats.merge(grammar: "/missing/grammar"))
    assert_operator(result[:score], :>, 0)
    assert_equal(1, profile.read["generation_runs"])
    assert_false(File.exist?(@path))
  end

  private

  def build(profile: @profile)
    Doparserb::Career.new(interactive: true, profile: profile,
                         game: Doparserb::Game.new(rng: OrdinaryRandom.new), today: -> { @today })
  end

  def stats
    {grammar: @grammar, states: 31, sr_conflicts: 0, rr_conflicts: 0, resolved_conflicts: 0,
     expect_matched: false, features: [], success: true, duration: 0.1}
  end
end
