# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../../test/support/pty_driver"

lrama = Gem::Specification.find_by_name("lrama").full_gem_path
root = File.expand_path("../..", __dir__)
tokens = 2048.times.map { |index| "T#{index}" }
grammars = {
  "calc" => File.read(File.join(lrama, "sample/calc.y")),
  "large" => "%token #{tokens.join(' ')}\n%%\nstart: #{tokens.join(' | ')};\n%%\n",
  "conflicts" => File.read(File.join(root, "test/fixtures/conflicts.y"))
}

grammars.each do |name, grammar|
  Dir.mktmpdir("doparserb-recording") do |directory|
    File.write(File.join(directory, "#{name}.y"), grammar)
    driver = PTYDriver.doparserb("#{name}.y", "-o", "#{name}.c", directory: directory)
    raise "#{name} generation failed" unless driver.wait_exit(timeout: 30).zero?
    raise "missing generation show" unless driver.raw_output.include?("FORGED")
    raise "missing live meter" if name == "large" && !driver.raw_output.include?("CHARGING")
    path = File.join(__dir__, "generation-#{name}.cast")
    File.open(path, "w") do |file|
      file.puts(JSON.generate(version: 2, width: 80, height: 24, timestamp: Time.now.to_i,
                              title: "doparserb generation: #{name}", env: {TERM: "xterm-256color"}))
      driver.records.each do |at, type, bytes|
        file.puts(JSON.generate([at, type, bytes.dup.force_encoding(Encoding::UTF_8).scrub]))
      end
    end
    puts path
  ensure
    driver&.close
  end
end
