# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../test/support/pty_driver"

root = File.expand_path("../..", __dir__)
lrama = Gem::Specification.find_by_name("lrama").full_gem_path
scenarios = {
  "calc" => {source: File.join(lrama, "sample/calc.y"), ready: "Enter the formula:",
              input: ["1+2*3\n", "(1+2)*3\n"], expected: ["=> 7", "=> 9"], env: {}},
  "comeback" => {source: File.join(root, "test/fixtures/runtime_calc.y"), ready: "CALC READY",
                  input: ["1+\n", "2*3\n"], expected: ["syntax error", "=> 6"], env: {"PARSER_READY" => "1"}}
}
scenarios.each do |name, scenario|
  Dir.mktmpdir("doparserb-play-recording") do |directory|
    FileUtils.cp(scenario[:source], File.join(directory, "grammar.y"))
    command = [RbConfig.ruby, "-I#{root}/lib", File.join(root, "exe/doparserb"), "--dopa=off", "grammar.y", "-o", "parser.c"]
    _, error, status = Open3.capture3(*command, chdir: directory)
    raise "generation failed: #{error}" unless status.success?
    _, error, status = Open3.capture3("clang", "-std=c99", "parser.c", "-o", "parser", chdir: directory)
    raise "compilation failed: #{error}" unless status.success?
    driver = PTYDriver.doparserb("play", "--", File.join(directory, "parser"), directory: directory, env: scenario[:env])
    driver.wait_for(scenario[:ready])
    scenario[:input].zip(scenario[:expected]).each do |input, expected|
      driver.send_keys(input)
      driver.wait_for(expected)
      sleep 0.7
    end
    driver.send_keys("\x04")
    raise "play failed" unless driver.wait_exit(timeout: 10).zero?
    raise "missing tower playback" unless driver.raw_output.include?("STACK TOWER")
    raise "missing comeback" if name == "comeback" && !driver.raw_output.include?("COMEBACK")
    path = File.join(__dir__, "play-#{name}.cast")
    File.open(path, "w") do |file|
      file.puts(JSON.generate(version: 2, width: 80, height: 24, timestamp: Time.now.to_i,
                              title: "doparserb play: #{name}", env: {TERM: "xterm-256color"}))
      driver.records.each do |at, type, bytes|
        file.puts(JSON.generate([at, type, bytes.dup.force_encoding(Encoding::UTF_8).scrub]))
      end
    end
    puts path
  ensure
    driver&.close
  end
end
