# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class PlayShowTest < Test::Unit::TestCase
  class RecordingEngine
    attr_reader :frames, :badges, :actions
    attr_accessor :broken

    def initialize
      @frames, @badges, @actions = [], [], []
    end

    def animated? = true
    def session = yield(self)
    def cancelled? = false
    def scene(kind, **options) = frame(kind, **options)
    def resume = @actions << :resume
    def clear = @actions << :clear
    def yield_to_output = @actions << :yield
    def badge(text, **options) = @badges << [text, options]

    def frame(kind, **options)
      raise IOError, "broken renderer" if broken
      @frames << options.merge(kind: kind)
    end
  end

  METADATA = {
    "symbols" => [{"id" => 2, "name" => "NUMBER"}, {"id" => 3, "name" => "expr"}],
    "rules" => [{"id" => 1, "lhs" => 3, "rhs" => [2], "text" => "expr: NUMBER"}]
  }.freeze

  def setup
    assert(Doparserb.const_defined?(:Play), "parse-time presentation must be available")
    assert_const_defined(Doparserb::Play, :Show)
    @time = 0.0
    @engine = RecordingEngine.new
  end

  def test_full_replay_preserves_order_and_immutable_post_event_snapshots
    show = build_show("replay=full,speed=10")
    sequence = [event("B"), event("T", sym: 2, line: 1, col: 1), event("S", sym: 2, state: 3, depth: 1), event("R", rule: 1, len: 1, state: 3, depth: 1), event("A")]
    sequence.each { |item| show.consume(item, metadata: METADATA) }
    assert_empty(@engine.frames)
    show.finish
    5.times { |index| @time = index * 0.1; show.tick }
    assert_equal(%w[B T S R A], @engine.frames.map { |frame| frame[:data][:event][:code] })
    assert_equal([0, 0, 1, 1, 1], @engine.frames.map { |frame| frame[:data][:depth] })
    assert_equal(2, @engine.frames[2][:data][:blocks].last[:sym])
    assert_equal(3, @engine.frames[3][:data][:blocks].last[:sym])
    assert_true(@engine.frames[2][:data].frozen?)
    assert_true(@engine.frames[2][:data][:blocks].frozen?)
    @time = 1.0
    show.tick
    assert_true(show.done?)
    assert_include(@engine.badges.last.first, "STAGE CLEAR")
  end

  def test_full_replay_obeys_both_speed_boundaries
    [1, 2000].each do |speed|
      @engine = RecordingEngine.new
      show = build_show("replay=full,speed=#{speed}")
      show.consume(event("B"))
      show.consume(event("A"))
      show.tick(now: 0)
      show.tick(now: 0.5 / speed)
      assert_equal(1, @engine.frames.size)
      show.tick(now: 1.0 / speed)
      assert_equal(2, @engine.frames.size)
    end
  end

  def test_full_replay_does_not_catch_up_from_idle_or_reset_its_deadline_on_finish
    show = build_show("replay=full,speed=20")
    show.tick
    @time = 10.0
    show.consume(event("B"))
    show.consume(event("A"))
    show.tick
    assert_equal(1, @engine.frames.size)
    @time = 10.01
    show.finish
    show.tick
    assert_equal(1, @engine.frames.size)
    @time = 10.05
    show.tick
    assert_equal(2, @engine.frames.size)
  end

  def test_finished_parse_history_is_bounded_without_losing_session_totals
    show = build_show("replay=off")
    500.times do |index|
      show.consume(event("B", parse_id: index))
      show.consume(event("S", parse_id: index, sym: 2, state: 3, depth: 1))
      show.consume(event("A", parse_id: index))
    end
    assert_respond_to(show, :tracked_parses)
    assert_compare(show.tracked_parses, :<=, Doparserb::Play::Show::MAX_TOWERS)
    show.finish
    show.tick
    assert_include(@engine.badges.last.first, "500 TOKENS")
    assert_include(@engine.badges.last.first, "STAGE CLEAR")
  end

  def test_every_parse_cache_stays_bounded_when_finished_events_arrive_without_begin
    show = build_show("replay=full")
    128.times { |index| show.consume(event("B", parse_id: index), metadata: METADATA) }
    500.times { |index| show.consume(event("A", parse_id: 128 + index), metadata: METADATA) }
    %i[@towers @metadata @names @max_depths].each do |name|
      assert_compare(show.instance_variable_get(name).size, :<=, Doparserb::Play::Show::MAX_TOWERS, name.to_s)
    end
  end

  def test_late_metadata_relabels_queued_symbols_and_unresolved_rules
    show = build_show("replay=full")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("R", rule: 1, len: 1, state: 3, depth: 1))
    assert(show.respond_to?(:metadata_available), "show must accept completed metadata lookups")
    show.metadata_available("12345678", 42, METADATA)
    assert_empty(@engine.frames)
    show.finish
    drain(show)
    assert_equal("NUMBER", @engine.frames[0][:data][:blocks].last[:label])
    assert_equal("expr", @engine.frames[1][:data][:blocks].last[:label])
    assert_nil(@engine.frames[1][:data][:blocks].last[:sym], "metadata must not rewrite the event-time snapshot")
  end

  def test_late_metadata_preserves_highlight_selection_and_fast_forward_prefix
    show = build_show("replay=highlight")
    show.consume(event("I", sym: 2))
    show.finish
    assert(show.respond_to?(:metadata_available), "show must accept metadata while draining replay")
    show.metadata_available("12345678", 42, METADATA)
    drain(show)
    assert_equal(:inserted, @engine.frames.last[:kind])
    assert_include(@engine.frames.last[:subtitle], ">> x1")
    assert_include(@engine.frames.last[:subtitle], "+ NUMBER INSERTED")
  end

  def test_engine_caps_actual_play_painting_at_forty_frames_per_second
    previous_term = ENV["TERM"]
    ENV["TERM"] = "xterm"
    Dir.mktmpdir("doparserb-play-rate") do |directory|
      File.open(File.join(directory, "terminal"), "w+") do |output|
        output.define_singleton_method(:tty?) { true }
        output.define_singleton_method(:winsize) { [24, 80] }
        config = Doparserb::Config.new(settings: ["sound=off,color=none"], env: {})
        engine = Doparserb::Engine.new(config, output: output, input: StringIO.new)
        time = 0.0
        engine.define_singleton_method(:now) { time }
        engine.session do
          100.times do |index|
            time = index * 0.001
            engine.frame(:shift, title: "RATE FRAME", data: Doparserb::Play::Scenes::DEMO_STATS.merge(play: true))
          end
        end
        output.rewind
        count = output.read.scan("RATE FRAME").size
        assert_equal(4, count)
      end
    end
  ensure
    ENV["TERM"] = previous_term
  end

  def test_highlight_is_bounded_and_finishes_with_the_strongest_scene
    show = build_show("replay=highlight")
    show.consume(event("B"))
    300.times { |index| show.consume(event("S", sym: 2, state: 3, depth: index + 1)) }
    show.consume(event("E", state: 3, sym: 2, line: 4, col: 7))
    show.consume(event("Q", n: 1))
    show.consume(event("I", sym: 2))
    show.consume(event("C"))
    show.consume(event("A"))
    show.finish
    drain(show)
    assert_compare(@time, :<=, 2.1)
    assert_compare(@engine.frames.size, :<=, 65)
    assert_equal(:comeback, @engine.frames.last[:kind])
    assert_include(@engine.frames.map { |frame| frame[:subtitle] }.join(" "), ">> x")
    assert_include(@engine.badges.last.first, "300 TOKENS")
  end

  def test_partial_child_output_holds_frames_until_a_line_boundary
    show = build_show("replay=full")
    show.consume(event("B"))
    show.tick
    show.yield_to_output("answer? ")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    @time = 0.5
    show.tick
    assert_equal(1, @engine.frames.size)
    assert_equal(:yield, @engine.actions.last)
    show.yield_to_output("yes\r\n")
    show.tick
    assert_equal(2, @engine.frames.size)
  end

  def test_finishing_after_a_partial_prompt_discards_replay_without_hanging
    show = build_show("replay=full,speed=1")
    show.consume(event("B"))
    show.consume(event("A"))
    show.yield_to_output("last prompt> ")
    show.finish
    show.tick
    assert_true(show.done?)
    assert_empty(@engine.frames)
    assert_equal(true, @engine.badges.last.last[:new_line])
  end

  def test_cancellation_clears_old_replay_and_allows_new_events_in_the_same_parse
    show = build_show("replay=full")
    show.consume(event("B"))
    show.consume(event("T", sym: 2, line: 1, col: 1))
    show.cancel
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.tick
    assert_equal(["S"], @engine.frames.map { |frame| frame[:data][:event][:code] })
    assert_equal([1], @engine.frames.map { |frame| frame[:data][:event][:parse_id] })
  end

  def test_cancellation_does_not_affect_later_parse_invocations
    show = build_show("replay=full")
    show.consume(event("B"))
    show.cancel
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("A"))
    show.consume(event("B", parse_id: 2))
    show.consume(event("A", parse_id: 2))
    show.finish
    drain(show)
    assert_equal([1, 1, 2, 2], @engine.frames.map { |frame| frame[:data][:event][:parse_id] })
    assert_equal(1, @engine.badges.size)
  end

  def test_cancelled_final_replay_stays_cancelled_without_new_events
    show = build_show("replay=highlight")
    show.consume(event("B"))
    show.consume(event("A"))
    show.finish
    show.cancel
    show.tick
    assert_true(show.done?)
    assert_empty(@engine.frames)
    assert_equal(1, @engine.badges.size)
  end

  def test_large_backlogs_fold_old_events_and_preserve_totals_and_the_result
    show = build_show("replay=full,speed=2000")
    show.consume(event("B"))
    4100.times { show.consume(event("S", sym: 2, state: 3, depth: 1)) }
    show.consume(event("A"))
    assert_compare(show.pending_count, :<=, Doparserb::Play::Show::MAX_PENDING)
    assert_compare(show.folded_events, :>, 0)
    show.finish
    drain(show)
    assert_equal("A", @engine.frames.last[:data][:event][:code])
    assert_include(@engine.badges.last.first, "4100 TOKENS")
    assert_include(@engine.badges.last.first, "FOLDED")
  end

  def test_rendering_failure_does_not_stop_event_collection_or_the_final_badge
    show = build_show("replay=full")
    @engine.broken = true
    show.consume(event("B"))
    assert_nothing_raised { show.tick }
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("A"))
    show.finish
    drain(show)
    assert_include(@engine.badges.last.first, "1 TOKENS")
  end

  def test_replay_off_motion_off_and_intensity_off_never_animate
    ["replay=off", "motion=off", "intensity=off"].each do |setting|
      @engine = RecordingEngine.new
      show = build_show(setting)
      show.consume(event("B"))
      show.consume(event("A"))
      show.finish
      show.tick
      assert_true(show.done?)
      assert_empty(@engine.frames)
      assert_equal(setting == "intensity=off" ? 0 : 1, @engine.badges.size)
    end
  end

  def test_trail_none_has_no_badge
    show = build_show("replay=off,trail=none")
    show.consume(event("A"))
    show.finish
    show.tick
    assert_empty(@engine.badges)
  end

  def test_career_collects_before_animation_filters_and_survives_cancel_and_no_trail
    profile = Doparserb::Profile.new(interactive: true, env: {"DOPAPARSER_PROFILE" => "off"})
    career = Doparserb::Career.new(interactive: true, profile: profile, game: Doparserb::Game.new(seed: 1))
    config = Doparserb::Config.new(settings: ["motion=off,replay=off,trail=none,sound=off"], env: {})
    show = Doparserb::Play::Show.new(config: config, engine: @engine, career: career, clock: -> { @time })
    show.consume(event("B"))
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("R", rule: 1, len: 1, depth: 1))
    show.cancel
    show.consume(event("A"))
    show.finish
    show.finish
    show.tick
    state = profile.read
    assert_equal(1, state["play_runs"])
    assert_equal(1, state["tokens"])
    assert_equal(1, state["best_chain"])
    assert_operator(state["xp"], :>=, 514)
    assert_empty(@engine.frames)
    assert_empty(@engine.badges)
  end

  def test_full_replay_folds_career_rewards_into_the_existing_last_event
    profile = Doparserb::Profile.new(interactive: true, env: {"DOPAPARSER_PROFILE" => "off"})
    career = Doparserb::Career.new(interactive: true, profile: profile, game: Doparserb::Game.new(seed: 1))
    config = Doparserb::Config.new(settings: ["replay=full,speed=30,sound=off"], env: {})
    show = Doparserb::Play::Show.new(config: config, engine: @engine, career: career, clock: -> { @time })
    sequence = [event("B"), event("S", sym: 2, state: 3, depth: 1), event("R", rule: 1, len: 1, depth: 1), event("A")]
    sequence.each { |item| show.consume(item) }
    show.finish
    drain(show)
    assert_equal(%w[B S R A], @engine.frames.map { |frame| frame[:data][:event][:code] })
    assert_equal(:llama_drop, @engine.frames.last[:kind])
    assert_include(@engine.frames.last[:subtitle], "RANK")
    assert_include(@engine.badges.last.first, "LV 2")
  end

  def test_live_events_drained_before_exit_still_show_the_career_ending
    %w[highlight full].each do |replay|
      @engine = RecordingEngine.new
      profile = Doparserb::Profile.new(interactive: true, env: {"DOPAPARSER_PROFILE" => "off"})
      career = Doparserb::Career.new(interactive: true, profile: profile, game: Doparserb::Game.new(seed: 1))
      config = Doparserb::Config.new(settings: ["replay=#{replay},sound=off"], env: {})
      show = Doparserb::Play::Show.new(config: config, engine: @engine, career: career, clock: -> { @time })
      [event("B"), event("S", depth: 1), event("R", rule: 1, len: 1, depth: 1), event("A")].each do |item|
        show.consume(item)
        show.tick
        @time += 0.1
      end
      deadline = @time + 2
      until show.pending_count.zero? || @time >= deadline
        show.tick
        @time += 0.05
      end
      assert_equal(0, show.pending_count)
      show.finish
      drain(show)
      assert_equal(:llama_drop, @engine.frames.last[:kind], replay)
      assert_include(@engine.frames.last[:subtitle], "RANK")
      assert_true(@engine.frames.last[:data][:ending])
    end
  end

  def test_scene_catalogue_covers_every_parse_scene_and_priority
    scenes = Doparserb::Play::Scenes
    kinds = %i[tower next shift reduce chain from_nothing tower_milestone syntax_break collapse recovery repair_plan inserted auto_repair stage_clear comeback aborted exhausted token_milestone critical jackpot llama_drop]
    assert_equal(kinds.sort, scenes::KINDS.sort)
    kinds.each do |kind|
      scene = scenes.build(kind, scenes::DEMO_STATS)
      assert_equal(kind, scene.kind)
      assert_not_empty(scene.title)
    end
    assert_compare(scenes.priority(:auto_repair), :>, scenes.priority(:stage_clear))
    assert_compare(scenes.priority(:syntax_break), :>, scenes.priority(:chain))
    assert_compare(scenes.priority(:chain), :>, scenes.priority(:shift))
  end

  def test_demo_presents_each_scene_without_recording_any_game_state
    config = Doparserb::Config.new(settings: ["sound=off"], env: {})
    assert_respond_to(Doparserb::Play::Show, :demo)
    Doparserb::Play::Show.demo(config, engine: @engine)
    assert_equal(Doparserb::Play::Scenes::KINDS, @engine.frames.map { |frame| frame[:kind] })
    assert_include(@engine.badges.last.first, "PARSE SCENES")
  end

  def test_tower_milestones_celebrate_only_new_maximum_depths
    show = build_show("replay=full")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("S", sym: 2, state: 3, depth: 2))
    show.consume(event("P", n: 1, depth: 1))
    show.consume(event("S", sym: 2, state: 3, depth: 2))
    show.finish
    drain(show)
    assert_equal([:shift, :tower_milestone, :collapse, :shift], @engine.frames.map { |frame| frame[:kind] })
  end

  def test_empty_reduction_chains_keep_both_labels_and_raise_strength
    scenes = Doparserb::Play::Scenes
    scene = scenes.for_event(event("R", rule: 1, len: 0), scenes::DEMO_STATS.merge(chain: 8), {})
    assert_equal(:chain, scene.kind)
    assert_equal(:huge, scene.strength)
    assert_include(scene.subtitle, "FROM NOTHING")
    scene = scenes.build(:chain, scenes::DEMO_STATS.merge(chain: 5))
    assert_equal(:large, scene.strength)
    assert_equal(:large, scenes.build(:chain, scenes::DEMO_STATS.merge(chain: 9)).strength)
  end

  def test_token_milestones_include_thousand_and_million_counts
    scenes = Doparserb::Play::Scenes
    assert_equal("1K TOKENS!", scenes.build(:token_milestone, scenes::DEMO_STATS.merge(tokens: 1000)).title)
    assert_equal("1M TOKENS!!!", scenes.build(:token_milestone, scenes::DEMO_STATS.merge(tokens: 1_000_000)).title)
    assert_equal("1001K TOKENS!", scenes.build(:token_milestone, scenes::DEMO_STATS.merge(tokens: 1_001_000)).title)
    assert_equal(:large, scenes.build(:token_milestone, scenes::DEMO_STATS).strength)
  end

  def test_interleaved_parser_invocations_keep_separate_towers
    show = build_show("replay=full")
    show.consume(event("S", sym: 2, state: 3, depth: 1))
    show.consume(event("S", parser: "87654321", sym: 3, state: 4, depth: 4))
    show.consume(event("A"))
    show.finish
    drain(show)
    assert_equal([1, 4, 1], @engine.frames.map { |frame| frame[:data][:depth] })
    assert_include(@engine.badges.last.first, "2 TOKENS")
  end

  def test_scene_labels_are_sanitized_and_numeric_fallback_is_available
    show = build_show("replay=full")
    metadata = {"symbols" => [{"id" => 2, "name" => "bad\e[2J\nname"}], "rules" => []}
    show.consume(event("S", sym: 2, state: 3, depth: 1), metadata: metadata)
    show.consume(event("R", rule: 99, len: 0, state: 3, depth: 1))
    show.finish
    drain(show)
    assert_not_match(/[\e\n\r]/, @engine.frames.first[:data][:blocks].last[:label])
    assert_include(@engine.frames.last[:data][:blocks].last[:label], "99")
  end

  def test_every_scene_renders_a_tower_and_next_at_narrow_terminal_widths
    engine = Doparserb::Engine.new(Doparserb::Config.new(settings: ["color=none"], env: {}), output: StringIO.new)
    Doparserb::Play::Scenes::KINDS.each do |kind|
      scene = Doparserb::Play::Scenes.build(kind, Doparserb::Play::Scenes::DEMO_STATS)
      [24, 40, 80].each do |width|
        lines = engine.render(kind, title: scene.title, subtitle: scene.subtitle, progress: 0.8, data: scene.data, width: width, height: 10)
        plain = lines.join("\n").gsub(/\e\[[\d;]*m/, "")
        if kind == :llama_drop
          assert_include(plain, "LLAMA DROP", "#{kind}, #{width}")
        else
          assert_include(plain, "STACK TOWER", "#{kind}, #{width}")
          assert_include(plain, "NEXT", "#{kind}, #{width}")
          assert_include(plain, "CHAIN", "#{kind}, #{width}")
        end
        lines.each { |line| assert_compare(line.gsub(/\e\[[\d;]*m/, "").length, :<=, width) }
      end
    end
  end

  def test_low_intensity_frame_keeps_at_least_one_labeled_stack_block
    engine = Doparserb::Engine.new(Doparserb::Config.new(settings: ["intensity=low,color=none"], env: {}), output: StringIO.new)
    scene = Doparserb::Play::Scenes.build(:shift, Doparserb::Play::Scenes::DEMO_STATS)
    lines = engine.render(:shift, title: scene.title, subtitle: scene.subtitle, progress: 1.0, data: scene.data, width: 40, height: 6)
    assert_include(lines.join("\n"), "expr")
  end

  def test_fever_hud_retains_chain_and_combo
    engine = Doparserb::Engine.new(Doparserb::Config.new(settings: ["color=none"], env: {}), output: StringIO.new)
    data = Doparserb::Play::Scenes::DEMO_STATS.merge(play: true, game: {combo: 10, fever: true})
    lines = engine.render(:stage_clear, title: "CLEAR", data: data, subtitle: "", progress: 1, width: 40, height: 10)
    assert_include(lines.join("\n"), "CHAIN 8  COMBO 10  FEVER!")
  end

  private

  def build_show(settings)
    config = Doparserb::Config.new(settings: ["sound=off", settings], env: {})
    Doparserb::Play::Show.new(config: config, engine: @engine, clock: -> { @time }).start
  end

  def event(code, **args)
    {parser: "12345678", pid: 42, parse_id: 1, code: code}.merge(args)
  end

  def drain(show)
    500.times do
      show.tick
      return if show.done?
      @time += 0.025
    end
    flunk("presentation did not finish")
  end
end
