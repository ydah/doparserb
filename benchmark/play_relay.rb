# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/doparserb"
require_relative "../test/support/pty_driver"

samples = Integer(ENV.fetch("SAMPLES", "100"))
raise ArgumentError, "SAMPLES must be positive" unless samples.positive?
sidecars = Integer(ENV.fetch("SIDECARS", "0"))
raise ArgumentError, "SIDECARS must be in 0..128" unless (0..128).cover?(sidecars)
directory = Dir.mktmpdir("doparserb-relay-bench")
metadata = nil
if sidecars.positive?
  common = {grammar: "benchmark.y", generator: "benchmark", states: 3, rules: []}
  unrelated = Doparserb::Runtime::Meta.new(common.merge(symbols: Array.new(7500) do |index|
    {id: index, name: "unused symbol " * 6, term: true}
  end))
  (sidecars - 1).times { |index| File.write(File.join(directory, "candidate-#{index}.dopa.json"), unrelated.json) }
  metadata = Doparserb::Runtime::Meta.new(common.merge(
    symbols: [{id: 3, name: "NUMBER", term: true}, {id: 4, name: "expression", term: false}],
    rules: [{id: 2, lhs: 4, rhs: [3, 3], text: "expression: NUMBER NUMBER"}]
  ))
  File.write(File.join(directory, "zzz-target.dopa.json"), metadata.json)
end
program = <<~'RUBY'
  require "socket"
  require "json"
  socket = Socket.for_fd(Integer(ENV.fetch("DOPAPARSER_FD")))
  STDOUT.sync = true
  metadata = ARGV[1]
  parser = metadata ? JSON.parse(metadata).fetch("digest")[0, 8] : "0123abcd"
  prefix = "F #{parser} #{Process.pid} 1\n"
  socket.send(prefix + "M #{parser} 0 #{metadata.bytesize}\n" + metadata, 0) if metadata
  socket.send(prefix + "B\nS 3 1 1\n", 0)
  packet = prefix + "T 3 1 1\nS 3 2 2\nR 2 2 1 2\n" * 40
  Integer(ARGV.fetch(0)).times do |index|
    8.times do
      begin
        socket.send(packet, Socket::MSG_DONTWAIT)
      rescue IO::WaitWritable, Errno::ENOBUFS
      end
    end
    puts "LATENCY #{index} #{Process.clock_gettime(Process::CLOCK_MONOTONIC)}"
    sleep 0.01
  end
  socket.send(prefix + "A\n", 0)
RUBY

arguments = [RbConfig.ruby, "-e", program, samples.to_s]
arguments << metadata.stub_json if metadata
driver = PTYDriver.doparserb("play", "--dopa-set", "duration=0.1", "--", *arguments, directory: directory)
origin = Process.clock_gettime(Process::CLOCK_MONOTONIC) - driver.elapsed
raise "relay child failed: #{driver.all_text}" unless driver.wait_exit(timeout: 30).zero?
buffer = +""
latencies = []
driver.records.each do |at, _, bytes|
  buffer << bytes
  while (line = buffer.slice!(/.*?\n/m))
    match = line.match(/LATENCY (\d+) (\d+\.\d+)/)
    latencies << origin + at - Float(match[2]) if match
  end
end
raise "lost child output: #{latencies.length}/#{samples}" unless latencies.length == samples
raise "presentation was not exercised" unless driver.raw_output.include?("STACK TOWER")
raise "sidecar names were not resolved" if metadata && !driver.raw_output.include?("NUMBER")
ordered = latencies.sort
puts JSON.pretty_generate(samples: samples, sidecars: sidecars, median_ms: ordered[samples / 2] * 1000,
                          p95_ms: ordered[(samples * 0.95).ceil - 1] * 1000,
                          maximum_ms: ordered.last * 1000, target_ms: 5,
                          meets_target: ordered.last <= 0.005, samples_seconds: latencies)
driver.close
FileUtils.remove_entry(directory)
