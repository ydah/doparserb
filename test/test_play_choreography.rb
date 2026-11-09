# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class PlayChoreographyTest < Test::Unit::TestCase
  def setup
    @engine = Doparserb::Engine.new(Doparserb::Config.new(settings: ["color=none,sound=off,flash=off"], env: {}), output: StringIO.new)
  end

  def test_shift_capsule_accelerates_down_then_lands
    panels = [0.1, 0.4, 0.8, 1.0].map { |phase| panel(:shift, phase, symbol_label: "NUMBER") }
    rows = panels.map { |lines| lines.index { |line| line.include?("NUMBER") } }
    assert(rows.none?(&:nil?), "the actual shifted token must remain visible in the close-up")
    assert_operator(rows[0], :<, rows[2])
    assert_equal(rows[2], rows[3])
    assert_not_include(panels[0].join, "LANDED")
    assert_include(panels[2].join, "LANDED")
  end

  def test_reduce_operands_collide_before_the_result_is_revealed
    before = panel(:reduce, 0.1).join("\n")
    after = panel(:reduce, 0.9).join
    assert_include(before, "RHS")
    assert_match(/RHS 2[^\n]*\|\|/, before, "the right operand must retain its full outline")
    assert_not_include(before, "expr")
    assert_not_include(after, "RHS")
    assert_include(after, "expr")
    assert_include(after, "FUSED")
    early = frame(:reduce, 0.1, game: {points: 20, score: 100, combo: 2}).join
    assert_not_include(early, "+20")
    assert_not_include(early, "SCORE 100")
  end

  def test_lookahead_never_depicts_a_completed_shift
    [0.1, 0.65, 1.0].each do |phase|
      body = panel(:next, phase).join
      assert_include(body, "LOOKAHEAD")
      assert_include(body, "NUMBER")
      assert_no_match(/SHIFT|LANDED/, body)
    end
  end

  def test_chain_meter_points_to_a_real_bonus_threshold
    assert_include(frame(:chain, 0.9, chain: 8).join, "CHAIN ->16")
    assert_include(frame(:chain, 0.9, chain: 16).join, "CHAIN ->32")
    assert_include(frame(:chain, 0.9, chain: 32).join, "CHAIN MAX")
  end

  def test_recovery_reconnects_the_broken_structure_without_claiming_acceptance
    before = panel(:recovery, 0.1).join
    after = panel(:recovery, 0.9).join
    assert_include(before, "//")
    assert_include(after, "error")
    assert_include(after, "REJOIN")
    [before, after].each { |frame| assert_no_match(/SUCCESS|CLEAR|ACCEPTED/, frame) }
    assert_not_equal(before, after)
  end

  def test_jackpot_hides_the_win_and_coins_until_the_last_reel_stops
    stats = {game: {points: 160, combo: 2}, multiplier: 16}
    early = frame(:jackpot, 0.1, **stats).join
    tease = frame(:jackpot, 0.5, **stats).join
    win = frame(:jackpot, 1.0, **stats).join
    assert_not_include(early, "JACKPOT")
    assert_not_include(early, "$", "coins must follow the win, not precede it")
    assert_include(tease, "LAST REEL")
    assert_include(win, "JACKPOT")
    assert_include(win, "$", "the win needs a visible coin payoff")
    assert_include(win, "+160")
    assert_operator(panel(:jackpot, 1.0, **stats).join.count("█⣿#"), :>=, 12, "the payoff needs a fitted large display")
  end

  def test_core_scenes_do_not_reuse_the_llama_or_shield
    %i[shift reduce recovery].each do |kind|
      body = panel(kind, 0.9).join
      assert_not_include(body, "~~~~~~", kind.to_s)
      assert_not_include(body, "+++++", kind.to_s)
    end
  end

  def test_soft_flash_occurs_at_the_landing_not_during_the_drop
    previous = ENV.delete("NO_COLOR")
    scene = Doparserb::Play::Scenes.build(:shift, Doparserb::Play::Scenes::DEMO_STATS)
    options = {title: scene.title, subtitle: scene.subtitle, data: scene.data, width: 80, height: 16}
    soft, off = %w[soft off].map do |flash|
      Doparserb::Engine.new(Doparserb::Config.new(settings: ["color=truecolor,sound=off,flash=#{flash}"], env: {}), output: StringIO.new)
    end
    assert_equal(off.render(:shift, **options, progress: 0.48), soft.render(:shift, **options, progress: 0.48))
    assert_not_equal(off.render(:shift, **options, progress: 0.6), soft.render(:shift, **options, progress: 0.6))
  ensure
    ENV["NO_COLOR"] = previous
  end

  def test_hit_sound_waits_for_impact_and_is_cancelled_by_program_output
    previous_term = ENV["TERM"]
    ENV["TERM"] = "xterm"
    Dir.mktmpdir("doparserb-impact") do |directory|
      File.open(File.join(directory, "terminal"), "w+") do |output|
        output.define_singleton_method(:tty?) { true }
        output.define_singleton_method(:winsize) { [24, 80] }
        engine = Doparserb::Engine.new(@engine.config, output: output, input: StringIO.new)
        hits = []
        time = 0.0
        engine.define_singleton_method(:now) { time }
        engine.define_singleton_method(:sound) { |kind, _data| hits << kind }
        engine.session do
          engine.frame(:shift, title: "SHIFT", progress: 0, data: Doparserb::Play::Scenes::DEMO_STATS.merge(play: true))
          assert_empty(hits)
          time = 0.04
          engine.animate(progress: 0.4)
          assert_empty(hits)
          time = 0.08
          engine.animate(progress: 0.7)
          assert_equal([:shift], hits)
          time = 0.12
          engine.animate(progress: 1)
          assert_equal([:shift], hits)
          engine.frame(:recovery, title: "RECOVERY", progress: 0, data: Doparserb::Play::Scenes::DEMO_STATS.merge(play: true))
          engine.yield_to_output
          time = 0.2
          engine.animate(progress: 1)
          assert_equal([:shift], hits)
        end
      end
    end
  ensure
    ENV["TERM"] = previous_term
  end

  private

  def frame(kind, phase, **stats)
    scene = Doparserb::Play::Scenes.build(kind, Doparserb::Play::Scenes::DEMO_STATS.merge(stats))
    @engine.render(kind, title: scene.title, subtitle: scene.subtitle, progress: phase,
                   data: scene.data, width: 80, height: 16)
  end

  def panel(kind, phase, **stats)
    frame(kind, phase, **stats)[3...14].map { |line| line[40..] }
  end
end
