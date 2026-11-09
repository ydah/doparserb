# frozen_string_literal: true

require_relative "test_helper"
require "doparserb/play/tower"

class PlayTowerTest < Test::Unit::TestCase
  def setup
    @tower = Doparserb::Play::Tower.new
  end

  def test_shift_and_lookahead_have_separate_roles
    assert_same(@tower, consume("B"))
    consume("T", sym: 3, line: 2, col: 7)
    assert_equal({sym: 3, line: 2, col: 7}, state[:next_token])
    assert_equal(0, state[:tokens])
    consume("S", sym: 3, state: 5, depth: 1)
    assert_equal([{sym: 3, state: 5}], state[:blocks])
    assert_nil(state[:next_token])
    assert_equal(1, state[:tokens])
    assert_equal(1, state[:depth])
    assert_equal(1, state[:max_depth])
  end

  def test_reduce_uses_pre_reduction_depth_and_metadata_lhs
    3.times { |i| consume("S", sym: i + 3, state: i + 4, depth: i + 1) }
    metadata = {"rules" => [{"id" => 7, "lhs" => 9}]}
    @tower.consume({code: "R", rule: 7, len: 3, state: 6, depth: 3}, metadata: metadata)
    assert_equal(1, state[:depth])
    assert_equal([{sym: 9, state: 6, rule: 7}], state[:blocks])
    assert_equal(3, state[:max_depth])
    assert_equal(1, state[:reductions])
    assert_equal(1, state[:chain])
  end

  def test_empty_reductions_grow_and_keep_lookahead
    consume("T", sym: 3, line: 1, col: 1)
    consume("R", rule: 7, len: 0, state: 0, depth: 0)
    assert_equal(1, state[:depth])
    assert_equal([{sym: nil, state: 0, rule: 7}], state[:blocks])
    assert_equal({sym: 3, line: 1, col: 1}, state[:next_token])
  end

  def test_chain_maximum_survives_shifts_and_errors
    3.times { |i| consume("R", rule: 1, len: 0, state: 0, depth: i) }
    assert_equal(3, state[:chain])
    consume("S", sym: 3, state: 5, depth: 4)
    assert_equal(0, state[:chain])
    consume("R", rule: 1, len: 1, state: 5, depth: 4)
    consume("E", state: 5, sym: 4, line: 3, col: 7)
    assert_equal(0, state[:chain])
    assert_equal(3, state[:max_chain])
    assert_equal(1, state[:errors])
  end

  def test_pop_and_error_shift_use_authoritative_depth_after_disrupted_action
    3.times { |i| consume("S", sym: 3, state: 5, depth: i + 1) }
    consume("R", rule: 1, len: 3, state: 5, depth: 3)
    consume("E", state: 5, sym: 4, line: 3, col: 7)
    consume("P", n: 1, depth: 2)
    assert_equal(2, state[:depth])
    assert_equal(2, state[:blocks].length)
    consume("X", state: 8, depth: 3)
    assert_equal(3, state[:depth])
    assert_equal({sym: 1, state: 8}, state[:blocks].last)
    consume("P", n: 3, depth: 0)
    assert_empty(state[:blocks])
    assert_equal(0, state[:depth])
  end

  def test_repair_counts_insertions_and_completions
    consume("Q", n: 2)
    assert_equal(0, state[:repairs])
    2.times { consume("I", sym: 4) }
    consume("C")
    assert_equal(2, state[:inserted])
    assert_equal(1, state[:repairs])
    assert_equal(0, state[:tokens])
  end

  def test_acceptance_after_an_error_is_a_comeback
    consume("E", state: 0, sym: 3, line: 1, col: 1)
    consume("A")
    assert_equal("A", state[:outcome])
    assert_true(state[:accepted])
    assert_true(state[:comeback])
  end

  def test_abort_and_exhaustion_remain_distinct_without_acceptance
    %w[Z O].each do |code|
      consume("B")
      consume(code)
      assert_equal(code, state[:outcome])
      assert_false(state[:accepted])
      assert_false(state[:comeback])
    end
  end

  def test_drop_counts_accumulate_and_make_totals_approximate
    consume("D", n: 4)
    consume("D", n: 7)
    assert_equal(11, state[:discarded])
    assert_true(state[:approximate])
  end

  def test_begin_resets_every_parse_statistic
    consume("S", sym: 3, state: 5, depth: 1)
    consume("R", rule: 1, len: 1, state: 5, depth: 1)
    consume("E", state: 0, sym: 3, line: 1, col: 1)
    consume("I", sym: 4)
    consume("C")
    consume("D", n: 2)
    consume("A")
    consume("B")
    assert_equal(Doparserb::Play::Tower.new.to_h, state)
  end

  def test_snapshots_are_deeply_immutable_and_independent_of_later_updates
    consume("S", sym: 3, state: 5, depth: 1)
    consume("T", sym: 4, line: 1, col: 2)
    snapshot = state
    [snapshot, snapshot[:blocks], snapshot[:blocks].first, snapshot[:next_token]].each do |value|
      assert_predicate(value, :frozen?)
    end
    consume("S", sym: 4, state: 6, depth: 2)
    assert_equal(1, snapshot[:depth])
    assert_equal(1, snapshot[:blocks].length)
    assert_equal(4, snapshot[:next_token][:sym])
  end

  def test_huge_depths_retain_only_bounded_top_blocks_but_preserve_logical_totals
    consume("S", sym: 3, state: 5, depth: 1_000_000_000)
    assert_equal(1_000_000_000, state[:depth])
    assert_equal(1_000_000_000, state[:max_depth])
    assert_operator(state[:blocks].length, :<=, Doparserb::Play::Tower::MAX_BLOCKS)
    assert_equal({sym: 3, state: 5}, state[:blocks].last)
    consume("R", rule: 1, len: 999_999_999, state: 5, depth: 1_000_000_000)
    assert_equal(2, state[:depth])
    assert_equal(2, state[:blocks].length)
    assert_true(state[:approximate])
  end

  private

  def consume(code, **args)
    @tower.consume({code: code}.merge(args))
  end

  def state
    @tower.to_h
  end
end
