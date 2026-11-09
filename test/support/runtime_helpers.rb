# frozen_string_literal: true

require "socket"
require "timeout"
require "json"
require_relative "../test_helper"

module RuntimeHelpers
  include CommandTest

  GCC = "/opt/homebrew/Cellar/gcc/16.2.0/bin/gcc-16"
  COMPILERS = [File.executable?(GCC) ? GCC : "gcc", "clang"].freeze
  SAMPLE_INPUTS = {
    "calc" => ["1+2*3\n", "(1+2)*3\n", "1+\n", "z\n"],
    "json" => ['{"foo":42,"bar":[1,2,3],"baz":true}', "[]", "[1,]", '{"x":invalid}'],
    "sql" => ["SELECT id FROM users;\n", "SELECT id FROM users WHERE age > 18;\n", "SELECT FROM;\n"]
  }.freeze

  def build_parser(name, runtime: true, repair: false, compiler: COMPILERS.first, flags: [], meta: "embed")
    key = [name, runtime, repair, compiler, flags, meta]
    @builds ||= {}
    @builds[key] ||= begin
      directory = Dir.mktmpdir("doparserb-c")
      (@runtime_directories ||= []) << directory
      source = if SAMPLE_INPUTS.key?(name)
                 File.join(LRAMA_ROOT, "sample", "#{name}.y")
               else
                 File.join(FIXTURES, "#{name}.y")
               end
      FileUtils.cp(source, File.join(directory, "grammar.y"))
      args = ["--dopa=off", "--dopa-runtime=#{runtime ? 'on' : 'off'}", "--dopa-meta=#{meta}"]
      args << "-e" if repair
      result = run_command(:doparserb, [*args, "grammar.y", "-o", "parser.c"], directory: directory)
      assert_equal(0, result[:status], result[:stderr])
      command = [compiler, "-std=c99", "-Wall", "-Wextra", "-D_POSIX_C_SOURCE=200809L", "-include", "strings.h", *flags,
                 "parser.c", "-o", "parser"]
      stdout, stderr, status = Open3.capture3(*command, chdir: directory)
      assert_equal(0, status.exitstatus, stdout + stderr)
      {directory: directory, source: File.read(File.join(directory, "parser.c")),
       executable: File.join(directory, "parser"), warnings: stderr}
    end
  end

  def run_parser(build, input, env: {}, socket: nil, timeout: 10)
    options = {stdin_data: input}
    options[socket.fileno] = socket if socket
    variables = ENVIRONMENT.merge(env)
    variables["DOPAPARSER_FD"] = socket.fileno.to_s if socket
    Timeout.timeout(timeout) do
      stdout, stderr, status = Open3.capture3(variables, build.fetch(:executable), **options)
      [stdout, stderr, status.exitstatus || 128 + status.termsig]
    end
  end

  def capture_events(build, input, env: {})
    receiver, sender = Socket.pair(:UNIX, :DGRAM, 0)
    chunks = []
    marker = "DOPARSERB_TEST_END"
    reader = Thread.new do
      loop do
        chunk = receiver.recv(2048)
        break if chunk == marker
        chunks << chunk
      end
    rescue IOError, SystemCallError
      nil
    end
    result = run_parser(build, input, env: env, socket: sender)
    Timeout.timeout(5) do
      sender.send(marker, 0)
      reader.join
    end
    [result, chunks]
  ensure
    sender&.close unless sender&.closed?
    receiver&.close unless receiver&.closed?
    reader&.join
  end

  def event_lines(chunks)
    chunks.flat_map do |chunk|
      assert_operator(chunk.bytesize, :<=, 2048)
      header, body = chunk.split("\n", 2)
      assert_match(/\AF [0-9a-f]{8} \d+ \d+\z/, header)
      next [] if body&.start_with?("M ")
      assert(chunk.end_with?("\n"), "partial event line: #{chunk.inspect}")
      body.to_s.lines.map(&:split)
    end
  end

  def cleanup_runtime
    @runtime_directories&.each { |directory| FileUtils.remove_entry(directory) }
  end
end
