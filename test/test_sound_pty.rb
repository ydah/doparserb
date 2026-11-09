# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_driver"

class SoundPTYTest < Test::Unit::TestCase
  include CommandTest

  def setup
    @directory = Dir.mktmpdir("doparserb-sound-pty")
    @cache = File.join(@directory, "cache")
    @log = File.join(@directory, "sound.log")
    @drivers = []
  end

  def teardown
    @drivers.each(&:close)
    FileUtils.remove_entry(@directory)
  end

  def test_generation_synthesizes_cached_wavs_without_an_audio_device
    driver = terminal("--dopa-set", "intro=off,duration=0.2", File.join(FIXTURES, "prec.y"), "-o", File.join(@directory, "parser.c"))
    assert_equal(0, driver.wait_exit)
    assert_path_exist(@log)
    paths = File.readlines(@log).map { |line| line.split.last }
    assert_not_empty(paths)
    assert(paths.any? { |path| File.basename(path).include?("doparserb-") })
    paths.each { |path| assert_equal("RIFF", File.binread(path, 4)) }
    assert_empty(driver.unknown)
  end

  def test_silent_generation_creates_no_audio_cache_or_log
    driver = terminal("--dopa-set", "sound=off,intro=off,duration=0.1", File.join(FIXTURES, "prec.y"), "-o", File.join(@directory, "parser.c"))
    assert_equal(0, driver.wait_exit)
    assert_false(File.exist?(@cache))
    assert_false(File.exist?(@log))
    assert_not_include(driver.raw_output, "\a")
  end

  def test_full_playback_sounds_shifts_reductions_and_chains
    program = <<~'RUBY'
      require "socket"
      socket = Socket.for_fd(Integer(ENV.fetch("DOPAPARSER_FD")))
      socket.send("F 0123abcd #{Process.pid} 1\nB\nS 3 1 1\nR 2 1 1 1\nR 2 1 1 1\nR 2 1 1 1\nA\n", 0)
      sleep 0.7
    RUBY
    driver = terminal("play", "--replay=full", "--speed=10", "--", RbConfig.ruby, "-e", program)
    assert_equal(0, driver.wait_exit)
    assert_path_exist(@log)
    paths = File.read(@log)
    %w[dopa_shift dopa_reduce dopa_chain].each { |name| assert_include(paths, name) }
    assert_include(driver.all_text, "STAGE CLEAR")
    assert_empty(driver.unknown)
  end

  private

  def terminal(*arguments)
    wrapper = 'require "doparserb"; Doparserb::Engine; Dopairb::Sound.instance_variable_set(:@dir, ARGV.shift); load ARGV.shift'
    driver = PTYDriver.new([RbConfig.ruby, "-I#{ROOT}/lib", "-e", wrapper, @cache, File.join(ROOT, "exe/doparserb"), *arguments],
                           env: {"DOPAPARSER" => "sound=sfx,flash=off", "DOPAPARSER_SEED" => "2", "DOPAIRB_SOUND_LOG" => @log}, directory: @directory)
    @drivers << driver
    driver
  end
end
