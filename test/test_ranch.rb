# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "stringio"
require_relative "support/pty_driver"
require "doparserb/ranch" if File.exist?(File.expand_path("../lib/doparserb/ranch.rb", __dir__))

class RanchTest < Test::Unit::TestCase
  class RecordingEngine
    attr_reader :scenes, :badges
    attr_accessor :cancel_after, :animated

    def initialize
      @scenes, @badges = [], []
      @animated = true
    end

    def session = yield(self)
    def animated? = @animated
    def cancelled? = @cancel_after && @scenes.size >= @cancel_after
    def scene(kind, **options) = @scenes << options.merge(kind: kind)
    def badge(text) = @badges << text
  end

  def setup
    assert_const_defined(Doparserb, :Ranch)
  end

  def test_variants_are_the_immutable_product_of_four_coats_accessories_and_backgrounds
    variants = Doparserb::Ranch.variants
    assert_equal((0...64).to_a, variants.map { |variant| variant[:id] })
    %i[coat accessory background].each { |key| assert_equal(4, variants.map { |variant| variant[key] }.uniq.size) }
    assert_equal(64, variants.map { |variant| variant.values_at(:coat, :accessory, :background) }.uniq.size)
    assert_equal(64, variants.map { |variant| variant[:name] }.uniq.size)
    assert_true(variants.frozen?)
    assert(variants.all?(&:frozen?))
    variants.each { |variant| assert_equal(variant, Doparserb::Ranch.variant(variant[:id])) }
  end

  def test_all_sixty_four_ascii_snapshots_at_forty_and_eighty_columns
    snapshots = JSON.parse(File.read(File.join(__dir__, "fixtures/ranch_snapshots.json")))
    [40, 80].each do |width|
      drawings = 64.times.map do |id|
        lines = Doparserb::Ranch.render(id: id, width: width)
        assert_equal(snapshots.fetch(width.to_s).fetch(id.to_s), lines, "llama #{id}, width #{width}")
        assert_equal(8, lines.size)
        assert(lines.all? { |line| line.ascii_only? && line.length <= width })
        assert_not_match(/[\e\r\t]/, lines.join)
        lines.drop(1)
      end
      assert_equal(64, drawings.uniq.size, "the art, not only the label, must identify each llama")
    end
  end

  def test_walking_changes_the_pose_and_stays_bounded
    still = Doparserb::Ranch.render(id: 17, width: 40)
    walking = Doparserb::Ranch.render(id: 17, width: 40, tick: 1)
    assert_not_equal(still.drop(1), walking.drop(1))
    assert_equal(walking, Doparserb::Ranch.render(id: 17, width: 40, tick: 1))
    [1, 2, 5, 20, 40, 80, 100_000].each do |width|
      lines = Doparserb::Ranch.render(id: 63, width: width, tick: 999)
      assert(lines.all? { |line| line.length <= [width, 120].min })
    end
  end

  def test_unowned_llamas_are_anonymous_silhouettes_without_accessories_or_backgrounds
    first = Doparserb::Ranch.render(id: 0, width: 40, owned: false)
    last = Doparserb::Ranch.render(id: 63, width: 40, owned: false)
    assert_include(first.first, "UNKNOWN")
    assert_equal(first.drop(1), last.drop(1))
    assert_not_equal(Doparserb::Ranch.render(id: 0, width: 40).drop(1), first.drop(1))
  end

  def test_half_block_art_contains_only_trusted_pixel_glyphs_and_ascii
    lines = Doparserb::Ranch.render(id: 63, width: 40, ascii: false)
    assert_match(/[▀▄█]/, lines.join)
    assert_not_match(/[^\x20-\x7e▀▄█]/, lines.join)
    assert(lines.all? { |line| line.length <= 40 })
  end

  def test_invalid_ids_and_widths_are_rejected_at_the_renderer_boundary
    [-1, 64, nil, "1", 1.2].each do |id|
      assert_raise(ArgumentError) { Doparserb::Ranch.variant(id) }
      assert_raise(ArgumentError) { Doparserb::Ranch.render(id: id, width: 40) }
    end
    [-1, 0, nil, "40", 2.5].each do |width|
      assert_raise(ArgumentError) { Doparserb::Ranch.render(id: 0, width: width) }
    end
  end

  def test_ranch_animates_owned_ids_and_leaves_a_stable_summary
    engine = RecordingEngine.new
    owned = [0, 17, 63].freeze
    Doparserb::Ranch.new(config: config, engine: engine).show(owned: owned)
    assert_equal(1, engine.scenes.size)
    assert_equal(:ranch, engine.scenes.first[:kind])
    assert_equal(owned, engine.scenes.first[:data][:ids])
    assert_equal(2.0, engine.scenes.first[:duration])
    assert_include(engine.badges.last, "3/64")
    assert_equal([0, 17, 63], owned)
  end

  def test_tour_visits_every_id_including_unowned_silhouettes
    engine = RecordingEngine.new
    Doparserb::Ranch.new(config: config, engine: engine).show(owned: [17], tour: true)
    assert_equal((0...64).to_a, engine.scenes.map { |scene| scene[:data][:ids].first })
    assert(engine.scenes.all? { |scene| scene[:data][:owned] == [17] })
    assert_in_delta(6.4, engine.scenes.sum { |scene| scene[:duration] }, 0.001)
    assert_include(engine.badges.last, "1/64")
  end

  def test_cancelled_tour_stops_without_visiting_remaining_llamas
    engine = RecordingEngine.new
    engine.cancel_after = 2
    Doparserb::Ranch.new(config: config, engine: engine).show(owned: [], tour: true)
    assert_equal(2, engine.scenes.size)
    assert_equal(1, engine.badges.size)
  end

  def test_empty_or_disabled_motion_ranch_does_not_animate
    engine = RecordingEngine.new
    Doparserb::Ranch.new(config: config, engine: engine).show(owned: [])
    assert_empty(engine.scenes)
    assert_include(engine.badges.last, "0/64")
    engine.animated = false
    Doparserb::Ranch.new(config: config, engine: engine).show(owned: [0], tour: true)
    assert_empty(engine.scenes)
  end

  def test_non_tty_ranch_writes_nothing_and_does_not_load_reline
    output = StringIO.new
    engine = Doparserb::Engine.new(config, output: output, input: StringIO.new)
    Doparserb::Ranch.new(config: config, engine: engine).show(owned: [0], tour: true)
    assert_empty(output.string)
    program = 'require "doparserb"; require "doparserb/ranch"; Doparserb::Engine; abort "Reline loaded" if Object.const_defined?(:Reline)'
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", program)
    assert_equal(0, status.exitstatus, stderr)
    assert_empty(stdout)
    assert_empty(stderr)
  end

  def test_engine_renders_ranch_and_drop_art_with_safe_labels_and_no_color
    engine = Doparserb::Engine.new(config, output: StringIO.new)
    with_glyph_width(2) do
      %i[ranch llama_drop].each do |kind|
        [24, 40, 80].each do |width|
          lines = engine.render(kind, title: "LLAMA\e[2J\nDROP", subtitle: "FOUND", progress: 0.5,
            data: {id: 17, ids: [17, 63], owned: [17, 63]}, width: width, height: 10)
          assert_equal(10, lines.size)
          assert(lines.all? { |line| line.ascii_only? && line.length <= width })
          assert_not_match(/[\e\n\r]/, lines.join)
          assert_match(/Amber|Slate/, lines.join)
          assert_include(lines.last, "FOUND")
        end
      end
    end
  end

  def test_engine_accepts_trusted_half_blocks_only_when_terminal_width_allows_them
    engine = Doparserb::Engine.new(config, output: StringIO.new)
    with_glyph_width(1) do
      lines = engine.render(:llama_drop, title: "UNTRUSTED █", subtitle: "", progress: 0.5,
        data: {id: 17}, width: 40, height: 10)
      assert_match(/[▀▄█]/, lines.drop(1).join)
      assert_not_include(lines.first, "█")
      assert_not_match(/[^\x20-\x7e▀▄█]/, lines.join)
    end
  end

  def test_engine_has_four_distinct_coat_colors
    no_color = ENV.delete("NO_COLOR")
    colorful = Doparserb::Config.new(settings: ["color=truecolor"], env: {})
    engine = Doparserb::Engine.new(colorful, output: StringIO.new)
    colors = [[240, 235, 220], [230, 165, 65], [225, 120, 155], [125, 155, 185]]
    colors.each_with_index do |color, index|
      lines = engine.render(:llama_drop, title: "DROP", subtitle: "", progress: 0,
        data: {id: index * 16}, width: 40, height: 10)
      assert_include(lines.join, "38;2;#{color.join(';')}")
    end
  ensure
    ENV["NO_COLOR"] = no_color
  end

  def test_terminal_ranch_finishes_cleanly_at_forty_and_eighty_columns
    program = <<~'RUBY'
      require "doparserb"
      require "doparserb/ranch"
      config = Doparserb::Config.new(settings: ["sound=off,duration=0.1"])
      Doparserb::Ranch.new(config: config).show(owned: [0, 17, 63])
    RUBY
    driver = nil
    [40, 80].each do |width|
      driver = PTYDriver.new([RbConfig.ruby, "-Ilib", "-e", program], cols: width, env: {"NO_COLOR" => "1"})
      assert_equal(0, driver.wait_exit)
      assert_include(driver.raw_output, "#00")
      assert_equal("LLAMA RANCH | 3/64 COLLECTED", driver.all_text)
      assert_not_match(/\e\[[\d;]*m/, driver.raw_output)
      assert_equal({}, driver.unknown)
      driver.close
    end
  ensure
    driver&.close
  end

  def test_terminal_tour_cancels_within_fifty_milliseconds_and_preserves_the_key
    program = <<~'RUBY'
      require "doparserb"
      require "doparserb/ranch"
      Doparserb::Ranch.new(config: Doparserb::Config.new(settings: ["sound=off"])).show(owned: [], tour: true)
      key = STDIN.raw { STDIN.read(1) }
      STDOUT.write("PRESERVED:#{key}\n")
    RUBY
    driver = PTYDriver.new([RbConfig.ruby, "-Ilib", "-e", program])
    driver.wait_for("UNKNOWN LLAMA", raw: true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    driver.send_keys("x")
    driver.wait_for("PRESERVED:x", timeout: 2)
    latency = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_compare(latency, :<=, 0.050)
    assert_equal(0, driver.wait_exit)
    assert_equal({}, driver.unknown)
  ensure
    driver&.close
  end

  private

  def config
    Doparserb::Config.new(settings: ["sound=off,color=none"], env: {})
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
