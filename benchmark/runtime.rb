# frozen_string_literal: true

require "digest"
require "fileutils"
require "io/console"
require "json"
require "open3"
require "pty"
require "rbconfig"
require "tmpdir"
require "timeout"

module RuntimeBenchmark
  ROOT = File.expand_path("..", __dir__)
  MODES = %w[plain compile_off runtime_off badge play_batch].freeze
  TARGETS = {"plain" => nil, "compile_off" => nil, "runtime_off" => 2, "badge" => 3, "play_batch" => 30}.freeze
  NUMBERS = %w[0 1 -7 12 123 1024 -65536 987654321 3.14159 -0.125 42.5 1000000].freeze
  MARKER = /DOPARSERB_BENCH seconds=(\d+\.\d+) result=(\d+) stdin=(\d) stdout=(\d) stderr=(\d) flush=(\w+)/
  ENVIRONMENT = {
    "DOPAPARSER" => nil, "DOPAPARSER_PROFILE" => "off", "DOPAPARSER_DEBUG" => nil,
    "DOPAPARSER_FD" => nil, "DOPAPARSER_FLUSH" => nil, "DOPAPARSER_SEED" => "1",
    "DOPAIRB_SOUND_LOG" => nil, "NO_COLOR" => "1", "TERM" => "xterm-256color", "MAKELEVEL" => nil
  }.freeze
  PLAY_OBSERVER = <<~'RUBY'
    require "doparserb"
    require "json"
    module BenchmarkEnding
      def finish
        result = super
        unless @benchmark_written
          @benchmark_written = true
          lost = @retired[:discarded] + @towers.values.sum { |tower| tower.to_h[:discarded] }
          summary = (@result || {}).merge(discarded_events: lost, folded_events: folded_events)
          File.write(ENV.fetch("DOPARSERB_BENCH_SUMMARY"), JSON.generate(summary))
        end
        result
      end
    end
    Doparserb::Play::Show.prepend(BenchmarkEnding)
    exit Doparserb::CLI.new(ARGV).run
  RUBY

  module_function

  def median(values)
    sorted = values.sort
    (sorted[(sorted.length - 1) / 2] + sorted[sorted.length / 2]) / 2.0
  end

  def corpus(path, minimum_bytes)
    repetitions = [(minimum_bytes - 2).fdiv(NUMBERS.join(",").bytesize + 1).ceil, 1].max
    group = NUMBERS.join(",") + ","
    File.open(path, "wb") do |file|
      file.write("[")
      (repetitions - 1).times { file.write(group) }
      file.write(NUMBERS.join(","))
      file.write("]\n")
    end
    numbers = repetitions * NUMBERS.length
    {bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest,
     numbers: numbers, expected_shifts: numbers * 2 + 2, pattern: NUMBERS,
     shape: "flat numeric array; repeated mixed magnitudes and decimals"}
  end

  def timed_grammar(source)
    anchor = "    yyparse();"
    raise "expected one yyparse call in upstream sample main" unless source.scan(anchor).length == 1
    raise "expected one stdio include" unless source.scan("#include <stdio.h>").length == 1
    source.sub("#include <stdio.h>", "#include <stdio.h>\n#include <time.h>\n#include <unistd.h>").sub(anchor, <<~'C'.lines.map { |line| "    #{line}" }.join.rstrip)
      struct timespec before, after;
      int result;
      const char *flush;
      if (clock_gettime(CLOCK_MONOTONIC, &before)) return 98;
      result = yyparse();
      if (clock_gettime(CLOCK_MONOTONIC, &after)) return 98;
      flush = getenv("DOPAPARSER_FLUSH");
      fprintf(stderr, "DOPARSERB_BENCH seconds=%.9f result=%d stdin=%d stdout=%d stderr=%d flush=%s\n",
              (double)(after.tv_sec - before.tv_sec) + (after.tv_nsec - before.tv_nsec) / 1e9,
              result, isatty(STDIN_FILENO), isatty(STDOUT_FILENO), isatty(STDERR_FILENO), flush ? flush : "unset");
      if (result) return result;
    C
  end

  def marker(stderr)
    matches = stderr.scan(MARKER)
    raise "expected one parser timing marker, found #{matches.length}" unless matches.length == 1
    seconds, result, input_tty, output_tty, error_tty, flush = matches.first
    seconds = Float(seconds)
    raise "invalid parser duration" unless seconds.finite? && seconds.positive?
    raise "yyparse rejected the benchmark corpus (#{result})" unless result == "0"
    {parse_seconds: seconds, parse_result: Integer(result), stdin_tty: input_tty == "1",
     stdout_tty: output_tty == "1", stderr_tty: error_tty == "1", flush: flush}
  end

  def self_check
    raise "odd median failed" unless median([9, 1, 3]) == 3
    raise "even median failed" unless median([4, 1, 3, 2]) == 2.5
    source = "#include <stdio.h>\nint main() {\n    yyparse();\n}\n"
    instrumented = timed_grammar(source)
    raise "timing instrumentation failed" unless instrumented.scan("result = yyparse();").length == 1 && instrumented.include?("if (result) return result;")
    begin
      timed_grammar(source + "    yyparse();")
      raise "duplicate timing anchor was accepted"
    rescue RuntimeError => error
      raise unless error.message.start_with?("expected one yyparse")
    end
    valid = "DOPARSERB_BENCH seconds=0.125000000 result=0 stdin=0 stdout=0 stderr=1 flush=batch\n"
    raise "marker parsing failed" unless marker(valid) == {parse_seconds: 0.125, parse_result: 0, stdin_tty: false, stdout_tty: false, stderr_tty: true, flush: "batch"}
    ["", valid + valid, valid.sub("result=0", "result=1"), valid.sub("0.125000000", "0.000000000")].each do |invalid|
      accepted = begin
        marker(invalid)
        true
      rescue RuntimeError
        false
      end
      raise "invalid timing marker was accepted" if accepted
    end
    Dir.mktmpdir("doparserb-corpus-check") do |directory|
      path = File.join(directory, "input.json")
      info = corpus(path, 1000)
      parsed = JSON.parse(File.read(path))
      raise "invalid corpus size" unless (1000..1100).cover?(info[:bytes])
      raise "invalid corpus count" unless parsed.length == info[:numbers] && parsed.all? { |value| value.is_a?(Numeric) }
      raise "corpus is not deterministic" unless info == corpus(path, 1000)
    end
  end

  def capture!(command, directory:, env: {})
    stdout, stderr, status = Open3.capture3(ENVIRONMENT.merge(env), *command, chdir: directory)
    raise "command failed: #{command.inspect}\n#{stdout}#{stderr}" unless status.success?
    [stdout, stderr]
  end

  def build(directory, compiler)
    lrama = Gem::Specification.find_by_name("lrama").full_gem_path
    grammar = File.join(directory, "grammar.y")
    File.write(grammar, timed_grammar(File.read(File.join(lrama, "sample/json.y"))))
    generation = {}
    ["plain", "instrumented"].each do |mode|
      command = if mode == "plain"
                  [RbConfig.ruby, File.join(lrama, "exe/lrama")]
                else
                  [RbConfig.ruby, "-I#{ROOT}/lib", File.join(ROOT, "exe/doparserb"), "--dopa=off"]
                end
      _, diagnostics = capture!([*command, "grammar.y", "-o", "#{mode}.c"], directory: directory)
      generation[mode] = diagnostics
    end
    flags = %w[-O2 -std=c99 -Wall -Wextra -D_POSIX_C_SOURCE=200809L]
    compilations = {}
    %w[plain compile_off instrumented].each do |name|
      source = name == "plain" ? "plain.c" : "instrumented.c"
      command = [compiler, *flags, *(name == "compile_off" ? ["-DDOPA_RT_DISABLE"] : []), source, "-o", name]
      _, diagnostics = capture!(command, directory: directory)
      compilations[name] = diagnostics
    end
    {compiler: capture!([compiler, "--version"], directory: directory).first.lines.first.strip,
     flags: flags, generation_diagnostics: generation, compilation_diagnostics: compilations,
     source_sha256: %w[plain instrumented].to_h { |name| [name, Digest::SHA256.file(File.join(directory, "#{name}.c")).hexdigest] }}
  end

  def run(mode, directory)
    executable = File.join(directory, %w[plain compile_off].include?(mode) ? mode : "instrumented")
    command = [executable]
    environment = ENVIRONMENT.dup
    summary_path = File.join(directory, "play-summary.json")
    debug_path = File.join(directory, "presentation-errors.log")
    File.unlink(debug_path) if File.exist?(debug_path)
    environment["DOPAPARSER_DEBUG"] = debug_path
    if mode == "play_batch"
      command = [RbConfig.ruby, "-I#{ROOT}/lib", "-e", PLAY_OBSERVER, "play", "--replay=highlight",
                 "--dopa-set", "sound=off,flash=off,intro=off,duration=0.1", "--", executable]
      environment["DOPARSERB_BENCH_SUMMARY"] = summary_path
      File.unlink(summary_path) if File.exist?(summary_path)
    end
    terminal = %w[badge play_batch].include?(mode)
    master, slave = PTY.open if terminal
    slave.winsize = [24, 120] if slave
    stdout_path, stderr_path = %w[stdout stderr].map { |name| File.join(directory, "#{name}.txt") }
    output = File.open(stdout_path, "wb")
    errors = slave || File.open(stderr_path, "wb")
    input = File.open(File.join(directory, "input.json"), "rb")
    raw = +"".b
    reader = Thread.new do
      loop { raw << master.readpartial(65_536) }
    rescue EOFError, Errno::EIO, IOError
      nil
    end if master
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pid = Process.spawn(environment, *command, in: input, out: output, err: errors, chdir: directory, pgroup: true)
    status = Timeout.timeout(120) { Process.waitpid2(pid).last }
    whole = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    input.close
    output.close
    errors.close
    raise "terminal output did not close" if reader && !reader.join(5)
    stderr = terminal ? raw.force_encoding(Encoding::UTF_8) : File.read(stderr_path)
    stdout = File.read(stdout_path)
    raise "#{mode} presentation error: #{File.read(debug_path)}" if File.size?(debug_path)
    raise "#{mode} exited #{status.inspect}\n#{stderr}" unless status.success?
    raise "#{mode} changed stdout: #{stdout.inspect}" unless stdout == "JSON parsed successfully!\n"
    sample = marker(stderr)
    raise "#{mode} has wrong descriptor assignment" unless !sample[:stdin_tty] && !sample[:stdout_tty] && sample[:stderr_tty] == terminal
    raise "#{mode} has wrong flush mode" unless sample[:flush] == (mode == "play_batch" ? "batch" : "unset")
    if mode == "badge"
      raise "standalone badge was not exercised" unless stderr.include?("STAGE CLEAR") && stderr.include?("TOKENS")
      sample[:tokens] = Integer(stderr[/\b(\d+) TOKENS\b/, 1])
    elsif mode == "play_batch"
      unless stderr.include?("\e[?25l") && stderr.match?(/STACK TOWER|LLAMA DROP!|STAGE CLEAR!|CHAIN/)
        details = File.exist?(summary_path) ? File.read(summary_path) : "missing summary"
        raise "play presentation was not exercised: #{stderr.inspect}; #{details}"
      end
      raise "play did not record a summary" unless File.exist?(summary_path)
      sample[:events] = JSON.parse(File.read(summary_path)).slice("tokens", "reductions", "acceptances", "approximate", "discarded_events", "folded_events", "success")
    else
      raise "#{mode} emitted extra diagnostics" unless stderr.sub(MARKER, "").strip.empty?
    end
    sample.merge(whole_process_seconds: whole, status: status.exitstatus, stdout_sha256: Digest::SHA256.hexdigest(stdout), stderr_bytes: stderr.bytesize)
  ensure
    if pid && !status
      Process.kill("KILL", -pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    [input, output, errors, slave, master].compact.uniq.each { |io| io.close unless io.closed? }
    reader&.join(1)
  end

  def main
    self_check
    if ARGV == ["--self-test"]
      puts "Runtime benchmark self-checks passed."
      return
    end
    raise ArgumentError, "only --self-test is accepted" unless ARGV.empty?
    runs = Integer(ENV.fetch("RUNS", "10"))
    bytes = Integer(ENV.fetch("BYTES", (10 * 1024 * 1024).to_s))
    warmups = Integer(ENV.fetch("WARMUPS", "1"))
    raise ArgumentError, "RUNS/BYTES must be positive and WARMUPS nonnegative" unless runs.positive? && bytes.positive? && warmups >= 0
    compiler = ENV.fetch("CC", "clang")
    Dir.mktmpdir("doparserb-runtime-bench") do |directory|
      input = corpus(File.join(directory, "input.json"), bytes)
      builds = build(directory, compiler)
      samples = MODES.to_h { |mode| [mode, []] }
      orders = []
      warmups.times { MODES.each { |mode| run(mode, directory) } }
      runs.times do |round|
        order = MODES.rotate(round)
        orders << order
        order.each { |mode| samples[mode] << run(mode, directory) }
      end
      baseline = median(samples["plain"].map { |sample| sample[:parse_seconds] })
      raise "badge token count disagrees with the corpus" unless samples["badge"].all? { |sample| sample[:tokens] == input[:expected_shifts] }
      results = samples.to_h do |mode, values|
        parse = median(values.map { |sample| sample[:parse_seconds] })
        overhead = (parse / baseline - 1) * 100
        [mode, {parse_median_ms: parse * 1000, whole_process_median_ms: median(values.map { |sample| sample[:whole_process_seconds] }) * 1000,
                overhead_percent: overhead, target_overhead_percent: TARGETS[mode],
                meets_target: TARGETS[mode] ? overhead <= TARGETS[mode] : nil, samples: values}]
      end
      revision = ->(name) { Gem::Specification.find_by_name(name).full_gem_path.split("/").last }
      puts JSON.pretty_generate(measured_at: Time.now.utc.iso8601, ruby: RUBY_DESCRIPTION, host: RbConfig::CONFIG["host"],
                                lrama: revision.call("lrama"), dopairb: revision.call("dopairb"),
                                runs: runs, warmups_per_mode: warmups, order: orders, corpus: input,
                                settings: {sound: "off", profile: "off", flash: "off", replay: "highlight", duration: 0.1},
                                measurement: "C CLOCK_MONOTONIC immediately around yyparse; whole process includes startup and finishing replay",
                                build: builds, results: results)
    end
  end
end

require "time"
RuntimeBenchmark.main if $PROGRAM_NAME == __FILE__
