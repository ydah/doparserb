# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Test::Unit::TestCase
  def config(**options)
    assert_const_defined(Doparserb, :Config)
    Doparserb::Config.new(env: {}, **options)
  end

  def test_presentation_defaults
    settings = config
    assert_equal(:max, settings.intensity)
    assert_equal(true, settings.motion)
    assert_equal(:soft, settings.flash)
    assert_equal(:sfx, settings.sound)
    assert_equal(1.0, settings.duration)
    assert_equal(:auto, settings.color)
    assert_equal(:badge, settings.trail)
    assert_equal(:on, settings.intro)
    assert_equal(:auto, settings.quick)
    assert_equal(:highlight, settings.replay)
    assert_equal(30, settings.speed)
  end

  def test_cli_overrides_environment_and_presets
    settings = config(mode: "calm", settings: ["sound=bell,duration=0.5", "intensity=max"],
                      env: {"DOPAPARSER" => "intensity=normal,sound=off,color=16"})
    assert_equal(:max, settings.intensity)
    assert_equal(:off, settings.flash)
    assert_equal(:bell, settings.sound)
    assert_equal(0.5, settings.duration)
    assert_equal(:"16", settings.color)
    assert_true(config(env: {"DOPAPARSER" => "off"}).off?)
    assert_false(config(mode: "party", env: {"DOPAPARSER" => "off"}).off?)
  end

  def test_quick_mode_and_party_override_make
    assert_true(config(env: {"MAKELEVEL" => "0"}).quick?)
    assert_false(config(mode: "party", env: {"MAKELEVEL" => "1"}).quick?)
    assert_true(config(settings: ["quick=on"]).quick?)
    assert_false(config(settings: ["quick=off"], env: {"MAKELEVEL" => "1"}).quick?)
    assert_false(config(settings: ["quick=on"]).intro?)
  end

  def test_all_settings_accept_their_documented_values
    settings = config(settings: ["intensity=low,motion=off,flash=full,sound=off,duration=5,color=256,trail=none,intro=daily,quick=off,replay=full,speed=2000"])
    assert_false(settings.motion)
    assert_equal(:daily, settings.intro)
    assert_equal(2000, settings.speed)
    assert_equal(:none, config(settings: ["color=truecolor"], env: {"NO_COLOR" => "1"}).color)
  end

  def test_invalid_settings_and_artifact_settings_are_rejected
    %w[duration=0 duration=NaN speed=2001 speed=1.5 flash=on motion=maybe unknown=1 runtime=off meta=sidecar].each do |setting|
      assert_raise(Doparserb::Error, setting) { config(settings: [setting]) }
    end
  end

  def test_invalid_environment_settings_do_not_abort_or_override_valid_entries
    settings = config(env: {"DOPAPARSER" => "runtime=off,flash=off,duration=bad,meta=sidecar,intensity=low"})
    assert_equal(:off, settings.flash)
    assert_equal(:low, settings.intensity)
    assert_equal(1.0, settings.duration)
    assert_equal(Doparserb::Config::DEFAULTS, config(env: {"DOPAPARSER" => "runtime=off,meta=sidecar"}).to_h)
  end
end
