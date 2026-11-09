# frozen_string_literal: true

require_relative "support/runtime_helpers"

class RuntimeFuzzTest < Test::Unit::TestCase
  include RuntimeHelpers

  CASES = 10_000
  SEED = 0xD0FA

  def teardown = cleanup_runtime

  def test_c2_ten_thousand_seeded_json_inputs_preserve_behavior
    baseline = build_parser("json", runtime: false)
    observed = build_parser("json")
    random = Random.new(SEED)
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    received = 0
    reader = Thread.new do
      loop do
        chunk = receiver.recv(2048)
        break if chunk == "DONE"
        received += 1
      end
    rescue IOError, SystemCallError
      nil
    end
    CASES.times do |index|
      input = if index.even?
                JSON.generate(Array.new(random.rand(0..8)) { json_value(random, 2) })
              else
                alphabet = '{}[],:"\\0123456789truefalsenull xyz+-.' + "\n\t"
                Array.new(random.rand(0..128)) { alphabet[random.rand(alphabet.length)] }.join
              end
      expected = run_parser(baseline, input)
      actual = run_parser(observed, input, socket: sender)
      assert_equal(expected, actual, "seed=#{SEED} case=#{index} input=#{input.inspect}")
      warn "JSON fuzz: #{index + 1}/#{CASES}" if ((index + 1) % 2500).zero?
    end
    Timeout.timeout(5) do
      sender.send("DONE", 0)
      reader.join
    end
    assert_operator(received, :>=, CASES, "fuzzing did not exercise the active event sink")
  ensure
    sender&.close
    receiver&.close
    reader&.join
  end

  private

  def json_value(random, depth)
    case random.rand(depth.positive? ? 6 : 4)
    when 0 then random.rand(-999..999)
    when 1 then [true, false, nil][random.rand(3)]
    when 2 then "text #{random.rand(1000)}"
    when 3 then random.rand.round(4)
    when 4 then Array.new(random.rand(4)) { json_value(random, depth - 1) }
    when 5 then {"key#{random.rand(10)}" => json_value(random, depth - 1)}
    end
  end
end
