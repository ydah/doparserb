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

  def test_demo_scenes_have_time_for_a_readable_animation
    Doparserb::Play::Show.demo(Doparserb::Config.new(env: {}), engine: @engine)
    assert_equal(Doparserb::Play::Scenes::KINDS, @engine.scenes.map { |scene| scene[:kind] })
    assert(@engine.scenes.all? { |scene| scene[:duration].between?(0.5, 0.75) })
    assert_operator(@engine.scenes.sum { |scene| scene[:duration] }, :<=, 16)
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

  def build_show(settings)
    config = Doparserb::Config.new(settings: [settings], env: {})
    Doparserb::Play::Show.new(config: config, engine: @engine, career: SilentCareer.new, clock: -> { @time }).start
  end

  def event(code, **values)
    {code: code, parser: "12345678", pid: 42, parse_id: 1}.merge(values)
  end
end
