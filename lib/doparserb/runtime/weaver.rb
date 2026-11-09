# frozen_string_literal: true

require "tmpdir"

module Doparserb
  module Runtime
    class Weaver
      def initialize(template)
        @template = template
      end

      def weave
        mismatches = Anchors::ALL.filter_map do |name, anchor|
          expected = anchor.fetch(:count, 1)
          actual = @template.scan(Regexp.new(Regexp.escape(anchor.fetch(:text)))).length
          next if actual == expected

          "#{name} expected #{expected} matches, found #{actual}"
        end
        raise Error, "unsupported lrama skeleton: #{mismatches.join('; ')}; use --dopa-runtime=off" unless mismatches.empty?

        Anchors::ALL.each_value.reduce(@template.dup) do |source, anchor|
          text, hook = anchor.values_at(:text, :hook)
          source.gsub(text) do
            case anchor[:position]
            when :before then "#{hook}\n#{text}"
            when :declaration then text.sub("  int yylen = 0;", "  int yylen = 0;\n#{hook}")
            else "#{text}\n#{hook}"
            end
          end
        end
      end

      def with_template
        source = weave
        Dir.mktmpdir("doparserb-runtime") do |directory|
          path = File.join(directory, "yacc.c")
          File.write(path, source)
          yield path
        end
      end
    end
  end
end
