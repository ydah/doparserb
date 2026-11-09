# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class VisualsTest < Test::Unit::TestCase
  SGR = /\e\[[\d;]*m/
  PHASES = [0.12, 0.56, 0.90].freeze

  def setup
    @no_color = ENV.delete("NO_COLOR")
    Doparserb::Engine
    Object.const_get(:Dopairb)::Term.reset_glyphs
  end

  def teardown
    ENV["NO_COLOR"] = @no_color
    Object.const_get(:Dopairb)::Term.reset_glyphs
  end

  def test_standalone_typography_uses_neutral_width_pixels_without_loading_reline
    program = <<~'RUBY'
      require "doparserb"
      require "stringio"
      config = Doparserb::Config.new(settings: ["sound=off,color=none,flash=off"], env: {})
      engine = Doparserb::Engine.new(config, output: StringIO.new)
      lines = engine.render(:title, title: "DOPARSERB", subtitle: "GRAMMAR IN / PARSER OUT",
                            progress: 0.8, data: {}, width: 80, height: 18)
      abort "standalone typography lost its braille pixels" unless lines.join.include?("⣿")
      abort "ambiguous block width was forced narrow" if Object.const_get(:Dopairb)::Term.char_width("█") == 1
      abort "IRB was loaded" if Object.const_defined?(:IRB)
      abort "Reline was loaded" if Object.const_defined?(:Reline)
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", program)
    assert_equal(0, status.exitstatus, stderr)
    assert_empty(stdout)
  end

  %i[title scan boss forge].each do |kind|
    define_method("test_#{kind}_uses_multiple_foreground_colors_without_flashing") do
      engine = build_engine
      scene = generation_scene(kind)
      lines = render(engine, scene, progress: 0.56)
      foregrounds = lines.join.scan(/38;2;(\d+);(\d+);(\d+)/).uniq
      assert_operator(foregrounds.size, :>=, 3, "#{kind} needs contrasting foreground colors with flash disabled")
    end
  end

  %i[shift reduce chain recovery stage_clear comeback].each do |kind|
    define_method("test_#{kind}_changes_geometry_across_animation_phases") do
      engine = build_engine(color: "none")
      scene = playback_scene(kind)
      frames = PHASES.map { |progress| plain(render(engine, scene, progress: progress)) }
      assert_operator(frames.uniq.size, :>=, 2, "#{kind} must animate geometry, not only its color")
    end
  end

  def test_every_scene_fits_small_and_large_terminal_canvases
    engine = build_engine
    scenes.each do |scene|
      [30, 40, 80, 120].each do |width|
        [8, 18].each do |height|
          PHASES.each do |progress|
            lines = render(engine, scene, progress: progress, width: width, height: height)
            assert_equal(height, lines.length, "#{scene.kind}: #{width}x#{height}")
            invalid = plain(lines).find { |line| line.length > width || line.match?(/[\x00-\x1f\x7f]/) }
            assert_nil(invalid, "#{scene.kind}: unsafe or overflowing row at #{width}x#{height}, progress #{progress}: #{invalid.inspect}")
          end
        end
      end
    end
  end

  def test_no_color_removes_styling_from_every_scene
    config = Doparserb::Config.new(settings: ["sound=off,color=truecolor,flash=off"], env: {"NO_COLOR" => "1"})
    engine = Doparserb::Engine.new(config, output: StringIO.new)
    scenes.each do |scene|
      assert_no_match(/\e/, render(engine, scene, progress: 0.56).join, scene.kind.to_s)
    end
  end

  def test_trusted_art_does_not_allow_terminal_controls_or_block_glyphs_in_labels
    engine = build_engine(color: "none")
    lines = engine.render(:loaded, title: "MARKER█END", subtitle: "FOOTER▀END\e[2J\n\x00",
                          progress: 0.8, data: Doparserb::Gen::Scenes::DEMO_STATS, width: 80, height: 18)
    text = lines.join
    assert_include(text, "MARKER?END")
    assert_include(text, "FOOTER?END")
    assert_no_match(/[\x00-\x1f\x7f]/, text)
  end

  def test_incompatible_glyph_widths_use_bounded_ascii_fallbacks
    engine = build_engine(color: "none")
    with_glyph_width(2) do
      scenes.each do |scene|
        lines = render(engine, scene, progress: 0.56, width: 40, height: 10)
        assert(lines.all? { |line| line.ascii_only? && line.length <= 40 }, scene.kind.to_s)
      end
    end
  end

  def test_narrow_playback_keeps_the_stack_and_next_token_hud_readable
    engine = build_engine(color: "none")
    scene = playback_scene(:chain)
    [30, 40, 80, 120].each do |width|
      lines = plain(render(engine, scene, progress: 0.56, width: width, height: 10))
      %w[STACK NEXT NUMBER DEPTH CHAIN].each do |label|
        assert_include(lines.join("\n"), label, "missing #{label} at #{width} columns")
      end
      assert(lines.any? { |line| line.include?(scene.title) }, "scene title is clipped at #{width} columns")
      next_row = lines.index { |line| line.include?("NEXT") }
      token_row = lines.index { |line| line.include?("NUMBER") }
      assert_not_equal(next_row, token_row, "next-token label overwrites its heading at #{width} columns")
    end
  end

  def test_jackpot_reels_spin_then_land_on_three_sevens
    engine = build_engine(color: "none")
    scene = generation_scene(:jackpot)
    reels = [0.12, 0.48, 1.0].map do |progress|
      plain(render(engine, scene, progress: progress)).join.scan(/\| (\d)  \|/).flatten
    end
    assert_equal(["7", "7", "7"], reels.last)
    assert_equal([3, 3, 3], reels.map(&:size))
    assert_operator(reels.uniq.size, :>=, 2)
  end

  def test_animation_paints_the_latest_event_without_replaying_its_sound
    engine = build_engine
    paints = []
    engine.define_singleton_method(:paint_frame) { |**frame| paints << frame }
    engine.frame(:shift, title: "SHIFT", data: {play: true})
    engine.frame(:chain, title: "8 CHAIN!", data: {play: true, chain: 8})
    engine.animate(progress: 0.5)
    assert_equal([true, true, false], paints.map { |frame| frame[:audio] })
    assert_equal(:chain, paints.last[:kind])
    assert_equal(8, paints.last.dig(:data, :chain))
    assert_equal(0.5, paints.last[:progress])
  end

  private

  def build_engine(color: "truecolor")
    config = Doparserb::Config.new(settings: ["sound=off,flash=off,color=#{color}"], env: {})
    Doparserb::Engine.new(config, output: StringIO.new)
  end

  def generation_scene(kind)
    Doparserb::Gen::Scenes.build(kind, Doparserb::Gen::Scenes::DEMO_STATS)
  end

  def playback_scene(kind)
    Doparserb::Play::Scenes.build(kind, Doparserb::Play::Scenes::DEMO_STATS)
  end

  def scenes
    Doparserb::Gen::Scenes::KINDS.map { |kind| generation_scene(kind) } +
      Doparserb::Play::Scenes::KINDS.map { |kind| playback_scene(kind) }
  end

  def render(engine, scene, progress:, width: 80, height: 18)
    engine.render(scene.kind, title: scene.title, subtitle: scene.subtitle,
                  data: scene.data, progress: progress, width: width, height: height)
  end

  def plain(lines)
    lines.map { |line| line.gsub(SGR, "") }
  end

  def with_glyph_width(width)
    term = Object.const_get(:Dopairb)::Term
    original = term.method(:char_width)
    term.define_singleton_method(:char_width) { |char| char.ascii_only? ? 1 : width }
    term.reset_glyphs
    yield
  ensure
    term&.define_singleton_method(:char_width, original) if original
    term&.reset_glyphs
  end
end
