# frozen_string_literal: true

require_relative "doparserb/version"

module Doparserb
  class Error < StandardError; end

  autoload :CLI, "doparserb/cli"
  autoload :Command, "doparserb/lrama_adapter"
  autoload :Event, "doparserb/event"
  autoload :EventBus, "doparserb/event_bus"
  autoload :Config, "doparserb/config"
  autoload :Engine, "doparserb/engine"
  autoload :TTYLock, "doparserb/tty_lock"
  autoload :Runtime, "doparserb/runtime"
  autoload :Game, "doparserb/game"
  autoload :Profile, "doparserb/profile"
  autoload :Career, "doparserb/career"
  autoload :Achievements, "doparserb/achievements"
  autoload :Ranch, "doparserb/ranch"
  autoload :SoundBank, "doparserb/sound_bank"
  autoload :Watch, "doparserb/watch"

  module Gen
    autoload :Collector, "doparserb/gen/collector"
    autoload :Show, "doparserb/gen/show"
    autoload :Scenes, "doparserb/gen/scenes/catalogue"
  end

  module Play
    autoload :Launcher, "doparserb/play/launcher"
    autoload :Protocol, "doparserb/play/protocol"
    autoload :Tower, "doparserb/play/tower"
    autoload :Show, "doparserb/play/show"
    autoload :Scenes, "doparserb/play/scenes/catalogue"
  end

  def self.debug(error)
    path = ENV["DOPAPARSER_DEBUG"]
    File.open(path, "a") { |file| file.puts(error.full_message) } if path && !path.empty?
  rescue StandardError
    nil
  end
end
