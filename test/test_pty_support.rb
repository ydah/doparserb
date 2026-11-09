# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/pty_driver"

class PTYSupportTest < Test::Unit::TestCase
  def test_resize_updates_child_window_size_and_screen_model
    script = <<~RUBY
      require "io/console"
      STDOUT.sync = true
      Signal.trap("WINCH") { puts "SIZE:" + STDOUT.winsize.join("x") }
      puts "READY"
      STDIN.gets
    RUBY
    driver = PTYDriver.new([RbConfig.ruby, "-e", script])
    driver.wait_for("READY")
    driver.resize(rows: 24, cols: 30)
    driver.wait_for("SIZE:24x30")
    assert(driver.lines.all? { |line| line.length <= 30 })
    driver.send_keys("\n")
    assert_equal(0, driver.wait_exit)
  ensure
    driver&.close
  end

  def test_virtual_terminal_removes_erased_frames
    terminal = VT.new(4, 20)
    terminal.feed("temporary\r\e[2Kresult\n")
    assert_equal("result", terminal.all_text)
    assert_equal({}, terminal.unknown)
  end

  def test_driver_preserves_input_and_exit_status
    program = '$stdout.sync = true; puts "READY"; puts "RETURN:#{STDIN.gets}"; exit 7'
    driver = PTYDriver.new([RbConfig.ruby, "-e", program])
    driver.wait_for("READY")
    driver.send_keys("hello\n")
    assert_equal(7, driver.wait_exit)
    assert_include(driver.all_text, "RETURN:hello")
    assert_not_empty(driver.records)
    assert_operator(driver.elapsed, :>, 0)
  ensure
    driver&.close
  end
end
