# frozen_string_literal: true

require "json"
require "fileutils"
require "tempfile"

module Doparserb
  class Profile
    MAX_BYTES = 4 * 1024 * 1024
    COUNTERS = %w[xp level best_score best_chain highest_tower tokens generation_runs play_runs flawless_count daily_streak].freeze
    InvalidProfile = Class.new(StandardError)

    attr_reader :path

    def initialize(interactive:, env: ENV)
      @state = defaults
      @enabled = !!interactive && env["DOPAPARSER_PROFILE"] != "off"
      return unless enabled?

      custom = env["DOPAPARSER_PROFILE"]
      if custom && !custom.empty?
        @path = File.expand_path(custom)
      else
        base = env["XDG_STATE_HOME"]
        base = File.join(env["HOME"] || Dir.home, ".local", "state") if !base || base.empty?
        @path = File.expand_path(File.join(base, "doparserb", "profile.json"))
      end
    rescue SystemCallError, IOError, ArgumentError => error
      Doparserb.debug(error)
      @enabled = false
    end

    def enabled?
      @enabled
    end

    def read
      return JSON.parse(JSON.generate(@state)) unless enabled?

      load_state.first
    end

    def update
      return yield(@state) unless enabled?

      lock = acquire_lock
      return yield(defaults) unless lock

      begin
        state, writable = load_state
        result = yield(state)
        save_state(state) if writable
        result
      ensure
        lock.close
      end
    end

    private

    def defaults
      {
        "v" => 1, "xp" => 0, "level" => 1, "best_score" => 0,
        "best_chain" => 0, "highest_tower" => 0, "tokens" => 0,
        "generation_runs" => 0, "play_runs" => 0, "flawless_count" => 0,
        "daily_streak" => 0, "last_day" => nil, "intro_day" => nil,
        "achievements" => [], "llamas" => [], "features" => [], "grammars" => {}
      }
    end

    def acquire_lock
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      lock = File.open("#{@path}.lock", File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600)
      raise InvalidProfile, "Profile lock is not a regular file" unless lock.stat.file?

      lock.chmod(0o600)
      raise IOError, "Could not lock profile" unless lock.flock(File::LOCK_EX)
      lock
    rescue SystemCallError, IOError, InvalidProfile => error
      lock&.close
      Doparserb.debug(error)
      nil
    end

    def load_state
      File.open(@path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        raise InvalidProfile, "Profile is not a regular file" unless file.stat.file?
        raise InvalidProfile, "Profile exceeds size limit" if file.stat.size > MAX_BYTES

        contents = file.read(MAX_BYTES + 1)
        raise InvalidProfile, "Profile exceeds size limit" if contents.bytesize > MAX_BYTES

        state = JSON.parse(contents)
        validate!(state)
        [defaults.merge(state), true]
      end
    rescue Errno::ENOENT
      [defaults, true]
    rescue SystemCallError, IOError, JSON::ParserError, InvalidProfile => error
      Doparserb.debug(error)
      [defaults, false]
    end

    def save_state(state)
      validate!(state)
      contents = JSON.generate(state)
      raise InvalidProfile, "Profile exceeds size limit" if contents.bytesize > MAX_BYTES

      Tempfile.create([".profile-", ".json"], File.dirname(@path)) do |file|
        file.write(contents)
        file.flush
        file.fsync
        file.close
        begin
          raise InvalidProfile, "Profile is not a regular file" unless File.lstat(@path).file?
        rescue Errno::ENOENT
          nil
        end

        File.rename(file.path, @path)
      end
    rescue SystemCallError, IOError, JSON::JSONError, InvalidProfile => error
      Doparserb.debug(error)
    end

    def validate!(state)
      raise InvalidProfile, "Unsupported profile schema" unless state.is_a?(Hash) && state["v"].eql?(1)

      COUNTERS.each do |key|
        next unless state.key?(key)

        value = state[key]
        minimum = key == "level" ? 1 : 0
        raise InvalidProfile, "Invalid profile #{key}" unless value.is_a?(Integer) && value >= minimum
      end
      %w[last_day intro_day].each do |key|
        value = state[key]
        raise InvalidProfile, "Invalid profile #{key}" unless value.nil? || value.is_a?(String)
      end
      %w[achievements features].each do |key|
        next unless state.key?(key)

        value = state[key]
        raise InvalidProfile, "Invalid profile #{key}" unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
      end
      if state.key?("llamas")
        llamas = state["llamas"]
        unless llamas.is_a?(Array) && llamas.uniq == llamas && llamas.all? { |id| id.is_a?(Integer) && (0..63).cover?(id) }
          raise InvalidProfile, "Invalid profile llamas"
        end
      end
      return unless state.key?("grammars")

      grammars = state["grammars"]
      unless grammars.is_a?(Hash) && grammars.all? { |path, stats| path.is_a?(String) && stats.is_a?(Hash) }
        raise InvalidProfile, "Invalid profile grammars"
      end
      grammars.each_value do |stats|
        %w[conflicts states build_streak].each do |key|
          next unless stats.key?(key)

          value = stats[key]
          raise InvalidProfile, "Invalid grammar #{key}" unless value.is_a?(Integer) && value >= 0
        end
        if stats.key?("duration")
          value = stats["duration"]
          unless (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value >= 0
            raise InvalidProfile, "Invalid grammar duration"
          end
        end
        if stats.key?("success") && ![true, false].include?(stats["success"])
          raise InvalidProfile, "Invalid grammar success"
        end
        if stats.key?("digest") && !(stats["digest"].is_a?(String) && /\A[0-9a-f]+\z/i.match?(stats["digest"]))
          raise InvalidProfile, "Invalid grammar digest"
        end
      end
    end
  end
end
