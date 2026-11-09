# frozen_string_literal: true

module Doparserb
  class Config
    DEFAULTS = {
      intensity: :max, motion: true, flash: :soft, sound: :sfx, duration: 1.0,
      color: :auto, trail: :badge, intro: :on, quick: :auto, replay: :highlight, speed: 30
    }.freeze
    VALUES = {
      intensity: %w[off low normal max], motion: %w[on off], flash: %w[off soft full],
      sound: %w[off bell sfx], color: %w[auto truecolor 256 16 none], trail: %w[none badge],
      intro: %w[on off daily], quick: %w[auto on off], replay: %w[highlight full off]
    }.freeze
    PRESETS = {
      "off" => "intensity=off", "calm" => "intensity=low,flash=off,duration=0.5,sound=off",
      "party" => "intensity=max,flash=full,quick=off"
    }.freeze

    attr_reader(*DEFAULTS.keys)

    def initialize(mode: nil, settings: [], env: ENV)
      @env = env
      DEFAULTS.each { |name, value| instance_variable_set("@#{name}", value) }
      environment = env["DOPAPARSER"].to_s
      environment = "intensity=off" if environment == "off"
      environment.split(",", -1).each do |setting|
        apply(setting)
      rescue Error => error
        Doparserb.debug(error)
      end
      apply(PRESETS.fetch(mode)) if mode
      settings.each { |setting| apply(setting) }
      @color = :none if env.key?("NO_COLOR")
    end

    def off? = intensity == :off
    def quick? = quick == :on || (quick == :auto && @env.key?("MAKELEVEL"))
    def intro? = intro != :off && !quick?
    def to_h = DEFAULTS.keys.to_h { |name| [name, public_send(name)] }

    private

    def apply(string)
      return if string.empty?
      string.split(",", -1).each do |pair|
        name, value = pair.split("=", 2)
        name = name.to_s.strip.to_sym
        value = value.to_s.strip
        raise Error, "unknown presentation setting: #{name}" unless DEFAULTS.key?(name)
        parsed = case name
                 when :duration
                   number = Float(value, exception: false)
                   raise Error, "duration must be in 0.1..5" unless number && (0.1..5).cover?(number)
                   number
                 when :speed
                   number = Integer(value, 10, exception: false)
                   raise Error, "speed must be an integer in 1..2000" unless number && (1..2000).cover?(number)
                   number
                 else
                   raise Error, "#{name} must be #{VALUES.fetch(name).join('/')}" unless VALUES.fetch(name).include?(value)
                   name == :motion ? value == "on" : value.to_sym
                 end
        instance_variable_set("@#{name}", parsed)
      end
    end
  end
end
