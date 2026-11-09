# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "timeout"

class SoundBankTest < Test::Unit::TestCase
  class Backend
    attr_reader :calls
    attr_accessor :available, :before_discovery, :before_file

    def initialize
      @calls = Queue.new
      @available = true
    end

    def backend
      @before_discovery&.call
      [:fast, ["/fake/player"]] if @available
    end

    def file(name, step)
      @before_file&.call
      @calls << [:file, name, step, Thread.current]
      ["/fake/sound.wav", 0, 0.1]
    end
  end

  def setup
    assert_const_defined(Doparserb, :SoundBank)
    @engine = nil
    @time = 0.0
    @output = StringIO.new
  end

  def teardown
    @engine&.send(:stop_sound)
  end

  def test_all_requested_patches_synthesize_finite_original_samples
    bank = Doparserb::SoundBank
    assert_equal(%i[dopa_shift dopa_reduce dopa_chain dopa_states dopa_slash dopa_boss dopa_forge dopa_repair dopa_clear].sort,
                 bank::PATCHES.keys.sort)
    Doparserb::Engine
    bank::PATCHES.each_key do |name|
      samples, impact = bank.render(name, 0, synth: Dopairb::Sound::Synth)
      assert_operator(samples.length, :>, 0, name.to_s)
      assert_operator(samples.length, :<=, Dopairb::Sound::RATE, name.to_s)
      assert(samples.all? { |sample| sample.is_a?(Numeric) && sample.finite? }, name.to_s)
      assert(samples.any?(&:positive?) && samples.any?(&:negative?), "#{name} must oscillate around zero")
      assert_operator(impact, :>=, 0)
      assert_operator(impact, :<, samples.length.fdiv(Dopairb::Sound::RATE))
    end
  end

  def test_chain_notes_rise_by_one_semitone_and_have_a_bounded_cache_range
    bank = Doparserb::SoundBank
    synth = Object.new
    frequencies = []
    synth.define_singleton_method(:tone) { |frequency, *_, **_| frequencies << frequency; [0.1] }
    3.times { |step| bank.render(:dopa_chain, step, synth: synth) }
    assert_in_delta(2**(1.0 / 12), frequencies[1] / frequencies[0], 1e-10)
    assert_in_delta(2**(1.0 / 12), frequencies[2] / frequencies[1], 1e-10)
    assert_equal([:dopa_chain, 0], bank.selection(:chain, chain: 1))
    assert_equal([:dopa_chain, bank::MAX_CHAIN_STEP], bank.selection(:chain, chain: 1_000_000))
    assert_equal([:dopa_chain, 0], bank.selection(:chain, chain: -10))
  end

  def test_every_generation_and_play_scene_has_a_known_sound
    Doparserb::Engine
    kinds = Doparserb::Gen::Scenes::KINDS + Doparserb::Play::Scenes::KINDS + %i[charging ranch]
    kinds.each do |kind|
      name, step = Doparserb::SoundBank.selection(kind, chain: 5)
      assert(Doparserb::SoundBank.custom?(name) || Dopairb::Sound::PATCHES.key?(name), kind.to_s)
      assert_operator(step, :>=, 0)
    end
    assert_equal([:dopa_forge, 0], Doparserb::SoundBank.selection(:forge))
    assert_equal([:dopa_repair, 0], Doparserb::SoundBank.selection(:auto_repair))
    assert_equal([:dopa_clear, 0], Doparserb::SoundBank.selection(:comeback))
  end

  def test_off_returns_before_clock_patch_lookup_or_backend_work
    engine = build_engine("off")
    calls = []
    engine.define_singleton_method(:now) { calls << :clock; 0 }
    engine.define_singleton_method(:sound_backend) { calls << :backend; Backend.new }
    data = Object.new
    data.define_singleton_method(:[]) { |_| calls << :patch_data; 1 }
    bank_class = Doparserb::SoundBank.singleton_class
    trace = TracePoint.new(:call) { |point| calls << point.method_id if point.defined_class == bank_class }
    assert_nothing_raised { trace.enable { engine.send(:sound, :unknown, data) } }
    assert_empty(calls)
    assert_nil(engine.instance_variable_get(:@audio_queue))
    assert_nil(engine.instance_variable_get(:@audio_thread))
    assert_empty(@output.string)
  end

  def test_bell_mode_never_discovers_a_player_and_throttles_identical_sounds_for_thirty_ms
    engine = build_engine("bell")
    discoveries = []
    engine.define_singleton_method(:sound_backend) { discoveries << true; Backend.new }
    engine.send(:sound, :shift)
    @time = 0.029
    engine.send(:sound, :shift)
    assert_equal("\a", @output.string)
    @time = 0.03
    engine.send(:sound, :shift)
    assert_equal("\a\a", @output.string)
    engine.send(:sound, :reduce)
    assert_equal("\a\a\a", @output.string)
    assert_empty(discoveries)
  end

  def test_missing_player_falls_back_to_bell_but_busy_player_does_not
    backend = Backend.new
    backend.available = false
    engine = build_engine("sfx", backend: backend)
    engine.send(:sound, :shift)
    wait_until { @output.string == "\a" }
    assert_true(backend.calls.empty?)
    backend.available = true
    engine.instance_variable_set(:@sound_players, [1, 2, 3, 4])
    @time = 0.1
    engine.send(:sound, :reduce)
    wait_idle(engine)
    assert_true(backend.calls.empty?)
    assert_equal("\a", @output.string)
  end

  def test_slow_discovery_and_cold_cache_never_wait_in_the_calling_thread
    backend = Backend.new
    entered, release = Queue.new, Queue.new
    backend.before_discovery = -> { entered << true; release.pop }
    engine = build_engine("sfx", backend: backend)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    engine.send(:sound, :states)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator(elapsed, :<, 0.05)
    take(entered)
    backend.before_discovery = nil
    backend.before_file = -> { entered << true; release.pop }
    release << true
    take(entered)
    assert_true(backend.calls.empty?)
    release << true
    calls = [take(backend.calls), take(backend.calls)]
    assert_equal(%i[file play], calls.map(&:first))
    assert(calls.all? { |call| call.last != Thread.current })
  ensure
    4.times { release << true } if release
  end

  def test_audio_queue_is_bounded_and_session_stop_does_not_wait_for_worker
    backend = Backend.new
    entered, release = Queue.new, Queue.new
    backend.before_discovery = -> { entered << true; release.pop }
    engine = build_engine("sfx", backend: backend)
    engine.send(:sound, :shift)
    take(entered)
    100.times do
      @time += 0.031
      engine.send(:sound, :reduce)
    end
    queue = engine.instance_variable_get(:@audio_queue)
    assert_operator(queue.size, :<=, Doparserb::Engine::SOUND_QUEUE_LIMIT)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    engine.send(:stop_sound)
    assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.05)
    assert_true(queue.closed?)
    assert_equal(0, queue.size)
    release << true
    wait_until { !engine.instance_variable_get(:@audio_thread)&.alive? }
    assert_true(backend.calls.empty?)
    assert_empty(@output.string)
  ensure
    4.times { release << true } if release
  end

  def test_cold_synthesis_drops_audio_that_has_become_stale
    backend = Backend.new
    entered, release = Queue.new, Queue.new
    backend.before_file = -> { entered << true; release.pop }
    engine = build_engine("sfx", backend: backend)
    engine.send(:sound, :forge)
    take(entered)
    @time = Doparserb::Engine::SOUND_MAX_DELAY + 0.001
    release << true
    assert_equal(:file, take(backend.calls).first)
    engine.send(:stop_sound)
    engine.instance_variable_get(:@audio_thread).join(1)
    assert_true(backend.calls.empty?, "stale audio must not reach the player")
  ensure
    release << true if release
  end

  def test_play_cancellation_invalidates_audio_already_rendering_with_preserved_input
    backend = Backend.new
    entered, release = Queue.new, Queue.new
    backend.before_file = -> { entered << true; release.pop }
    engine = build_engine("sfx", backend: backend)
    engine.instance_variable_set(:@preserve_input, true)
    show = Doparserb::Play::Show.new(config: engine.config, engine: engine)
    engine.send(:sound, :reduce)
    take(entered)
    show.cancel
    release << true
    assert_equal(:file, take(backend.calls).first)
    engine.instance_variable_get(:@audio_thread).join(1)
    assert_true(backend.calls.empty?, "cancelled audio must not reach the player")
    assert_nil(engine.instance_variable_get(:@audio_queue))
  ensure
    release << true if release
  end

  def test_native_key_cancellation_stops_players_before_the_session_ends
    engine = build_engine("sfx")
    readable = false
    input = Object.new
    input.define_singleton_method(:tty?) { true }
    input.define_singleton_method(:wait_readable) { |_| readable }
    engine.instance_variable_set(:@input, input)
    stopped = []
    engine.define_singleton_method(:stop_sound_player) { |pid| stopped << pid }
    engine.send(:sound, :forge)
    wait_until { engine.instance_variable_get(:@sound_players) == [1] }
    readable = true
    assert_true(engine.cancelled?)
    assert_equal([1], stopped)
    assert_empty(engine.instance_variable_get(:@sound_players))
    assert_true(engine.cancelled?)
    assert_equal([1], stopped, "repeated cancellation must not stop a reused pid")
  end

  def test_player_argument_preparation_cannot_start_stale_audio
    backend = Backend.new
    engine = build_engine("sfx", backend: backend)
    advance = -> { @time = Doparserb::Engine::SOUND_MAX_DELAY + 0.001 }
    engine.define_singleton_method(:sound_player_arguments) { |_, arguments, path| advance.call; arguments + [path] }
    engine.send(:sound, :reduce)
    assert_equal(:file, take(backend.calls).first)
    wait_idle(engine)
    assert_true(backend.calls.empty?, "slow argument preparation must not play stale audio")
  end

  def test_paused_cancelled_and_unowned_engines_never_start_audio
    engine = build_engine("sfx")
    discoveries = []
    engine.define_singleton_method(:sound_backend) { discoveries << true; Backend.new }
    engine.instance_variable_set(:@paused, true)
    engine.send(:sound, :shift)
    engine.instance_variable_set(:@paused, false)
    engine.instance_variable_set(:@cancelled, true)
    engine.send(:sound, :shift)
    engine.instance_variable_set(:@cancelled, false)
    engine.instance_variable_set(:@animation_owner, false)
    engine.send(:sound, :shift)
    assert_nil(engine.instance_variable_get(:@audio_queue))
    assert_empty(@output.string)
    assert_empty(discoveries)
  end

  def test_only_one_player_launch_can_be_pending_and_late_launch_is_cancelled
    engine = build_engine("sfx")
    entered, release, stopped = Queue.new, Queue.new, Queue.new
    engine.define_singleton_method(:spawn_sound_player) { |_| entered << true; release.pop; 42 }
    engine.define_singleton_method(:stop_sound_player) { |pid| stopped << pid }
    engine.send(:sound, :shift)
    take(entered)
    8.times do
      @time += 0.045
      engine.send(:sound, :shift)
    end
    assert_true(entered.empty?, "one dispatch worker must own player launches")
    engine.silence
    release << true
    assert_equal(42, take(stopped))
    engine.instance_variable_get(:@audio_thread).join(1)
    assert_true(entered.empty?)
    assert_empty(engine.instance_variable_get(:@sound_players))
  ensure
    release << true if release
  end

  def test_real_player_process_groups_are_bounded_and_stopped_without_playing_audio
    directory = Dir.mktmpdir("doparserb-audio-stop")
    program = 'trap("TERM") {}; File.write(File.join(ARGV.first, Process.pid.to_s), "ready"); sleep 10'
    backend = Object.new
    backend.define_singleton_method(:backend) { [:fast, [RbConfig.ruby, "-e", program, "--"]] }
    backend.define_singleton_method(:file) { |*| [directory, 0, 0.1] }
    engine = build_engine("sfx", backend: backend)
    %i[shift reduce states forge].each { |kind| engine.send(:sound, kind) }
    wait_until { engine.instance_variable_get(:@sound_players).length == 4 }
    pids = engine.instance_variable_get(:@sound_players).dup
    wait_until { pids.all? { |pid| File.exist?(File.join(directory, pid.to_s)) } }
    pids.each { |pid| Process.kill("TERM", -pid) }
    assert(pids.all? { |pid| Process.kill(0, pid) == 1 })
    @time = 0.1
    %i[shift reduce states forge].each { |kind| engine.send(:sound, kind) }
    wait_idle(engine)
    assert_equal(pids, engine.instance_variable_get(:@sound_players))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    engine.silence
    assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.05)
    wait_until do
      pids.all? do |pid|
        begin
          Process.kill(0, pid)
          false
        rescue Errno::ESRCH
          true
        end
      end
    end
    assert_empty(engine.instance_variable_get(:@sound_players))
  ensure
    pids&.each do |pid|
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
    end
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end

  def test_log_backend_uses_the_engine_wav_cache_without_mutating_upstream_patches
    Doparserb::Engine
    bank = Dopairb::Sound
    original = bank::PATCHES
    with_sound_cache do |directory|
      log = File.join(directory, "sounds.log")
      bank.instance_variable_set(:@backend, [:log, [log]])
      engine = build_engine("sfx", backend: bank)
      engine.send(:sound, :forge)
      wait_until { File.exist?(log) && !File.read(log).empty? }
      path = File.read(log).split.last
      assert_include(File.basename(path), "doparserb-")
      assert_equal("RIFF", File.binread(path, 4))
      assert_path_exist("#{path}.meta")
      first = bank.file(:dopa_forge, 0)
      stamp = File.mtime(first.first)
      bank.instance_variable_set(:@files, {})
      assert_equal(first, bank.file(:dopa_forge, 0))
      assert_equal(stamp, File.mtime(first.first))
      assert_same(original, bank::PATCHES)
      assert_true(original.frozen?)
      assert_false(original.key?(:dopa_forge))
      assert_equal("key", bank.key_for(:key, 1))
    end
  end

  def test_scene_internal_frames_are_silent_but_live_frames_dispatch_audio
    engine = build_engine("bell")
    calls = []
    engine.define_singleton_method(:sound) { |kind, data = {}| calls << [kind, data[:chain]] }
    engine.define_singleton_method(:render) { |*, **| [] }
    engine.define_singleton_method(:dimensions) { [24, 80] }
    engine.define_singleton_method(:wait) { |_| @test_clock += 0.03; true }
    engine.instance_variable_set(:@test_clock, 0.0)
    engine.define_singleton_method(:now) { @test_clock }
    stage = Object.new
    stage.define_singleton_method(:open?) { true }
    stage.define_singleton_method(:height) { 10 }
    stage.define_singleton_method(:draw) { |_| }
    stage.define_singleton_method(:close) {}
    engine.instance_variable_set(:@stage, stage)
    engine.scene(:chain, title: "CHAIN", duration: 0.07, data: {play: true, chain: 4})
    assert_equal([[:chain, 4]], calls)
    engine.instance_variable_set(:@stage, stage)
    3.times do
      engine.instance_variable_set(:@test_clock, engine.instance_variable_get(:@test_clock) + 0.05)
      engine.frame(:shift, title: "SHIFT", data: {play: true})
    end
    assert_equal(3, calls.count { |call| call.first == :shift })
  end

  private

  def build_engine(mode, backend: Backend.new)
    config = Doparserb::Config.new(settings: ["sound=#{mode},flash=off,color=none"], env: {})
    @engine = Doparserb::Engine.new(config, output: @output, input: StringIO.new)
    @engine.instance_variable_set(:@writer, Doparserb::Engine::EffectOutput.new(@output, no_color: true))
    @engine.instance_variable_set(:@animation_owner, true)
    @engine.define_singleton_method(:enabled?) { true }
    @engine.define_singleton_method(:animated?) { true }
    clock = -> { @time }
    @engine.define_singleton_method(:now) { clock.call }
    @engine.define_singleton_method(:sound_backend) { backend }
    if backend.is_a?(Backend)
      player = 0
      @engine.define_singleton_method(:spawn_sound_player) do |arguments|
        backend.calls << [:play, arguments, nil, Thread.current]
        player += 1
      end
      @engine.define_singleton_method(:sound_player_running?) { |_| true }
      @engine.define_singleton_method(:stop_sound_player) { |_| }
    end
    @engine
  end

  def take(queue)
    Timeout.timeout(2) { queue.pop }
  end

  def wait_until
    Timeout.timeout(2) { sleep 0.001 until yield }
  end

  def wait_idle(engine)
    wait_until { engine.instance_variable_get(:@audio_queue).empty? && engine.instance_variable_get(:@audio_thread).status == "sleep" }
  end

  def with_sound_cache
    bank = Dopairb::Sound
    names = %i[@dir @files @backend @last @children]
    saved = names.to_h { |name| [name, [bank.instance_variable_defined?(name), bank.instance_variable_get(name)]] }
    Dir.mktmpdir("doparserb-sound") do |directory|
      bank.instance_variable_set(:@dir, directory)
      bank.instance_variable_set(:@files, {})
      bank.instance_variable_set(:@last, {})
      bank.instance_variable_set(:@children, [])
      yield directory
    end
  ensure
    @engine&.send(:stop_sound)
    @engine&.instance_variable_get(:@audio_thread)&.join(1)
    saved&.each { |name, (exists, value)| exists ? bank.instance_variable_set(name, value) : bank.remove_instance_variable(name) if exists || bank.instance_variable_defined?(name) }
  end
end
