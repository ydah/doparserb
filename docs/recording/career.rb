# frozen_string_literal: true

require "json"
require "tmpdir"
require "doparserb"
require_relative "../../test/support/pty_driver"

Dir.mktmpdir("doparserb-career-recording") do |directory|
  profile = File.join(directory, "profile.json")
  Doparserb::Profile.new(interactive: true, env: {"DOPAPARSER_PROFILE" => profile}).update do |state|
    state["xp"] = 1024
    state["level"] = 3
    state["llamas"] = [0, 5, 17, 42, 63]
  end
  original = File.binread(profile)
  scenarios = {
    "demo" => ["demo", "--dopa-set", "duration=0.15,flash=off"],
    "ranch" => ["ranch", "--dopa-set", "duration=0.5,flash=off"],
    "ranch-tour" => ["ranch", "tour", "--dopa-set", "duration=0.5,flash=off"]
  }
  scenarios.each do |name, arguments|
    driver = PTYDriver.doparserb(*arguments, env: {"DOPAPARSER_PROFILE" => profile})
    raise "#{name} failed" unless driver.wait_exit(timeout: 30).zero?
    raise "unknown terminal sequences: #{driver.unknown}" unless driver.unknown.empty?
    raise "career presentation changed the profile" unless File.binread(profile) == original
    path = File.join(__dir__, "#{name}.cast")
    File.open(path, "w") do |file|
      file.puts(JSON.generate(version: 2, width: 80, height: 24, timestamp: Time.now.to_i,
                              title: "doparserb #{name}", env: {TERM: "xterm-256color"}))
      driver.records.each do |at, type, bytes|
        file.puts(JSON.generate([at, type, bytes.dup.force_encoding(Encoding::UTF_8).scrub]))
      end
    end
    puts path
  ensure
    driver&.close
  end
end
