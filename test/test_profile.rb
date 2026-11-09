# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "doparserb/profile"

class ProfileTest < Test::Unit::TestCase
  def setup
    @directory = Dir.mktmpdir("doparserb-profile")
    @path = File.join(@directory, "nested", "profile.json")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_new_profiles_have_independent_mutable_defaults
    assert_const_defined(Doparserb, :Profile)
    profile = Doparserb::Profile.new(interactive: false, env: {})
    assert_equal(0, profile.read.fetch("xp"))
    assert_equal(1, profile.read.fetch("level"))
    assert_equal(:awarded, profile.update { |state| state["xp"] += 25; :awarded })
    assert_equal(25, profile.read.fetch("xp"))
    assert_equal(0, Doparserb::Profile.new(interactive: false, env: {}).read.fetch("xp"))
  end

  def test_disabled_profiles_do_not_resolve_paths_or_touch_the_filesystem
    trace = TracePoint.new(:call, :c_call) do |event|
      filesystem = [File, Dir, FileUtils].include?(event.self) || event.self.is_a?(File)
      raise "Unexpected filesystem call: #{event.method_id}" if filesystem
    end
    trace.enable do
      [
        {interactive: false, env: {"DOPAPARSER_PROFILE" => @path}},
        {interactive: true, env: {"DOPAPARSER_PROFILE" => "off"}}
      ].each do |options|
        profile = Doparserb::Profile.new(**options)
        assert_false(profile.enabled?)
        assert_nil(profile.path)
        assert_equal(0, profile.read.fetch("xp"))
        assert_equal(7, profile.update { |state| state["xp"] += 7 })
      end
    end
  end

  def test_default_xdg_and_custom_paths
    home = File.join(@directory, "home")
    assert_equal(File.join(home, ".local/state/doparserb/profile.json"),
                 Doparserb::Profile.new(interactive: true, env: {"HOME" => home}).path)
    assert_equal(File.join(@directory, "doparserb/profile.json"),
                 Doparserb::Profile.new(interactive: true, env: {"XDG_STATE_HOME" => @directory}).path)
    assert_equal(@path, profile.path)
    assert_true(profile.enabled?)
    assert_equal(File.join(home, ".local/state/doparserb/profile.json"),
                 Doparserb::Profile.new(interactive: true, env: {"HOME" => home, "XDG_STATE_HOME" => ""}).path)
  end

  def test_read_is_detached_and_does_not_create_files
    store = profile
    state = store.read
    state["achievements"] << "FIRST FORGE"
    assert_empty(store.read.fetch("achievements"))
    assert_false(File.exist?(File.dirname(@path)))
  end

  def test_updates_persist_under_private_permissions_and_return_the_block_result
    result = profile.update do |state|
      state["xp"] = 512
      state["level"] = 2
      state["llamas"] << 63
      state["grammars"]["/real/calc.y"] = {"digest" => "abc", "states" => 20, "duration_ms" => 1.5}
      state["future"] = {"nested" => [true, nil, "value"]}
      :awarded
    end
    assert_equal(:awarded, result)
    state = profile.read
    assert_equal(512, state.fetch("xp"))
    assert_equal([63], state.fetch("llamas"))
    assert_equal(1.5, state.fetch("grammars").fetch("/real/calc.y").fetch("duration_ms"))
    assert_equal({"nested" => [true, nil, "value"]}, state.fetch("future"))
    assert_equal(0o700, File.stat(File.dirname(@path)).mode & 0o777)
    assert_equal(0o600, File.stat(@path).mode & 0o777)
    assert_equal(0o600, File.stat("#{@path}.lock").mode & 0o777)
    assert_equal(%w[profile.json profile.json.lock], Dir.children(File.dirname(@path)).sort)
  end

  def test_corrupt_or_invalid_profiles_are_preserved_and_reported
    FileUtils.mkdir_p(File.dirname(@path))
    defaults = profile.read
    invalid = ["{broken", "[]"]
    {
      "v" => [2, "1", 1.0], "xp" => [-1, "2", 2.5], "level" => [0],
      "llamas" => [[64], [1, 1], ["1"]],
      "achievements" => [[false]], "features" => [[1]], "grammars" => [{"x" => []}],
      "last_day" => [12], "intro_day" => [false]
    }.each do |key, values|
      values.each { |value| invalid << JSON.generate(defaults.merge(key => value)) }
    end
    capture_debug do |errors|
      invalid.each do |contents|
        File.binwrite(@path, contents)
        assert_equal(defaults, profile.read)
        assert_equal(:result, profile.update { |state| state["xp"] += 1; :result })
        assert_equal(contents, File.binread(@path))
      end
      assert_equal(invalid.length * 2, errors.length)
    end
  end

  def test_grammar_statistics_reject_invalid_scalars_and_preserve_extensions
    FileUtils.mkdir_p(File.dirname(@path))
    defaults = profile.read
    capture_debug do |errors|
      {"digest" => [false, "not a digest"], "conflicts" => [-1, 0.5], "states" => ["2"],
       "duration" => [-0.1, "1.5"], "success" => ["true"], "build_streak" => [-1]}.each do |key, values|
        values.each do |value|
          contents = JSON.generate(defaults.merge("grammars" => {"/real/calc.y" => {key => value}}))
          File.write(@path, contents)
          assert_equal(defaults, profile.read)
          profile.update { |state| state["xp"] += 1 }
          assert_equal(contents, File.read(@path))
        end
      end
      assert_equal(18, errors.length)
    end
    File.unlink(@path)
    stats = {"digest" => "abcd1234", "conflicts" => 0, "states" => 2, "duration" => 0.5,
             "success" => true, "future" => {"feature" => "enabled"}}
    profile.update { |state| state["grammars"]["/real/calc.y"] = stats }
    assert_equal(stats, profile.read.fetch("grammars").fetch("/real/calc.y"))
  end

  def test_failed_rename_preserves_the_original_and_cleans_up_the_temporary_file
    profile.update { |state| state["xp"] = 1 }
    original = File.method(:rename)
    File.define_singleton_method(:rename) { |*| raise Errno::EACCES }
    calls = 0
    capture_debug do |errors|
      assert_equal(:result, profile.update { |state| calls += 1; state["xp"] += 1; :result })
      assert_equal(1, calls)
      assert_equal(1, profile.read.fetch("xp"))
      assert_equal(%w[profile.json profile.json.lock], Dir.children(File.dirname(@path)).sort)
      assert_equal(1, errors.length)
    end
  ensure
    File.define_singleton_method(:rename, original) if original
  end

  def test_oversized_profiles_are_preserved
    FileUtils.mkdir_p(File.dirname(@path))
    contents = " " * (5 * 1024 * 1024)
    File.binwrite(@path, contents)
    capture_debug do |errors|
      assert_equal(0, profile.read.fetch("xp"))
      assert_equal(1, profile.update { |state| state["xp"] += 1 })
      assert_equal(contents, File.binread(@path))
      assert_equal(2, errors.length)
    end
  end

  def test_symlink_profiles_and_locks_do_not_change_their_targets
    FileUtils.mkdir_p(File.dirname(@path))
    target = File.join(@directory, "target")
    File.write(target, "original")
    [@path, "#{@path}.lock"].each do |link|
      File.unlink(link) if File.exist?(link)
      File.symlink(target, link)
      capture_debug do |errors|
        assert_equal(:result, profile.update { :result })
        assert_equal("original", File.read(target))
        assert_true(File.symlink?(link))
        assert_not_empty(errors)
      end
      File.unlink(link)
    end
  end

  def test_nonregular_profile_and_lock_fail_without_blocking
    FileUtils.mkdir_p(File.dirname(@path))
    [@path, "#{@path}.lock"].each do |path|
      File.unlink(path) if File.exist?(path)
      File.mkfifo(path, 0o600)
      capture_debug do |errors|
        assert_equal(2, profile.update { |state| state["xp"] += 2 })
        assert_true(File.pipe?(path))
        assert_not_empty(errors)
      end
      File.unlink(path)
    end
  end

  def test_unwritable_locations_still_yield_defaults_exactly_once
    File.write(File.dirname(@path), "not a directory")
    calls = 0
    capture_debug do |errors|
      assert_equal(:result, profile.update { |state| calls += 1; assert_equal(0, state.fetch("xp")); :result })
      assert_equal(1, calls)
      assert_not_empty(errors)
    end
  end

  def test_read_only_directories_do_not_interrupt_scoring
    omit("Root bypasses directory write permissions") if Process.uid.zero?
    directory = File.dirname(@path)
    FileUtils.mkdir_p(directory)
    File.chmod(0o500, directory)
    capture_debug do |errors|
      assert_equal(3, profile.update { |state| state["xp"] += 3 })
      assert_false(File.exist?(@path))
      assert_equal(1, errors.length)
    end
  ensure
    File.chmod(0o700, directory) if directory
  end

  def test_unserializable_changes_preserve_the_profile_and_the_block_result
    profile.update { |state| state["xp"] = 1 }
    capture_debug do |errors|
      assert_equal(:result, profile.update do |state|
        state["future"] = state
        :result
      end)
      assert_equal(1, profile.read.fetch("xp"))
      assert_equal(1, errors.length)
    end
  end

  def test_block_errors_propagate_without_saving_and_release_the_lock
    store = profile
    store.update { |state| state["xp"] = 1 }
    assert_raise(Errno::EIO) { store.update { |state| state["xp"] = 99; raise Errno::EIO } }
    assert_equal(1, profile.read.fetch("xp"))
    store.update { |state| state["xp"] += 1 }
    assert_equal(2, profile.read.fetch("xp"))
  end

  def test_eight_processes_keep_exact_counts_and_atomic_snapshots_on_a_stable_lock
    profile.update { |state| state["xp"] = 0 }
    lock_inode = File.stat("#{@path}.lock").ino
    children = 8.times.map do
      fork do
        store = profile
        20.times do
          store.update do |state|
            state["xp"] += 1
            sleep(0.0001)
            state["generation_runs"] += 1
          end
        end
        exit!(0)
      rescue StandardError
        exit!(1)
      end
    end
    pending = children.dup
    until pending.empty?
      state = JSON.parse(File.binread(@path))
      assert_equal(state.fetch("xp"), state.fetch("generation_runs"))
      pending.delete_if do |pid|
        result = Process.waitpid2(pid, Process::WNOHANG)
        assert_predicate(result.last, :success?) if result
        result
      end
    end
    assert_equal(160, profile.read.fetch("xp"))
    assert_equal(160, profile.read.fetch("generation_runs"))
    assert_equal(lock_inode, File.stat("#{@path}.lock").ino)
  ensure
    children&.each do |pid|
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  private

  def profile
    Doparserb::Profile.new(interactive: true, env: {"DOPAPARSER_PROFILE" => @path})
  end

  def capture_debug
    original = Doparserb.method(:debug)
    errors = []
    Doparserb.define_singleton_method(:debug) { |error| errors << error }
    yield errors
  ensure
    Doparserb.define_singleton_method(:debug, original)
  end
end
