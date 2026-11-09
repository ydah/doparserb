# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../../test/support/pty_driver"

root = File.expand_path("../..", __dir__)
Dir.mktmpdir("doparserb-watch-recording") do |directory|
  grammar = File.join(directory, "grammar.y")
  replace = lambda do |fixture|
    temporary = File.join(directory, "saved.y")
    File.write(temporary, File.read(File.join(root, "test/fixtures/#{fixture}.y")))
    File.rename(temporary, grammar)
  end
  replace.call("conflicts")
  driver = PTYDriver.doparserb("watch", "grammar.y", "-o", "parser.c", "--dopa-set",
                              "duration=0.2,flash=off", directory: directory)
  driver.wait_for(/\* WATCH \* CONFLICTS [1-9]\d*  READY/)
  replace.call("broken")
  driver.wait_for("* WATCH * CONFLICTS ?  FAILED")
  replace.call("prec")
  driver.wait_for("* WATCH * CONFLICTS 0  READY")
  driver.send_keys("\x03")
  raise "watch did not stop cleanly" unless driver.wait_exit == 130
  raise "unknown terminal sequences: #{driver.unknown}" unless driver.unknown.empty?
  raise "recovered build produced no parser" unless File.size?(File.join(directory, "parser.c"))
  path = File.join(__dir__, "watch.cast")
  File.open(path, "w") do |file|
    file.puts(JSON.generate(version: 2, width: 80, height: 24, timestamp: Time.now.to_i,
                            title: "doparserb watch: conflicts, error, recovery", env: {TERM: "xterm-256color"}))
    driver.records.each do |at, type, bytes|
      file.puts(JSON.generate([at, type, bytes.dup.force_encoding(Encoding::UTF_8).scrub]))
    end
  end
  puts path
ensure
  driver&.close
end
