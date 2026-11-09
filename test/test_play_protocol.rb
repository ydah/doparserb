# frozen_string_literal: true

require_relative "test_helper"
require "doparserb/play/protocol"
require "digest"
require "json"

class PlayProtocolTest < Test::Unit::TestCase
  def setup
    @protocol = Doparserb::Play::Protocol.new(executable: "/missing/parser")
  end

  def teardown
    @protocol.close
  end

  def test_every_event_has_named_arguments_and_immutable_identity
    lines = ["B", "T 3 4 5", "S 3 7 1", "R 2 1 7 1", "E 7 3 4 5", "P 1 0", "X 8 1",
             "Q 2", "I 9", "C", "A", "Z", "O", "D 6"]
    expected = [{}, {sym: 3, line: 4, col: 5}, {sym: 3, state: 7, depth: 1},
                {rule: 2, len: 1, state: 7, depth: 1}, {state: 7, sym: 3, line: 4, col: 5},
                {n: 1, depth: 0}, {state: 8, depth: 1}, {n: 2}, {sym: 9}, {}, {}, {}, {}, {n: 6}]
    events = @protocol.consume(frame(lines.join("\n") + "\n"))
    assert_equal(lines.length, events.length)
    events.zip(lines, expected).each do |event, line, args|
      assert_equal({parser: "0123abcd", pid: 42, parse_id: 1, code: line[0]}.merge(args), event)
      assert_predicate(event, :frozen?)
      assert_predicate(event[:parser], :frozen?)
      assert_predicate(event[:code], :frozen?)
    end
  end

  def test_each_datagram_requires_its_own_valid_header
    assert_equal("B", @protocol.consume(frame("B\n")).first[:code])
    ["B\n", "F bad 42 1\nB\n", "F 0123abcd nope 1\nB\n", "F 0123abcd 0 1\nB\n",
     "F 0123abcd 42 -1\nB\n", "F 0123abcd 42 1 extra\nB\n"].each do |datagram|
      assert_empty(@protocol.consume(datagram))
    end
  end

  def test_bad_lines_do_not_hide_later_events
    invalid = ["unknown", "T 1 2", "B 1", "S x 2 1", "P 1 -1", "Q -1", "R 1 -2 3 4",
               "S 1 2 999999999999999999999999999", "T 1 2 3.0", "F 87654321 99 4", "\xFF".b]
    events = @protocol.consume(frame(invalid.join("\n") + "\nT 1 -1 0\nA\n"))
    assert_equal(%w[T A], events.map { |event| event[:code] })
    assert_equal(-1, events.first[:line])
    assert_empty(@protocol.consume(frame("A")))
  end

  def test_frames_from_different_parsers_processes_and_parses_remain_separate
    identities = [["0123abcd", 42, 1], ["89abcdef", 42, 1], ["0123abcd", 43, 1], ["0123abcd", 42, 2]]
    identities.each do |parser, pid, parse_id|
      event = @protocol.consume(frame("B\n", parser: parser, pid: pid, parse_id: parse_id)).first
      assert_equal([parser, pid, parse_id], event.values_at(:parser, :pid, :parse_id))
    end
  end

  def test_raw_utf8_fragments_reassemble_out_of_order_across_parse_ids
    metadata = metadata_data("λ")
    json = JSON.generate(metadata).b
    parser = metadata.fetch("digest")[0, 8]
    split = json.index("λ".b) + 1
    assert_empty(@protocol.consume(fragment(json.byteslice(split..), parser, split, json.bytesize, parse_id: 2)))
    assert_nil(@protocol.metadata(parser, 42))
    @protocol.consume(fragment(json.byteslice(0, split), parser, 0, json.bytesize))
    result = @protocol.metadata(parser, 42)
    assert_equal(metadata, result)
    assert_predicate(result, :frozen?)
    assert_predicate(result.fetch("symbols"), :frozen?)
    assert_predicate(result.fetch("symbols").first.fetch("name"), :frozen?)
    assert_nil(@protocol.metadata(parser, 43))
  end

  def test_metadata_payload_is_all_remaining_bytes_even_when_it_looks_like_events
    bytes = "{}\nA\nD 99\n"
    assert_empty(@protocol.consume(fragment(bytes, "0123abcd", 0, bytes.bytesize)))
    assert_nil(@protocol.metadata("0123abcd", 42))
  end

  def test_drop_notice_can_precede_a_metadata_fragment
    metadata = metadata_data
    json = JSON.generate(metadata)
    parser = metadata.fetch("digest")[0, 8]
    events = @protocol.consume(frame("D 7\nM #{parser} 0 #{json.bytesize}\n#{json}", parser: parser))
    assert_equal(["D"], events.map { |event| event[:code] })
    assert_equal(7, events.first[:n])
    assert_equal(metadata, @protocol.metadata(parser, 42))
  end

  def test_malformed_metadata_header_does_not_hide_later_valid_lines
    events = @protocol.consume(frame("M 0123abcd nope 10\nM 0123abcd 0 nope\nA\n"))
    assert_equal(["A"], events.map { |event| event[:code] })
  end

  def test_identical_overlapping_bytes_reassemble_but_conflicting_bytes_invalidate
    metadata = metadata_data
    json = JSON.generate(metadata)
    parser = metadata.fetch("digest")[0, 8]
    @protocol.consume(fragment(json.byteslice(0, 40), parser, 0, json.bytesize))
    @protocol.consume(fragment(json.byteslice(30..), parser, 30, json.bytesize))
    assert_equal(metadata, @protocol.metadata(parser, 42))
    @protocol.consume(fragment("x", parser, 10, json.bytesize))
    assert_nil(@protocol.metadata(parser, 42))
  end

  def test_metadata_reassembly_keeps_processes_and_parsers_separate
    first = metadata_data("first")
    second = metadata_data("second")
    streams = [[first, 42], [second, 42], [first, 43]]
    streams.each do |data, pid|
      json = JSON.generate(data)
      parser = data.fetch("digest")[0, 8]
      @protocol.consume(fragment(json.byteslice(0, 30), parser, 0, json.bytesize, pid: pid))
    end
    streams.reverse_each do |data, pid|
      json = JSON.generate(data)
      parser = data.fetch("digest")[0, 8]
      @protocol.consume(fragment(json.byteslice(30..), parser, 30, json.bytesize, pid: pid))
      assert_equal(data, @protocol.metadata(parser, pid))
    end
  end

  def test_identical_duplicate_fragments_are_allowed_and_conflicts_invalidate
    metadata = metadata_data
    json = JSON.generate(metadata)
    parser = metadata.fetch("digest")[0, 8]
    first = fragment(json.byteslice(0, 30), parser, 0, json.bytesize)
    2.times { @protocol.consume(first) }
    @protocol.consume(fragment(json.byteslice(30..), parser, 30, json.bytesize))
    assert_equal(metadata, @protocol.metadata(parser, 42))

    other = Doparserb::Play::Protocol.new(executable: nil)
    other.consume(first)
    other.consume(fragment("x" * 30, parser, 0, json.bytesize))
    other.consume(fragment(json.byteslice(30..), parser, 30, json.bytesize))
    assert_nil(other.metadata(parser, 42))
  end

  def test_bad_metadata_bounds_and_parser_identity_are_rejected
    [[-1, 2, "x"], [0, 0, ""], [1, 1, "xx"], [0, 2**63, "x"]].each do |offset, total, bytes|
      assert_empty(@protocol.consume(fragment(bytes, "0123abcd", offset, total)))
      assert_nil(@protocol.metadata("0123abcd", 42))
    end
    metadata = metadata_data
    json = JSON.generate(metadata)
    parser = metadata.fetch("digest")[0, 8]
    @protocol.consume(frame("M #{parser} 0 #{json.bytesize}\n#{json}"))
    assert_nil(@protocol.metadata(parser, 42))
  end

  def test_invalid_versions_schemas_and_tampered_digests_fall_back
    [metadata_data.merge("v" => 2), metadata_data.merge("symbols" => "wrong"),
     metadata_data.merge("states" => 99), {"v" => 1, "digest" => "0123abcd"}].each do |data|
      json = JSON.generate(data)
      parser = data.fetch("digest")[0, 8]
      @protocol.consume(fragment(json, parser, 0, json.bytesize))
      assert_nil(@protocol.metadata(parser, 42))
    end
  end

  def test_oversized_datagrams_and_metadata_are_ignored_without_raising
    assert_empty(@protocol.consume(frame("B\n" * 1024)))
    assert_empty(@protocol.consume(nil))
    bytes = "x"
    @protocol.consume(fragment(bytes, "0123abcd", 0, Doparserb::Play::Protocol::MAX_METADATA_BYTES + 1))
    assert_nil(@protocol.metadata("0123abcd", 42))
  end

  def test_metadata_cache_and_fragment_count_have_fixed_limits
    limit = Doparserb::Play::Protocol::MAX_METADATA_ENTRIES
    metadata = metadata_data
    json = JSON.generate(metadata)
    parser = metadata.fetch("digest")[0, 8]
    (1..limit + 1).each do |pid|
      @protocol.consume(fragment(json, parser, 0, json.bytesize, pid: pid))
    end
    assert_nil(@protocol.metadata(parser, 1))
    assert_equal(metadata, @protocol.metadata(parser, limit + 1))

    large = metadata_data("x" * (Doparserb::Play::Protocol::MAX_FRAGMENTS + 100))
    json = JSON.generate(large)
    parser = large.fetch("digest")[0, 8]
    json.bytes.each_with_index { |byte, offset| @protocol.consume(fragment(byte.chr, parser, offset, json.bytesize)) }
    assert_nil(@protocol.metadata(parser, 42))
  end

  def test_sidecars_are_matched_by_full_verified_digest_in_cwd_or_resolved_executable_directory
    Dir.mktmpdir("doparserb-sidecars") do |directory|
      cwd = File.join(directory, "cwd")
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p([cwd, bin])
      executable = File.join(bin, "parser")
      File.write(executable, "")
      link = File.join(directory, "parser-link")
      File.symlink(executable, link)
      metadata = metadata_data
      parser = metadata.fetch("digest")[0, 8]
      stub = JSON.generate(metadata.slice("v", "grammar", "digest", "generator"))
      [cwd, bin].each do |destination|
        path = File.join(destination, "parser.dopa.json")
        File.write(path, JSON.generate(metadata))
        protocol = Doparserb::Play::Protocol.new(executable: link, directory: cwd)
        protocol.consume(fragment(stub, parser, 0, stub.bytesize))
        assert_equal(metadata, wait_for { protocol.metadata(parser, 42) })
        protocol.close
        File.unlink(path)
      end

      File.write(File.join(cwd, "malformed.dopa.json"), "{")
      File.write(File.join(cwd, "tampered.dopa.json"), JSON.generate(metadata.merge("states" => 100)))
      File.write(File.join(cwd, "collision.dopa.json"), JSON.generate(metadata.merge("digest" => parser + "0" * 56)))
      protocol = Doparserb::Play::Protocol.new(executable: link, directory: cwd)
      resolved = Queue.new
      protocol.define_singleton_method(:find_sidecar) do |*args|
        super(*args).tap { |result| resolved << [result] }
      end
      protocol.consume(fragment(stub, parser, 0, stub.bytesize))
      wait_for { !resolved.empty? }
      assert_nil(resolved.pop.first)
      assert_nil(protocol.metadata(parser, 42))
      protocol.close
    end
  end

  def test_sidecar_lookup_does_not_block_consumption_and_publishes_frozen_updates_later
    data = metadata_data
    parser = data.fetch("digest")[0, 8]
    stub = JSON.generate(data.slice("v", "grammar", "digest", "generator"))
    started = Queue.new
    release = Queue.new
    @protocol.define_singleton_method(:find_sidecar) do |_stub, _parser|
      started << Thread.current
      release.pop
      data
    end
    consumer = Thread.new { @protocol.consume(fragment(stub, parser, 0, stub.bytesize)) }
    wait_for { !started.empty? }
    worker = started.pop
    assert_not_nil(consumer.join(0.05), "consume must return while sidecar lookup is blocked")
    assert_not_same(consumer, worker)
    assert_nil(@protocol.metadata(parser, 42))
    assert_empty(@protocol.drain_updates)
    assert_equal("A", @protocol.consume(frame("A\n")).first[:code])
    release << true
    result = wait_for { @protocol.metadata(parser, 42) }
    assert_equal(data, result)
    assert_predicate(result, :frozen?)
    assert_predicate(result.fetch("symbols").first.fetch("name"), :frozen?)
    assert_equal([[parser, 42, result]], @protocol.drain_updates)
    assert_empty(@protocol.drain_updates)
  ensure
    release << true if release
    consumer&.join(0.2)
  end

  def test_sidecar_pending_work_is_bounded_and_close_stops_the_only_worker
    data = metadata_data
    parser = data.fetch("digest")[0, 8]
    stub = JSON.generate(data.slice("v", "grammar", "digest", "generator"))
    started = Queue.new
    release = Queue.new
    @protocol.define_singleton_method(:find_sidecar) do |_stub, _parser|
      started << Thread.current
      release.pop
      data
    end
    consumer = Thread.new { @protocol.consume(fragment(stub, parser, 0, stub.bytesize)) }
    wait_for { !started.empty? }
    worker = started.pop
    assert_not_nil(consumer.join(0.05), "consume must not join the resolver")
    limit = Doparserb::Play::Protocol::MAX_METADATA_ENTRIES
    (1..limit * 3).each { |pid| @protocol.consume(fragment(stub, parser, 0, stub.bytesize, pid: pid)) }
    assert_operator(@protocol.instance_variable_get(:@resolver_queue).size, :<=, limit)
    assert_empty(started, "one worker must remain blocked rather than spawning more workers")
    before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @protocol.close
    assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - before, :<, 0.05)
    assert_false(worker.alive?)
    assert_equal(0, @protocol.instance_variable_get(:@resolver_queue).size)
    assert_nothing_raised { @protocol.close }
    assert_empty(@protocol.consume(fragment(stub, parser, 0, stub.bytesize)))
  ensure
    release << true if release
    consumer&.join(0.2)
  end

  def test_late_resolution_cannot_restore_conflicted_metadata
    data = metadata_data
    parser = data.fetch("digest")[0, 8]
    stub = JSON.generate(data.slice("v", "grammar", "digest", "generator"))
    started = Queue.new
    release = Queue.new
    finished = Queue.new
    @protocol.define_singleton_method(:find_sidecar) do |_stub, _parser|
      started << Thread.current
      release.pop
      finished << true
      data
    end
    consumer = Thread.new { @protocol.consume(fragment(stub, parser, 0, stub.bytesize)) }
    wait_for { !started.empty? }
    worker = started.pop
    assert_not_nil(consumer.join(0.05))
    @protocol.consume(fragment("x", parser, 0, stub.bytesize))
    release << true
    wait_for { !finished.empty? && worker.status == "sleep" }
    assert_nil(@protocol.metadata(parser, 42))
    assert_empty(@protocol.drain_updates)
  ensure
    release << true if release
    consumer&.join(0.2)
  end

  private

  def wait_for
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    until (result = yield)
      flunk("timed out waiting for metadata resolution") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(0.001)
    end
    result
  end

  def frame(body, parser: "0123abcd", pid: 42, parse_id: 1)
    "F #{parser} #{pid} #{parse_id}\n".b + body.b
  end

  def fragment(bytes, parser, offset, total, **identity)
    frame("M #{parser} #{offset} #{total}\n".b + bytes.b, parser: parser, **identity)
  end

  def metadata_data(name = "number")
    data = {"v" => 1, "grammar" => "calc.y", "generator" => "doparserb test", "symbols" => [
      {"id" => 3, "name" => name, "term" => true}, {"id" => 9, "name" => "expr", "term" => false}
    ], "rules" => [{"id" => 2, "lhs" => 9, "rhs" => [3], "text" => "expr: number"}], "states" => 10}
    data.merge("digest" => Digest::SHA256.hexdigest(JSON.generate(data)))
  end
end
