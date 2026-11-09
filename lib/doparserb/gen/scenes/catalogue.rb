# frozen_string_literal: true

module Doparserb
  module Gen
    module Scenes
      Scene = Data.define(:kind, :strength, :title, :subtitle, :data)
      KINDS = %i[title scan loaded evolve fusion states lookahead split slash boss flawless forge extra warning new_ability record critical jackpot achievement llama_drop finale grammar_break expect_mismatch validation_break].freeze
      DEMO_STATS = {
        grammar: "calc.y", output: "calc.c", tokens: 1234, rules: 120, terms: 85, nterms: 60,
        states: 256, parameterized: 12, inline_expansions: 3, split_states: 12,
        resolved_conflicts: 45, sr_conflicts: 0, rr_conflicts: 0, expect: 2,
        expect_matched: false, output_lines: 1872, extras: %i[header report], warnings: 2,
        features: ["ielr"], success: true, failure: nil, duration: 0.12,
        llama: 17, achievements: ["FIRST FORGE"]
      }.freeze

      module_function

      def build(kind, stats)
        strength = :large
        title, subtitle = case kind
                          when :title then ["DOPARSERB", "GRAMMAR IN / PARSER OUT"]
                          when :scan
                            strength = :small
                            ["SCAN", "SCAN #{number(stats[:tokens])} TOKENS"]
                          when :loaded
                            strength = :medium
                            ["LOADED", "RULES #{stats[:rules]}   TERMS #{stats[:terms]}   NTERMS #{stats[:nterms]}"]
                          when :evolve
                            strength = :medium
                            ["EVOLVE", "option(X) -> option_expr   EVOLVE x#{stats[:parameterized]}"]
                          when :fusion
                            strength = :medium
                            ["FUSION", "INLINE FUSION x#{stats[:inline_expansions]}"]
                          when :states then ["STATES", state_milestone(stats[:states])]
                          when :lookahead
                            strength = :medium
                            ["LOOKAHEAD", "LOOKAHEAD LOCK"]
                          when :split then ["IELR SPLIT", "IELR SPLIT +#{stats[:split_states]}"]
                          when :slash
                            strength = stats[:resolved_conflicts].to_i >= 32 ? :large : :medium
                            ["SLASH", "PRECEDENCE SLASH x#{stats[:resolved_conflicts]}"]
                          when :boss
                            [stats[:expect_matched] ? "TAMED" : "CONFLICT BOSS", "S/R x#{stats[:sr_conflicts]}   R/R x#{stats[:rr_conflicts]}"]
                          when :flawless
                            strength = :huge
                            ["FLAWLESS!!", stats[:expect_matched] ? "EXPECTED CONFLICTS TAMED" : "FLAWLESS!! NO CONFLICT"]
                          when :forge
                            ["FORGED", "FORGED #{File.basename(stats[:output].to_s)} #{number(stats[:output_lines])} LINES  #{extras(stats)}"]
                          when :extra
                            strength = :small
                            ["EXTRA", extras(stats)]
                          when :warning
                            strength = :medium
                            ["WARNING", "WARNING x#{stats[:warnings]}"]
                          when :new_ability then ["NEW ABILITY", "NEW ABILITY: #{stats.fetch(:new_features, stats.fetch(:features, ["IELR"])).join(' / ').upcase}"]
                          when :record
                            strength = :huge
                            ["RECORD", stats[:records]&.join(" / ") || stats.fetch(:record, "CONFLICTS 3 -> 0  FIXED!")]
                          when :critical then ["CRITICAL!", "CRITICAL x#{stats.fetch(:multiplier, 4)}"]
                          when :jackpot
                            strength = :huge
                            ["JACKPOT!!", "7 - 7 - 7    JACKPOT x16"]
                          when :achievement
                            strength = :huge
                            ["ACHIEVEMENT!", stats.fetch(:achievements, []).join(" / ")]
                          when :llama_drop
                            strength = :huge
                            ["LLAMA DROP!", Ranch.variant(stats.fetch(:llama, 0))[:name]]
                          when :finale
                            strength = :huge
                            [stats[:title] || "FORGE CLEAR", "STATES #{stats[:states]}   RULES #{stats[:rules]}   #{number(stats[:output_lines])} LINES"]
                          when :grammar_break
                            location = stats.dig(:failure, :message).to_s[/\d+:\d+/]
                            ["GRAMMAR BREAK", location ? "GRAMMAR BREAK @#{location}" : "CHECK GRAMMAR SYNTAX"]
                          when :expect_mismatch
                            ["EXPECT MISMATCH", "EXPECTED #{stats[:expect]}, FOUND #{stats[:sr_conflicts].to_i + stats[:rr_conflicts].to_i}"]
                          when :validation_break then ["FAILED", "VALIDATION BREAK"]
                          else raise ArgumentError, "unknown generation scene: #{kind}"
                          end
        Scene.new(kind: kind, strength: strength, title: title, subtitle: subtitle, data: kind == :llama_drop ? stats.merge(id: stats[:llama]) : stats)
      end

      def reel(stats)
        return [build(stats[:failure][:kind], stats)] if stats[:failure]
        return [] unless stats[:success]
        kinds = [:states, :forge]
        kinds << :flawless if stats[:sr_conflicts].to_i.zero? && stats[:rr_conflicts].to_i.zero? || stats[:expect_matched]
        kinds << :boss if stats[:sr_conflicts].to_i + stats[:rr_conflicts].to_i > 0
        kinds << :slash if stats[:resolved_conflicts].to_i > 0
        kinds << :split if stats[:split_states].to_i > 0
        kinds << :new_ability if stats[:new_features]&.any?
        kinds << :record if stats[:records]&.any?
        kinds << stats[:bonus] if stats[:bonus]
        kinds << :achievement if stats[:achievements]&.any? && stats[:score]
        kinds << :llama_drop if stats[:llama] && stats[:score]
        scenes = kinds.map { |kind| build(kind, stats) }
        priorities = {small: 0, medium: 1, large: 2, huge: 3}
        chosen = scenes.sort_by.with_index { |scene, index| [-(scene.kind == :llama_drop ? 4 : priorities[scene.strength]), index] }.first(4)
        folded = ["SCAN #{number(stats[:tokens])} TOKENS", "RULES #{stats[:rules]}"]
        folded << "EVOLVE x#{stats[:parameterized]}" if stats[:parameterized].to_i > 0
        folded << "INLINE FUSION x#{stats[:inline_expansions]}" if stats[:inline_expansions].to_i > 0
        folded << "WARNING x#{stats[:warnings]}" if stats[:warnings].to_i > 0
        folded.concat((scenes - chosen).map(&:subtitle))
        folded << Career.summary(stats) if stats[:score]
        finale = build(:finale, stats)
        chosen.sort_by! { |scene| kinds.index(scene.kind) }
        chosen + [Scene.new(**finale.to_h.merge(subtitle: [finale.subtitle, *folded].join(" / ")))]
      end

      def extras(stats) = stats.fetch(:extras, []).map { |kind| "+#{kind.to_s.upcase}" }.join(" ")
      def number(value) = value.to_i.to_s.reverse.scan(/.{1,3}/).join(",").reverse

      def state_milestone(count)
        count = count.to_i
        milestone = {64 => "64 STATES!", 256 => "256 FULL BYTE!!", 1024 => "0x400 OVERFLOW!!!", 4096 => "4096 PAGE SIZE!!!"}.keys.select { |n| n <= count }.last
        label = {64 => "64 STATES!", 256 => "256 FULL BYTE!!", 1024 => "0x400 OVERFLOW!!!", 4096 => "4096 PAGE SIZE!!!"}[milestone]
        ["#{number(count)} STATES", label].compact.join("   ")
      end
    end
  end
end
