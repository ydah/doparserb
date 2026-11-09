# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)

def median(values)
  sorted = values.sort
  (sorted[(sorted.length - 1) / 2] + sorted[sorted.length / 2]) / 2.0
end

if ARGV.first == "--worker"
  _, mode, grammar, output, runs, batch = ARGV
  require(mode == "plain" ? "lrama" : File.join(ROOT, "lib/doparserb"))
  require File.join(ROOT, "lib/doparserb/event_bus") unless mode == "plain"
  require File.join(ROOT, "lib/doparserb/gen/collector") unless mode == "plain"
  arguments = [grammar, "-o", output]
  generate = lambda do
    if mode == "plain"
      Lrama::Command.new(arguments.dup).run
    else
      bus = Doparserb::EventBus.new
      Doparserb::Command.new(arguments.dup, events: bus, runtime: "off").run
      collector = Doparserb::Gen::Collector.new
      collector.collect(bus)
      raise "collector did not count states" unless collector.to_h.fetch(:states, 0).positive?
    end
  end
  3.times { generate.call }
  measurements = Integer(runs).times.map do
    GC.start
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Integer(batch).times { generate.call }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / Integer(batch)
  end
  raise "generator did not write C output" unless File.size?(output)
  puts JSON.generate(measurements)
  exit
end

runs = Integer(ENV.fetch("RUNS", "15"))
batch = Integer(ENV.fetch("BATCH", "10"))
raise ArgumentError, "RUNS and BATCH must be positive" unless runs.positive? && batch.positive?
raise "median self-check failed" unless median([4, 1, 3, 2]) == 2.5 && median([9, 1, 3]) == 3

Dir.mktmpdir("doparserb-generation-bench") do |directory|
  large = File.join(directory, "large.y")
  tokens = 512.times.map { |index| "T#{index}" }
  File.write(large, "%token #{tokens.join(' ')}\n%%\nstart: #{tokens.join(' | ')};\n%%\n")
  grammars = {
    "parse" => File.join(Gem::Specification.find_by_name("lrama").full_gem_path, "sample/parse.y"),
    "large" => large
  }
  results = grammars.to_h do |name, grammar|
    diagnostics = {}
    samples = %w[plain observed].to_h do |mode|
      command = [RbConfig.ruby, "-I#{ROOT}/lib", __FILE__, "--worker", mode, grammar,
                 File.join(directory, "parser.c"), runs.to_s, batch.to_s]
      stdout, stderr, status = Open3.capture3({"DOPAPARSER_PROFILE" => "off"}, *command)
      raise "#{mode} benchmark failed: #{stderr}" unless status.success?
      diagnostics[mode] = stderr
      [mode, JSON.parse(stdout)]
    end
    raise "collector changed diagnostics" unless diagnostics.fetch("plain") == diagnostics.fetch("observed")
    plain = median(samples.fetch("plain"))
    observed = median(samples.fetch("observed"))
    [name, {plain_ms: plain * 1000, observed_ms: observed * 1000,
            overhead_percent: (observed / plain - 1) * 100, samples_seconds: samples}]
  end
  puts JSON.pretty_generate({ruby: RUBY_DESCRIPTION, runs: runs, batch: batch,
                             includes: "generation and collection; excludes startup and drawing", results: results})
end
