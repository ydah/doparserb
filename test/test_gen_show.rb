# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class GenShowTest < Test::Unit::TestCase
  def setup
    assert_const_defined(Doparserb::Gen, :Show)
    assert_const_defined(Doparserb, :Engine)
  end

  def test_catalogue_has_every_generation_scene
    kinds = %i[title scan loaded evolve fusion states lookahead split slash boss flawless forge extra warning new_ability record critical jackpot achievement llama_drop finale grammar_break expect_mismatch validation_break]
    assert_equal(kinds.sort, Doparserb::Gen::Scenes::KINDS.sort)
    kinds.each do |kind|
      scene = Doparserb::Gen::Scenes.build(kind, Doparserb::Gen::Scenes::DEMO_STATS)
      assert_not_empty(scene.title, kind.to_s)
      assert_equal(kind, scene.kind)
    end
  end

  def test_reel_prioritizes_strong_scenes_and_folds_extras_into_forge
    stats = Doparserb::Gen::Scenes::DEMO_STATS.merge(extras: %i[header report], parameterized: 4, inline_expansions: 3)
    scenes = Doparserb::Gen::Scenes.reel(stats)
    assert_equal(:finale, scenes.last.kind)
    assert_compare(scenes.length, :<=, 5)
    assert_include(scenes.map(&:kind), :flawless)
    forge = scenes.find { |scene| scene.kind == :forge }
    assert_include(forge.subtitle, "+HEADER")
    assert_include(forge.subtitle, "+REPORT")
    assert_include(scenes.map(&:subtitle).join(" "), "EVOLVE x4")
  end

  def test_failures_have_only_the_specific_failure_scene
    stats = Doparserb::Gen::Scenes::DEMO_STATS.merge(success: false, failure: {kind: :expect_mismatch}, expect: 2, sr_conflicts: 3, rr_conflicts: 0)
    scenes = Doparserb::Gen::Scenes.reel(stats)
    assert_equal([:expect_mismatch], scenes.map(&:kind))
    assert_include(scenes.first.subtitle, "EXPECTED 2, FOUND 3")
  end

  def test_noninteractive_show_collects_without_rendering_or_loading_irb
    bus = Doparserb::EventBus.new
    output = StringIO.new
    config = Doparserb::Config.new(env: {})
    engine = Doparserb::Engine.new(config, output: output, input: StringIO.new)
    show = Doparserb::Gen::Show.new(bus, config: config, engine: engine).start
    bus.emit(:states, count: 29)
    bus.emit(:complete, success: true, duration: 0.01)
    bus.close
    show.finish
    assert_equal(29, show.collector.to_h[:states])
    assert_equal("", output.string)
  end

  def test_engine_loads_without_irb_or_reline_in_a_fresh_process
    program = <<~RUBY
      require "doparserb"
      Doparserb::Engine
      abort "IRB was loaded" if Object.const_defined?(:IRB)
      abort "Reline was loaded" if Object.const_defined?(:Reline)
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", program)
    assert_equal(0, status.exitstatus, stderr)
    assert_empty(stdout)
    assert_empty(stderr)
  end

  def test_tty_lock_is_exclusive_and_reusable
    Dir.mktmpdir("doparserb-lock") do |directory|
      path = File.join(directory, "tty.lock")
      first = Doparserb::TTYLock.new(path: path)
      second = Doparserb::TTYLock.new(path: path)
      assert_true(first.acquire)
      assert_false(second.acquire)
      first.close
      assert_true(second.acquire)
    ensure
      first&.close
      second&.close
    end
  end

  def test_effect_output_removes_every_sgr_without_rewriting_cursor_controls
    output = StringIO.new
    writer = Doparserb::Engine::EffectOutput.new(output, no_color: true)
    writer.write("\e[31mred\e[0m\e[2K\e[m")
    assert_equal("red\e[2K", output.string)
  end

  def test_scenes_render_visible_frames_with_only_trusted_art_glyphs
    config = Doparserb::Config.new(settings: ["sound=off,color=none"], env: {})
    engine = Doparserb::Engine.new(config, output: StringIO.new)
    Doparserb::Gen::Scenes::KINDS.each do |kind|
      scene = Doparserb::Gen::Scenes.build(kind, Doparserb::Gen::Scenes::DEMO_STATS)
      lines = engine.render(scene.kind, title: scene.title, subtitle: scene.subtitle, progress: 0.8, data: scene.data, width: 60, height: 10)
      assert(lines.any? { |line| !line.gsub(/\e\[[\d;]*m/, "").strip.empty? }, kind.to_s)
      lines.each do |line|
        plain = line.gsub(/\e\[[\d;]*m/, "")
        assert_compare(plain.length, :<=, 60, kind.to_s)
        assert_no_match(/[^\x20-\x7e\u2580-\u259f\u2800-\u28ff]/, plain, kind.to_s)
      end
    end
  end

  def test_live_meter_renders_one_plain_line
    config = Doparserb::Config.new(settings: ["color=none"], env: {})
    engine = Doparserb::Engine.new(config, output: StringIO.new)
    lines = engine.render(:charging, title: "CHARGING", subtitle: "STATES 256", progress: 0.5, data: {}, width: 30, height: 1)
    assert_equal(["CHARGING  STATES 256"], lines)
  end

  def test_a_broken_scene_does_not_stop_collection_or_the_badge
    engine = Object.new
    badges = []
    engine.define_singleton_method(:session) { |&block| block.call }
    engine.define_singleton_method(:animated?) { false }
    engine.define_singleton_method(:cancelled?) { false }
    engine.define_singleton_method(:clear) {}
    engine.define_singleton_method(:scene) { |*, **| raise IOError, "broken renderer" }
    engine.define_singleton_method(:badge) { |text| badges << text }
    bus = Doparserb::EventBus.new
    config = Doparserb::Config.new(env: {})
    show = Doparserb::Gen::Show.new(bus, config: config, engine: engine).start
    bus.emit(:states, count: 42)
    bus.emit(:complete, success: true)
    bus.close
    assert_nothing_raised { show.finish }
    assert_equal(42, show.collector.to_h[:states])
    assert_equal(1, badges.length)
    assert_include(badges.first, "STATES 42")
  end

  def test_cli_continues_generation_when_engine_initialization_fails
    Dir.mktmpdir("doparserb-engine-failure") do |directory|
      script = <<~RUBY
        require "doparserb"
        class Doparserb::Engine
          def initialize(*)
            raise IOError, "broken terminal"
          end
        end
        exit Doparserb::CLI.new(["--dopa-runtime=off", #{File.join(__dir__, "fixtures/prec.y").inspect}, "-o", #{File.join(directory, "parser.c").inspect}]).run
      RUBY
      _, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
      assert_equal(0, status.exitstatus, stderr)
      assert_path_exist(File.join(directory, "parser.c"))
    end
  end

  def test_full_flash_restores_screen_when_output_interrupts_the_scene
    previous_term = ENV["TERM"]
    ENV["TERM"] = "xterm"
    Dir.mktmpdir("doparserb-flash") do |directory|
      File.open(File.join(directory, "terminal"), "w+") do |output|
        output.define_singleton_method(:tty?) { true }
        output.define_singleton_method(:winsize) { [24, 80] }
        config = Doparserb::Config.new(settings: ["flash=full,sound=off,color=16"], env: {})
        engine = Doparserb::Engine.new(config, output: output, input: StringIO.new)
        engine.session do
          engine.frame(:critical, title: "CRITICAL", progress: 0.5)
          engine.yield_to_output
        end
        output.rewind
        rendered = output.read
        assert_include(rendered, "\e[?5h")
        assert_include(rendered, "\e[?5l")
        assert_operator(rendered.index("\e[?5h"), :<, rendered.index("\e[?5l"))
      end
    end
  ensure
    ENV["TERM"] = previous_term
  end

  def test_long_folded_subtitles_reveal_the_last_highlight
    config = Doparserb::Config.new(settings: ["color=none"], env: {})
    engine = Doparserb::Engine.new(config, output: StringIO.new)
    subtitle = "STATES 256 " * 12 + "INLINE FUSION x3"
    lines = engine.render(:finale, title: "CLEAR", subtitle: subtitle, progress: 1.0, data: {}, width: 30, height: 10)
    assert_include(lines.join, "INLINE FUSION x3")
  end

  def test_finish_can_suppress_presentation_for_an_unprinted_exception
    engine = Object.new
    badges = []
    engine.define_singleton_method(:session) { |&block| block.call }
    engine.define_singleton_method(:animated?) { false }
    engine.define_singleton_method(:cancelled?) { false }
    engine.define_singleton_method(:clear) {}
    engine.define_singleton_method(:scene) { |*, **| }
    engine.define_singleton_method(:badge) { |text| badges << text }
    bus = Doparserb::EventBus.new
    config = Doparserb::Config.new(env: {})
    show = Doparserb::Gen::Show.new(bus, config: config, engine: engine).start
    bus.emit(:validation_break, message: "unprinted exception")
    bus.close
    sleep 0.06
    assert_empty(badges)
    show.finish(present: false)
    assert_empty(badges)
  ensure
    bus&.close
    show&.finish(present: false)
  end

  def test_broken_overlay_never_prevents_program_output
    previous = Doparserb::Engine.active
    broken = Object.new
    broken.define_singleton_method(:yield_to_output) { raise IOError, "broken overlay" }
    Doparserb::Engine.active = broken
    output = StringIO.new
    assert_nothing_raised { Doparserb::Engine.program_output { output.write("original diagnostic") } }
    assert_equal("original diagnostic", output.string)
  ensure
    Doparserb::Engine.active = previous
  end

  def test_adapter_yields_before_writing_each_nonregular_output_destination
    Dir.mktmpdir("doparserb-direct-output") do |directory|
      grammar = File.join(__dir__, "fixtures/prec.y")
      arguments = [
        ["-o", File::NULL],
        ["-H#{File::NULL}"],
        ["--report-file=#{File::NULL}"],
        ["--diagram=#{File::NULL}"]
      ]
      arguments.each do |extra|
        bus = Doparserb::EventBus.new
        command = Doparserb::Command.new([grammar, "-o", File.join(directory, "parser.c"), *extra], events: bus)
        assert_respond_to(command, :before_output=)
        yielded = catch(:terminal_output) do
          command.before_output = -> { throw :terminal_output, true }
          command.run
          false
        end
        assert_true(yielded, extra.inspect)
      end
    end
  end

  def test_adapter_does_not_yield_for_regular_output_files
    Dir.mktmpdir("doparserb-regular-output") do |directory|
      command = Doparserb::Command.new([File.join(__dir__, "fixtures/prec.y"), "-o", File.join(directory, "parser.c")])
      assert_respond_to(command, :before_output=)
      yielded = false
      command.before_output = -> { yielded = true }
      command.run
      assert_false(yielded)
    end
  end

  def test_losing_engine_registers_output_hooks_and_remains_badge_only_after_diagnostics
    previous_term = ENV["TERM"]
    ENV["TERM"] = "xterm"
    Dir.mktmpdir("doparserb-contended-output") do |directory|
      File.open(File.join(directory, "terminal"), "w+") do |output|
        output.define_singleton_method(:tty?) { true }
        output.define_singleton_method(:winsize) { [24, 80] }
        winner = Doparserb::TTYLock.new(output: output)
        assert_true(winner.acquire)
        engine = Doparserb::Engine.new(Doparserb::Config.new(env: {}), output: output, input: StringIO.new)
        engine.session do
          assert_same(engine, Doparserb::Engine.active)
          assert_false(engine.animated?)
          writer = Thread.new { Doparserb::Engine.program_output { :written } }
          assert_nil(writer.join(0.03), "diagnostic must wait while another process owns the terminal")
          winner.close
          assert_equal(:written, writer.value)
          assert_false(engine.animated?, "output access must not enable animation")
          contender = Doparserb::TTYLock.new(output: output)
          assert_false(contender.acquire, "diagnostics retain terminal ownership through the badge")
        ensure
          winner.close
          writer&.join
          contender&.close
        end
      end
    end
  ensure
    ENV["TERM"] = previous_term
  end
end
