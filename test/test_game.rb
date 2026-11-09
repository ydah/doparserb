# frozen_string_literal: true

require_relative "test_helper"
require "doparserb/game"

class GameTest < Test::Unit::TestCase
  class NoBonus
    def rand(limit) = limit - 1
  end

  class Draws
    attr_reader :limits

    def initialize(*draws)
      @draws = draws
      @limits = []
    end

    def rand(limit)
      @limits << limit
      @draws.shift || limit - 1
    end
  end

  def setup
    @game = Doparserb::Game.new(rng: NoBonus.new)
  end

  def test_generation_scores_each_component_and_rounds_once
    result = @game.generation(stats(states: 7, resolved_conflicts: 2, expect_matched: true),
                              improved: true, new_features: %w[ielr inline inline])
    assert_equal(4500, result[:score])
    assert_true(result[:flawless])
    assert_equal("A", result[:rank])
    assert_equal("GRAMMAR HERO", result[:title])
    assert_equal(1, result[:build_streak])
    assert_equal(1, result[:multiplier])
    assert_nil(result[:bonus])
    assert_equal(158, @game.generation(stats(states: 2, sr_conflicts: 1))[:score])
  end

  def test_expected_conflicts_are_flawless_but_unexpected_conflicts_are_not
    assert_equal(1800, @game.generation(stats(states: 7, sr_conflicts: 2, expect_matched: true))[:score])
    assert_equal(300, @game.generation(stats(states: 7, sr_conflicts: 2))[:score])
    assert_equal(300, @game.generation(stats(states: 7, rr_conflicts: 1))[:score])
  end

  def test_build_fever_starts_at_ten_and_does_not_leak_between_grammars
    ninth = @game.generation(stats, build_streak: 9)
    tenth = @game.generation(stats, build_streak: 10)
    another = @game.generation(stats, build_streak: 1)
    assert_false(ninth[:fever])
    assert_true(tenth[:fever])
    assert_equal(ninth[:score] * 2, tenth[:score])
    assert_equal(ninth[:score], another[:score])
  end

  def test_failed_generation_has_no_points_bonus_or_build_streak
    game = Doparserb::Game.new(rng: Draws.new(0))
    result = game.generation(stats(success: false), build_streak: 11, improved: true)
    assert_equal(0, result[:score])
    assert_equal(0, result[:build_streak])
    assert_false(result[:success])
    assert_false(result[:fever])
    assert_nil(result[:bonus])
  end

  def test_random_bonus_priority_and_all_critical_multipliers
    rng = Draws.new(0, 0)
    jackpot = Doparserb::Game.new(rng: rng).generation(stats(states: 0))
    assert_equal(:jackpot, jackpot[:bonus])
    assert_equal(16_000, jackpot[:score])
    assert_equal([67], rng.limits)
    [2, 4, 8].each_with_index do |multiplier, index|
      critical = Doparserb::Game.new(rng: Draws.new(1, 0, index)).generation(stats(states: 0))
      assert_equal(:critical, critical[:bonus])
      assert_equal(multiplier, critical[:multiplier])
      assert_equal(1000 * multiplier, critical[:score])
    end
  end

  def test_fixed_seed_reproduces_bonus_and_llama_sequences
    games = Array.new(2) { Doparserb::Game.new(seed: 65_535) }
    results = games.map do |game|
      Array.new(100) { [game.generation(stats), game.llama_drop?(success: true), game.choose_llama([0, 2])] }
    end
    assert_equal(*results)
  end

  def test_environment_seed_is_repeatable_and_invalid_seed_is_ignored
    previous = ENV["DOPAPARSER_SEED"]
    ENV["DOPAPARSER_SEED"] = "1234"
    first = Array.new(2) { Doparserb::Game.new }.map { |game| Array.new(10) { game.generation(stats) } }
    assert_equal(*first)
    ENV["DOPAPARSER_SEED"] = "invalid"
    assert_nothing_raised { Doparserb::Game.new.generation(stats) }
  ensure
    ENV["DOPAPARSER_SEED"] = previous
  end

  def test_fixed_seed_bonus_and_drop_frequencies
    game = Doparserb::Game.new(seed: 731)
    trials = 20_000
    counts = Hash.new(0)
    drops = 0
    trials.times do
      counts[game.generation(stats)[:bonus]] += 1
      drops += 1 if game.llama_drop?(success: true)
    end
    assert_in_delta(1.0 / 67, counts[:jackpot].fdiv(trials), 0.004)
    assert_in_delta(66.0 / 67 / 10, counts[:critical].fdiv(trials), 0.012)
    assert_in_delta(1.0 / 50, drops.fdiv(trials), 0.005)
  end

  def test_llama_selection_prefers_unowned_and_stops_when_complete
    game = Doparserb::Game.new(rng: Draws.new(0, 0))
    assert_false(game.llama_drop?(success: false))
    assert_true(game.llama_drop?(success: true))
    assert_equal(1, game.choose_llama([0, 2]))
    assert_nil(game.choose_llama((0...64).to_a))
  end

  def test_rank_and_level_boundaries
    {0 => "C", 1023 => "C", 1024 => "B", 4095 => "B", 4096 => "A", 16_383 => "A", 16_384 => "S"}.each do |score, rank|
      assert_equal(rank, Doparserb::Game.rank(score))
    end
    {0 => 1, 511 => 1, 512 => 2, 1023 => 2, 1024 => 3, 2047 => 3, 2048 => 4,
     (2**100 - 1) => 92, (2**100) => 93}.each do |xp, level|
      assert_equal(level, Doparserb::Game.level(xp))
    end
  end

  def test_token_points_diminish_per_parse_and_reset_at_next_begin
    consume("B")
    assert_equal(10, consume("S", depth: 1)[:points])
    assert_equal(4, consume("S", depth: 2)[:points])
    assert_equal(6, consume("R", depth: 2, len: 2)[:points])
    consume("A")
    consume("B", parse_id: 2)
    assert_equal(10, consume("S", parse_id: 2, depth: 1)[:points])
    consume("A", parse_id: 2)
    result = @game.finish
    assert_equal(1030, result[:score])
    assert_equal(3, result[:tokens])
    assert_equal(1, result[:reductions])
    assert_equal(2, result[:max_depth])
    assert_equal(2, result[:combo])
    assert_true(result[:success])
    assert_false(result[:approximate])
    assert_same(result, @game.finish)
  end

  def test_token_growth_is_concave_for_short_and_long_inputs
    scores = [1, 4, 100, 10_000].map do |length|
      game = Doparserb::Game.new(rng: NoBonus.new)
      game.consume(event("B"))
      length.times { game.consume(event("S", depth: 1)) }
      game.finish[:score]
    end
    assert_equal([10, 20, 100, 1000], scores)
  end

  def test_chain_milestones_and_empty_reduction_depth
    consume("B")
    points = 32.times.map { |i| consume("R", depth: i, len: 0)[:points] }
    assert_equal({2 => 30, 4 => 50, 7 => 100, 15 => 300, 31 => 1000},
                 points.each_with_index.filter_map { |value, i| [i, value] if value.positive? }.to_h)
    consume("S", depth: 33)
    2.times { consume("R", depth: 33, len: 1) }
    consume("E")
    assert_equal(0, consume("R", depth: 32, len: 0)[:points])
    result = @game.finish
    assert_equal(32, result[:max_chain])
    assert_equal(33, result[:max_depth])
    assert_equal(35, result[:reductions])
  end

  def test_ninth_and_tenth_acceptance_then_error_and_comeback
    nine = nil
    10.times do |i|
      consume("B", parse_id: i)
      result = consume("A", parse_id: i)
      nine = result if i == 8
    end
    assert_equal(9, nine[:combo])
    assert_false(nine[:fever])
    consume("B", parse_id: 11)
    assert_equal(20, consume("S", parse_id: 11, depth: 1)[:points])
    broken = consume("E", parse_id: 11)
    assert_equal(0, broken[:combo])
    assert_false(broken[:fever])
    comeback = consume("A", parse_id: 11)
    assert_equal(1500, comeback[:points])
    assert_equal(1, comeback[:combo])
    assert_true(comeback[:comeback])
    assert_equal(7020, @game.finish[:score])
  end

  def test_error_in_one_parser_breaks_session_combo_and_comeback_stays_local
    consume("B")
    consume("E")
    consume("B", parser: "22222222")
    clean = consume("A", parser: "22222222")
    assert_false(clean[:comeback])
    assert_equal(500, clean[:points])
    comeback = consume("A")
    assert_true(comeback[:comeback])
    assert_equal(1, comeback[:combo])
  end

  def test_repair_and_reduce_random_bonuses
    game = Doparserb::Game.new(rng: Draws.new(0))
    game.consume(event("B"))
    reduction = game.consume(event("R", len: 4, depth: 4))
    assert_equal(:jackpot, reduction[:bonus])
    assert_equal(320, reduction[:points])
    assert_equal(300, game.consume(event("C"))[:points])
    game.consume(event("A"))
    assert_equal(1120, game.finish[:score])
    assert_equal(1, game.finish[:repairs])
    assert_equal(:jackpot, game.finish[:bonus])
  end

  def test_abort_exhaustion_missing_begin_and_dropped_events_are_approximate
    %w[Z O].each_with_index do |code, i|
      consume("B", parse_id: i)
      consume(code, parse_id: i)
    end
    consume("D", parse_id: 3, n: 9)
    consume("S", parse_id: 3, depth: 10)
    consume("A", parse_id: 3)
    result = @game.finish
    assert_true(result[:approximate])
    assert_false(result[:success])
    assert_equal(1, result[:tokens])
  end

  def test_loss_notice_before_begin_does_not_fail_the_accepted_parse
    protocol = Doparserb::Play::Protocol.new(executable: "parser")
    results = protocol.consume("F 12345678 42 1\nD 1\nB\nA\n").map { |event| @game.consume(event) }
    assert_equal(0, results.first[:points])
    assert_nil(results.first[:bonus])
    assert_equal(1, results.first[:multiplier])
    result = @game.finish
    assert_true(result[:success])
    assert_true(result[:approximate])
    assert_equal(1, result[:acceptances])
    assert_equal(0, result[:errors])
    assert_equal(500, result[:score])
  ensure
    protocol&.close
  end

  def test_finished_and_unfinished_parse_storage_is_bounded_without_losing_totals
    1000.times do |i|
      consume("B", parse_id: i)
      consume("S", parse_id: i, depth: 1)
      consume("A", parse_id: i)
    end
    assert_empty(@game.instance_variable_get(:@parses))
    200.times do |i|
      consume("B", parse_id: i + 1000)
      consume("S", parse_id: i + 1000, depth: 1)
    end
    assert_operator(@game.instance_variable_get(:@parses).length, :<=, 128)
    result = @game.finish
    assert_equal(1200, result[:tokens])
    assert_true(result[:approximate])
    assert_empty(@game.instance_variable_get(:@parses))
  end

  private

  def stats(**values)
    {success: true, states: 7, resolved_conflicts: 0, sr_conflicts: 0, rr_conflicts: 0,
     expect_matched: false, features: []}.merge(values)
  end

  def event(code, **args)
    {parser: "11111111", pid: 12, parse_id: 1, code: code}.merge(args)
  end

  def consume(code, **args)
    @game.consume(event(code, **args))
  end
end
