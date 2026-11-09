# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../test/support/pty_driver"

repetitions = Integer(ENV.fetch("RUNS", "7"))
raise ArgumentError, "RUNS must be positive" unless repetitions.positive?
samples = {plain: [], meter: []}
Dir.mktmpdir("doparserb-meter-bench") do |directory|
  tokens = 2048.times.map { |index| "T#{index}" }
  File.write(File.join(directory, "grammar.y"), "%token #{tokens.join(' ')}\n%%\nstart: #{tokens.join(' | ')};\n%%\n")
  repetitions.times do
    samples.each_key do |mode|
      settings = "intro=off,trail=none,duration=0.1,motion=#{mode == :plain ? 'off' : 'on'}"
      driver = PTYDriver.doparserb("--dopa-set", settings, "--dopa-debug-events", "grammar.y", "-o", "parser.c",
                                  directory: directory)
      raise "generation failed" unless driver.wait_exit(timeout: 30).zero?
      stats = JSON.parse(driver.raw_output.scan(/\{[^\r\n]*\}/).last || "null")
      raise "missing generation statistics" unless stats && stats.fetch("states") > 2048
      raise "live meter was not exercised" if mode == :meter && !driver.raw_output.include?("CHARGING")
      samples.fetch(mode) << stats.fetch("duration")
      driver.close
    ensure
      driver&.close
    end
  end
end
medians = samples.transform_values do |values|
  ordered = values.sort
  (ordered[(ordered.length - 1) / 2] + ordered[ordered.length / 2]) / 2.0
end
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, repetitions: repetitions, medians_seconds: medians,
                          overhead_percent: (medians.fetch(:meter) / medians.fetch(:plain) - 1) * 100,
                          samples_seconds: samples)
