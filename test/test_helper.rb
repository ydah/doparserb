# frozen_string_literal: true

require "test/unit"
require "open3"
require "tmpdir"
require "fileutils"
require "doparserb"

module CommandTest
  ROOT = File.expand_path("..", __dir__)
  LRAMA_ROOT = Gem::Specification.find_by_name("lrama").full_gem_path
  FIXTURES = File.join(__dir__, "fixtures")
  ENVIRONMENT = {
    "DOPAPARSER" => nil, "DOPAPARSER_PROFILE" => "off", "DOPAPARSER_DEBUG" => nil,
    "DOPAPARSER_FD" => nil, "DOPAPARSER_SEED" => "1", "MAKELEVEL" => nil,
    "TERM" => "dumb", "NO_COLOR" => "1"
  }.freeze

  def run_command(name, args, directory:, input: "", env: {})
    executable = name == :lrama ? File.join(LRAMA_ROOT, "exe/lrama") : File.join(ROOT, "exe/doparserb")
    stdout, stderr, status = Open3.capture3(
      ENVIRONMENT.merge(env), RbConfig.ruby, "-I#{ROOT}/lib", executable, *args,
      chdir: directory, stdin_data: input
    )
    {stdout: stdout, stderr: stderr, status: status.exitstatus}
  end

  def generated_files(directory, input_name)
    Dir.glob("**/*", base: directory).sort.filter_map do |path|
      next if path == input_name || !File.file?(File.join(directory, path))
      [path, File.binread(File.join(directory, path))]
    end.to_h
  end

  def normalized_diagnostic(text, debug: false, timing: false)
    text = text.gsub(/(?<=:0x)[0-9a-f]+/, "OBJECT") if debug
    if debug
      text = text.lines.reject do |line|
        callers = [File.join(ROOT, "lib/doparserb"), File.join(ROOT, "exe/doparserb"), File.join(LRAMA_ROOT, "exe/lrama")]
        line.start_with?("\tfrom ") && callers.any? { |path| line.include?(path) }
      end.join
    end
    text = text.gsub(/(?<=\s)\d+\.\d+(?= s(?:\n|\z))/, "TIME") if timing
    text
  end
end
