# frozen_string_literal: true

require_relative "test_helper"

class GoldenTest < Test::Unit::TestCase
  include CommandTest

  OPTIONS = {
    default: [], header: ["-d"], output: ["-o", "parser.c"], named_header: ["-H", "parser.h"],
    attached_header: ["-Hparser.h"],
    report: ["-r", "all", "--report-file=parser.output"], diagram: ["--diagram=parser.html"],
    repair: ["-e"], warnings: ["-W"], verbose: ["-v"], debug: ["-t"],
    stdin: ["-", "grammar.y"], timing: ["--trace=time"]
  }.freeze
  GRAMMARS = %w[calc json sql parse].to_h { |name| [name, File.join(LRAMA_ROOT, "sample", "#{name}.y")] }
    .merge(%w[conflicts expect_ok expect_ng prec inline param ielr broken warn].to_h do |name|
      [name, File.join(FIXTURES, "#{name}.y")]
    end).freeze

  GRAMMARS.each do |grammar, source|
    OPTIONS.each do |variant, options|
      define_method("test_#{grammar}_#{variant}") do
        Dir.mktmpdir("doparserb-golden") do |directory|
          input = File.binread(source)
          File.binwrite(File.join(directory, "grammar.y"), input)
          args = variant == :stdin ? options : [*options, "grammar.y"]
          baseline = run_command(:lrama, args, directory: directory, input: input)
          fails = %w[expect_ng broken].include?(grammar) || variant == :named_header
          assert_equal(fails ? 1 : 0, baseline[:status], "upstream fixture status")
          expected_files = generated_files(directory, "grammar.y")
          ["off", "default"].each do |mode|
            expected_files.each_key { |path| File.unlink(File.join(directory, path)) if File.exist?(File.join(directory, path)) }
            own = mode == "off" ? ["--dopa=off", "--dopa-runtime=off"] : []
            actual = run_command(:doparserb, [*own, *args], directory: directory, input: input)
            assert_equal(baseline[:status], actual[:status], "#{mode} status")
            %i[stdout stderr].each do |stream|
              assert_equal(normalized_diagnostic(baseline[stream], debug: variant == :debug, timing: variant == :timing),
                           normalized_diagnostic(actual[stream], debug: variant == :debug, timing: variant == :timing),
                           "#{mode} #{stream}")
            end
            assert_equal(expected_files, generated_files(directory, "grammar.y"), "off artifacts") if mode == "off"
          end
        end
      end
    end
  end
end
