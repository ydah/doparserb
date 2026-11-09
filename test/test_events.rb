# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "lrama"

class EventsTest < Test::Unit::TestCase
  include CommandTest

  def test_debug_summary_is_written_after_generation
    with_grammar("prec") do |directory, path|
      result = run_command(:doparserb, ["--dopa-debug-events", path, "-o", "parser.c"], directory: directory)
      assert_equal(0, result[:status])
      assert_match(/\A\{/, result[:stderr].lines.last.to_s)
      stats = JSON.parse(result[:stderr].lines.last)
      assert_true(stats["success"])
      assert_equal(File.size(File.join(directory, "parser.c")), stats["output_bytes"])
      assert_equal(File.foreach(File.join(directory, "parser.c")).count, stats["output_lines"])
      assert_operator(stats["tokens"], :>, 0)
      assert_equal(stats["tokens"], stats["token_types"].values.sum)
      assert_operator(stats["duration"], :>=, 0)
      assert_include(stats["phases"], "compute_lr0_states")
      assert_include(stats["phases"], "compute_look_ahead_sets")
    end
  end

  def test_summary_matches_upstream_for_each_successful_fixture
    %w[conflicts expect_ok prec inline param ielr warn].each do |name|
      with_grammar(name) do |directory, path|
        command = Lrama::Command.new([path, "-o", File.join(directory, "parser.c")])
        grammar = command.send(:build_grammar, command.send(:read_input))
        states, = command.send(:compute_status, grammar)
        result = run_command(:doparserb, ["--dopa-debug-events", path, "-o", "parser.c"], directory: directory)
        assert_match(/\A\{/, result[:stderr].lines.last.to_s, name)
        stats = JSON.parse(result[:stderr].lines.last)
        assert_equal(grammar.rules.length, stats["rules"], name)
        assert_equal(grammar.terms.length, stats["terms"], name)
        assert_equal(grammar.nterms.length, stats["nterms"], name)
        assert_equal(states.states.length, stats["states"], name)
        assert_equal(states.sr_conflicts_count, stats["sr_conflicts"], name)
        assert_equal(states.rr_conflicts_count, stats["rr_conflicts"], name)
        assert_equal(states.states.sum { |state| state.resolved_conflicts.length }, stats["resolved_conflicts"], name)
        assert_equal(grammar.parameterized_resolver.created_lhs_list.length, stats["parameterized"], name)
      end
    end
  end

  def test_inline_expansions_and_ielr_splits_are_observed
    {"inline" => ["inline_expansions", 3], "ielr" => ["split_states", 1]}.each do |name, (key, count)|
      with_grammar(name) do |directory, path|
        result = run_command(:doparserb, ["--dopa-debug-events", path], directory: directory)
        assert_match(/\A\{/, result[:stderr].lines.last.to_s)
        assert_equal(count, JSON.parse(result[:stderr].lines.last)[key])
      end
    end
  end

  def test_failure_kinds_and_diagnostics_preserve_upstream_behavior
    {"broken" => "grammar_break", "expect_ng" => "expect_mismatch", "validation" => "validation_break"}.each do |name, kind|
      with_grammar(name) do |directory, path|
        baseline = run_command(:lrama, [path], directory: directory)
        result = run_command(:doparserb, ["--dopa-debug-events", path], directory: directory)
        lines = result[:stderr].lines
        assert_match(/\A\{/, lines.last.to_s, name)
        stats = JSON.parse(lines.pop)
        assert_equal(baseline[:status], result[:status], name)
        assert_equal(baseline[:stdout], result[:stdout], name)
        assert_equal(baseline[:stderr], lines.join, name)
        assert_false(stats["success"], name)
        assert_equal(kind, stats.fetch("failure").fetch("kind"), name)
        assert_equal(1, stats.fetch("failure").fetch("status"), name)
      end
    end
  end

  def test_warning_counts_and_extra_outputs
    with_grammar("warn") do |directory, path|
      args = ["-W", "-d", "-r", "states", "--diagram=parser.html", "-o", "parser.c", path]
      baseline = run_command(:lrama, args, directory: directory)
      result = run_command(:doparserb, ["--dopa-debug-events", *args], directory: directory)
      lines = result[:stderr].lines
      assert_match(/\A\{/, lines.last.to_s)
      stats = JSON.parse(lines.pop)
      assert_equal(baseline[:stderr], lines.join)
      assert_equal(lines.count { |line| line.start_with?("warning:") }, stats["warnings"])
      assert_operator(stats["warnings"], :>, 0)
      assert_equal(%w[diagram header report], stats["extras"].sort)
      assert_true(stats["warnings_complete"])
    end
  end

  def test_debug_events_can_force_collection_when_effects_are_off
    with_grammar("prec") do |directory, path|
      result = run_command(:doparserb, ["--dopa=off", "--dopa-runtime=off", "--dopa-debug-events", path],
                           directory: directory, env: {"DOPAPARSER" => "off"})
      assert_match(/\A\{/, result[:stderr].lines.last.to_s)
      assert_operator(JSON.parse(result[:stderr].lines.last)["states"], :>, 0)
    end
  end

  def test_queue_delivers_concurrent_events_and_closes_consumer
    assert_const_defined(Doparserb, :EventBus)
    bus = Doparserb::EventBus.new
    events = []
    consumer = Thread.new { bus.each { |event| events << event } }
    producers = 4.times.map do |producer|
      Thread.new { 50.times { |number| bus.emit(:states, strength: :small, count: producer * 50 + number) } }
    end
    producers.each(&:join)
    bus.close
    assert(consumer.join(2), "closed event bus must wake its consumer")
    assert_equal((0...200).to_a, events.map { |event| event.info[:count] }.sort)
    assert_true(bus.closed?)
    assert_equal([], bus.drain)
  ensure
    consumer&.kill if consumer&.alive?
  end

  def test_events_retain_strength_and_immutable_fields
    assert_const_defined(Doparserb, :Event)
    event = Doparserb::Event.new(kind: :states, strength: :large, info: {count: 64})
    assert_equal(:states, event.kind)
    assert_equal(:large, event.strength)
    assert_equal({count: 64}, event.info)
    assert_predicate(event, :frozen?)
  end

  def test_observer_exceptions_do_not_change_generation
    assert_const_defined(Doparserb, :EventBus)
    with_grammar("prec") do |directory, path|
      bus = Doparserb::EventBus.new
      def bus.emit(*) = raise("broken observer")
      command = Doparserb::Command.new([path, "-o", File.join(directory, "parser.c")], events: bus)
      assert_nothing_raised { command.run }
      assert_path_exist(File.join(directory, "parser.c"))
      assert_true(bus.closed?)
    end
  end

  def test_system_exit_is_reraised_with_same_status
    assert_const_defined(Doparserb, :EventBus)
    with_grammar("expect_ng") do |directory, path|
      bus = Doparserb::EventBus.new
      command = Doparserb::Command.new([path, "-o", File.join(directory, "parser.c")], events: bus)
      command.instance_variable_get(:@logger).instance_variable_set(:@out, StringIO.new)
      error = assert_raise(SystemExit) { command.run }
      assert_equal(1, error.status)
      assert_true(bus.closed?)
      assert_include(bus.drain.map(&:kind), :expect_mismatch)
    end
  end

  def test_events_include_generation_milestones_and_live_state_additions
    assert_const_defined(Doparserb, :EventBus)
    with_grammar("prec") do |directory, path|
      bus = Doparserb::EventBus.new
      Doparserb::Command.new([path, "-o", File.join(directory, "parser.c")], events: bus).run
      events = bus.drain
      %i[scan loaded states lookahead slash flawless forge complete].each do |kind|
        assert_include(events.map(&:kind), kind)
      end
      counts = events.select { |event| event.kind == :states }.map { |event| event.info[:count] }
      assert_equal((1..counts.last).to_a, counts)
    end
  end

  def test_matching_expectation_is_tamed_without_losing_actual_conflict_counts
    assert_const_defined(Doparserb, :EventBus)
    with_grammar("expect_ok") do |directory, path|
      bus = Doparserb::EventBus.new
      Doparserb::Command.new([path, "-o", File.join(directory, "parser.c")], events: bus).run
      events = bus.drain
      flawless = events.find { |event| event.kind == :flawless }
      assert_not_nil(flawless)
      assert_true(flawless.info[:expected])
      collector = Doparserb::Gen::Collector.new
      events.each { |event| collector.consume(event) }
      assert_equal(1, collector.to_h[:sr_conflicts])
      assert_true(collector.to_h[:expect_matched])
      assert_true(events.find { |event| event.kind == :boss }.info[:tamed])
    end
  end

  def test_collection_context_is_restored_after_a_failed_run
    assert_const_defined(Doparserb, :EventBus)
    with_grammar("expect_ng") do |directory, path|
      bus = Doparserb::EventBus.new
      command = Doparserb::Command.new([path, "-o", File.join(directory, "parser.c")], events: bus)
      command.instance_variable_get(:@logger).instance_variable_set(:@out, StringIO.new)
      previous = Thread.current[:doparserb_command]
      assert_raise(SystemExit) { command.run }
      assert_same(previous, Thread.current[:doparserb_command])
    end
  end

  def test_stream_output_is_not_reopened_for_statistics
    with_grammar("prec") do |directory, path|
      fifo = File.join(directory, "parser.c")
      assert(system("mkfifo", fifo, out: File::NULL, err: File::NULL))
      reader = Thread.new { File.binread(fifo) }
      program = "Timeout.timeout(3) { load ARGV.shift }"
      stdout, stderr, status = Open3.capture3(
        ENVIRONMENT, RbConfig.ruby, "-rtimeout", "-I#{ROOT}/lib", "-e", program,
        File.join(ROOT, "exe/doparserb"), "--dopa-debug-events", "-o", fifo, path,
        chdir: directory
      )
      assert_equal(0, status.exitstatus, stderr)
      assert(reader.join(1), "the output stream must close when generation finishes")
      source = reader.value
      assert_equal("", stdout)
      assert_match(/\A\{/, stderr.lines.last.to_s)
      stats = JSON.parse(stderr.lines.last)
      assert_equal(source.bytesize, stats["output_bytes"])
      assert_equal(source.lines.count, stats["output_lines"])
      assert_operator(stats["output_bytes"], :>, 0)
    ensure
      reader&.kill if reader&.alive?
      reader&.join
    end
  end

  private

  def with_grammar(name)
    Dir.mktmpdir("doparserb-events") do |directory|
      path = File.join(directory, "grammar.y")
      FileUtils.cp(File.join(FIXTURES, "#{name}.y"), path)
      yield directory, path
    end
  end
end
