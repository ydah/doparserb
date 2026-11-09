# frozen_string_literal: true

require_relative "test_helper"

class PlayAnimationTest < Test::Unit::TestCase
  class AnimatedEngine
    attr_reader :frames, :animations, :actions, :scenes
    attr_accessor :broken

    def initialize
      @frames, @animations, @actions, @scenes = [], [], [], []
    end

    def animated? = true
    def session = yield(self)
    def cancelled? = false
    def resume = @actions << :resume
    def clear = @actions << :clear
    def yield_to_output = @actions << :yield
    def silence = @actions << :silence
    def badge(*) = nil
    def scene(kind, **options) = @scenes << options.merge(kind: kind)
    def frame(kind, **options) = @frames << options.merge(kind: kind)

    def animate(progress:)
      raise IOError, "broken animation" if broken
      @animations << [@frames.last.fetch(:data).dig(:event, :code), progress]
    end
  end

  class SilentCareer
    def consume(*) = {}
    def finish = nil
  end

  class JackpotCareer < SilentCareer
    def consume(event)
      event[:code] == "R" ? {bonus: :jackpot, multiplier: 16} : {}
    end
  end

  def setup
    @engine = AnimatedEngine.new
    @time = 0.0
  end

  def test_animation_advances_between_events_without_replaying_the_event
    show = build_show("replay=full,speed=2")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1))
    show.tick(now: 0)
    assert_equal(0.0, @engine.frames.first[:progress])
    [0.05, 0.10, 0.15].each { |at| show.tick(now: at) }
    assert_equal(1, @engine.frames.length)
    assert_equal(%w[S S S], @engine.animations.map(&:first))
    phases = @engine.animations.map(&:last)
    assert(phases.each_cons(2).all? { |before, after| before < after })
    assert(phases.all? { |phase| phase.positive? && phase < 1 })
    show.tick(now: 0.5)
    assert_equal(%w[S R], @engine.frames.map { |frame| frame[:data][:event][:code] })
    assert_equal(0.0, @engine.frames.last[:progress])
  end

  def test_idle_animation_has_multiple_phases_and_stops_after_its_final_frame
    show = build_show("replay=highlight")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.tick(now: 0)
    [0.05, 0.10, 1.0].each { |at| show.tick(now: at) }
    phases = @engine.animations.map(&:last)
    assert_equal(3, phases.length)
    assert(phases.each_cons(2).all? { |before, after| before < after })
    assert_equal(1.0, phases.last)
    show.tick(now: 2.0)
    assert_equal(phases, @engine.animations.map(&:last))
    assert_equal(1, @engine.frames.length)
    assert_false(show.done?)
  end

  def test_animation_does_not_extend_full_replay_deadlines
    show = build_show("replay=full,speed=20")
    show.consume(event("B"))
    show.consume(event("A"))
    show.finish
    [0, 0.025, 0.05, 0.075].each { |at| show.tick(now: at) }
    assert_equal(%w[B A], @engine.frames.map { |frame| frame[:data][:event][:code] })
    assert_equal(%w[B A], @engine.animations.map(&:first))
    @engine.animations.each { |_, phase| assert_in_delta(0.5, phase, 0.0001) }
    assert_false(show.done?)
    show.tick(now: 0.1)
    assert_true(show.done?)
    count = @engine.animations.length
    show.tick(now: 0.5)
    assert_equal(count, @engine.animations.length)
  end

  def test_idle_animation_respects_the_duration_setting
    show = build_show("replay=highlight,duration=0.1")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.tick(now: 0)
    show.tick(now: 0.04)
    assert_equal([1.0], @engine.animations.map(&:last))
    show.tick(now: 0.1)
    assert_equal(1, @engine.animations.length)
  end

  def test_any_program_output_discards_the_old_animation_until_a_new_event
    ["answer? ", "program output\n", nil].each do |output|
      @engine = AnimatedEngine.new
      show = build_show("replay=full,speed=20")
      show.consume(event("S", sym: 2, state: 3, depth: 1))
      show.tick(now: 0)
      show.tick(now: 0.025)
      before = @engine.animations.dup
      show.yield_to_output(output)
      show.tick(now: 0.1)
      show.tick(now: 0.2)
      assert_equal(before, @engine.animations, output.inspect)
      assert_equal(:yield, @engine.actions.last)
      show.yield_to_output("\n")
      show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1))
      show.tick(now: 0.3)
      show.tick(now: 0.325)
      assert_equal("R", @engine.animations.last&.first)
    end
  end

  def test_cancellation_stops_animation_and_later_input_can_animate
    show = build_show("replay=full,speed=20")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.tick(now: 0)
    show.tick(now: 0.025)
    before = @engine.animations.dup
    show.cancel
    show.tick(now: 0.1)
    assert_equal(before, @engine.animations)
    assert_equal([:silence, :clear], @engine.actions.last(2))
    show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1))
    show.tick(now: 0.2)
    show.tick(now: 0.225)
    assert_equal("R", @engine.animations.last&.first)
  end

  def test_disabled_presentation_never_starts_or_advances_animation
    %w[replay=off motion=off intensity=off].each do |settings|
      @engine = AnimatedEngine.new
      show = build_show(settings)
      show.consume(event("B"))
      show.consume(event("A"))
      show.tick(now: 0)
      show.tick(now: 0.1)
      show.finish
      show.tick(now: 1)
      assert_empty(@engine.frames)
      assert_empty(@engine.animations)
      assert_true(show.done?)
    end
  end

  def test_animation_errors_do_not_lose_queued_parser_events
    show = build_show("replay=full,speed=2")
    show.consume(event("B"))
    show.consume(event("A"))
    show.tick(now: 0)
    @engine.broken = true
    assert_nothing_raised { show.tick(now: 0.1) }
    @engine.broken = false
    show.tick(now: 0.2)
    assert_empty(@engine.animations, "a broken animation must stop until another event")
    show.tick(now: 0.5)
    show.tick(now: 0.6)
    assert_equal(%w[B A], @engine.frames.map { |frame| frame[:data][:event][:code] })
    assert_equal("A", @engine.animations.last&.first)
  end

  def test_demo_gives_rare_scenes_time_for_anticipation_and_payoff
    Doparserb::Play::Show.demo(Doparserb::Config.new(env: {}), engine: @engine)
    assert_equal(Doparserb::Play::Scenes::KINDS, @engine.scenes.map { |scene| scene[:kind] })
    durations = @engine.scenes.to_h { |scene| [scene[:kind], scene[:duration]] }
    %i[shift reduce].each { |kind| assert(durations[kind].between?(0.55, 0.75)) }
    assert_in_delta(0.85, durations[:recovery], 0.001)
    assert_in_delta(0.9, durations[:critical], 0.001)
    assert_in_delta(2.3, durations[:jackpot], 0.001)
    %i[stage_clear comeback].each { |kind| assert_operator(durations[kind], :>=, 1.2) }
    assert_operator(@engine.scenes.sum { |scene| scene[:duration] }, :<=, 24)
  end

  def test_demo_scales_the_longer_scenes_with_the_duration_setting
    config = Doparserb::Config.new(settings: ["duration=0.2"], env: {})
    Doparserb::Play::Show.demo(config, engine: @engine)
    jackpot = @engine.scenes.find { |scene| scene[:kind] == :jackpot }
    assert_in_delta(0.46, jackpot[:duration], 0.001)
  end

  def test_rare_demo_scenes_show_positive_payouts_without_changing_shared_stats
    Doparserb::Play::Show.demo(Doparserb::Config.new(env: {}), engine: @engine)
    {critical: [4, 80], jackpot: [16, 320]}.each do |kind, (multiplier, points)|
      data = @engine.scenes.find { |scene| scene[:kind] == kind }.fetch(:data)
      assert_equal(points, data.dig(:game, :points))
      assert_equal(multiplier, data[:multiplier])
      assert_operator(data.dig(:game, :score), :>=, points)
      assert_operator(data.dig(:game, :combo), :>, 0)
    end
    ordinary = @engine.scenes.reject { |scene| %i[critical jackpot].include?(scene[:kind]) }
    assert(ordinary.all? { |scene| scene[:data][:game].nil? })
    assert_false(Doparserb::Play::Scenes::DEMO_STATS.key?(:game))
  end

  def test_core_demo_scenes_have_matching_post_event_stack_snapshots
    Doparserb::Play::Show.demo(Doparserb::Config.new(env: {}), engine: @engine)
    data = @engine.scenes.to_h { |scene| [scene[:kind], scene[:data]] }
    {shift: ["S", "NUMBER", 0], reduce: ["R", "expr", 1], recovery: ["X", "error", 0]}.each do |kind, (code, label, chain)|
      assert_equal(code, data[kind].dig(:event, :code))
      assert_equal(label, data[kind][:blocks].last[:label])
      assert_equal(chain, data[kind][:chain])
      assert_equal(data[kind][:blocks].size, data[kind][:depth])
    end
    assert_equal("NUMBER", data[:shift][:symbol_label])
    assert_nil(data[:shift][:next_token])
    assert_equal(2, data[:reduce].dig(:event, :len))
    assert_equal(1, data[:reduce][:depth])
    assert_equal(1, data[:recovery][:depth])
    assert_equal(1, data[:recovery][:blocks].last[:sym])
    assert_equal("expr", Doparserb::Play::Scenes::DEMO_STATS[:blocks].last[:label])
    assert_equal(8, Doparserb::Play::Scenes::DEMO_STATS[:chain])
  end

  def test_live_highlight_animates_with_more_events_already_queued
    show = build_show("replay=highlight")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1))
    show.tick(now: 0)
    show.tick(now: 0.05)
    assert_equal(["S"], @engine.frames.map { |frame| frame[:data][:event][:code] })
    assert_equal("S", @engine.animations.last&.first)
    assert(@engine.animations.last.last.between?(0.1, 0.9))
    show.tick(now: 0.15)
    assert_equal(%w[S R], @engine.frames.map { |frame| frame[:data][:event][:code] })
  end

  def test_live_jackpot_holds_for_its_reveal_but_yields_to_output
    show = build_show("replay=highlight", career: JackpotCareer.new)
    show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1))
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.tick(now: 0)
    show.tick(now: 0.5)
    assert_equal([:jackpot], @engine.frames.map { |frame| frame[:kind] })
    assert(@engine.animations.last.last.between?(0.1, 0.9))
    show.yield_to_output("answer? ")
    before = @engine.animations.dup
    show.tick(now: 0.6)
    assert_equal(before, @engine.animations)
    assert_equal(:yield, @engine.actions.last)
    show.yield_to_output("\n")
    show.tick(now: 0.61)
    assert_equal(%i[jackpot shift], @engine.frames.map { |frame| frame[:kind] })
  end

  def test_finishing_highlight_reserves_time_for_the_strongest_scene
    %i[comeback jackpot].each do |ending|
      @engine = AnimatedEngine.new
      @time = 0.0
      career = ending == :jackpot ? JackpotCareer.new : SilentCareer.new
      show = build_show("replay=highlight", career: career)
      24.times { show.consume(event("S", sym: 2, state: 3, depth: 1)) }
      show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1)) if ending == :jackpot
      show.consume(event("E", state: 3, sym: 2, line: 1, col: 1)) if ending == :comeback
      show.consume(event("A"))
      show.finish
      until @engine.frames.last&.fetch(:kind) == ending || @time > 2
        show.tick(now: @time)
        @time += 0.01
      end
      assert_equal(ending, @engine.frames.last[:kind])
      started = @time - 0.01
      show.tick(now: started + 0.4)
      assert_false(show.done?)
      assert_operator(@engine.animations.last.last, :<, 1.0, "the final reveal must still be animating")
      @time = started + 0.4
      until show.done? || @time > 2.1
        show.tick(now: @time)
        @time += 0.01
      end
      assert_true(show.done?)
      assert_operator(@time - started, :>=, 0.55)
      assert_in_delta(1.5, @time, 0.03)
      assert_equal(1.0, @engine.animations.last.last)
    end
  end

  def test_weighted_highlight_keeps_the_minimum_and_maximum_total_budgets
    {0.1 => 1.0, 5 => 2.0}.each do |duration, budget|
      @engine = AnimatedEngine.new
      @time = 0.0
      show = build_show("replay=highlight,duration=#{duration}", career: JackpotCareer.new)
      200.times { show.consume(event("S", sym: 2, state: 3, depth: 1)) }
      show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1))
      show.consume(event("A"))
      show.finish
      until show.done? || @time > budget + 0.1
        show.tick(now: @time)
        @time += 0.01
      end
      assert_true(show.done?)
      assert_in_delta(budget, @time, 0.03)
      assert_equal(:jackpot, @engine.frames.last[:kind])
      assert_operator(@engine.frames.length, :<=, 13)
    end
  end

  def test_jackpot_does_not_override_full_replay_speed
    show = build_show("replay=full,speed=20", career: JackpotCareer.new)
    show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1))
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.finish
    [0, 0.025, 0.05, 0.075].each { |at| show.tick(now: at) }
    assert_equal(%i[jackpot shift], @engine.frames.map { |frame| frame[:kind] })
    assert_false(show.done?)
    show.tick(now: 0.1)
    assert_true(show.done?)
  end

  def test_a_renderer_failure_discards_the_previous_animation
    show = build_show("replay=full,speed=2")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("A"))
    show.tick(now: 0)
    @engine.define_singleton_method(:resume) { raise IOError, "cannot resume renderer" }
    assert_nothing_raised { show.tick(now: 0.5) }
    show.tick(now: 0.6)
    assert_empty(@engine.animations)
  end

  private

  def build_show(settings, career: SilentCareer.new)
    config = Doparserb::Config.new(settings: [settings], env: {})
    Doparserb::Play::Show.new(config: config, engine: @engine, career: career, clock: -> { @time }).start
  end

  def event(code, **values)
    {code: code, parser: "12345678", pid: 42, parse_id: 1}.merge(values)
  end
end
