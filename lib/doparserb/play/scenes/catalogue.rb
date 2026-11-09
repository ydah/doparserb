# frozen_string_literal: true

module Doparserb
  module Play
    module Scenes
      Scene = Data.define(:kind, :strength, :title, :subtitle, :data)
      KINDS = %i[tower next shift reduce chain from_nothing tower_milestone syntax_break collapse recovery repair_plan inserted auto_repair stage_clear comeback aborted exhausted token_milestone critical jackpot llama_drop].freeze
      DEMO_STATS = {
        blocks: [{sym: 2, state: 3, label: "NUMBER"}.freeze, {sym: 3, state: 5, label: "expr"}.freeze].freeze,
        next_token: {sym: 2, line: 3, col: 7, label: "NUMBER"}.freeze,
        depth: 2, max_depth: 32, tokens: 1000, reductions: 12, chain: 8, max_chain: 8,
        errors: 1, repairs: 1, inserted: 1, discarded: 0, approximate: false,
        event: {code: "R", len: 2, rule: 1, n: 3, line: 3, col: 7}.freeze
      }.freeze

      module_function

      def priority(kind)
        case kind
        when :llama_drop then 5
        when :comeback, :auto_repair, :inserted, :repair_plan, :jackpot then 4
        when :syntax_break, :recovery, :stage_clear, :aborted, :exhausted, :critical then 3
        when :chain, :tower_milestone, :token_milestone, :collapse then 2
        else 1
        end
      end

      def labels(metadata)
        names = Array(metadata && metadata["symbols"]).to_h { |symbol| [symbol["id"], safe(symbol["name"]).freeze] }
        names[:rules] = Array(metadata && metadata["rules"]).to_h do |rule|
          [rule["id"], names.fetch(rule["lhs"], "SYM #{rule['lhs']}").freeze]
        end.freeze
        names.freeze
      end

      def label_data(stats, names)
        blocks = stats[:blocks].map do |block|
          label = if block[:sym]
                    names.fetch(block[:sym], "SYM #{block[:sym]}")
                  else
                    names.fetch(:rules, {}).fetch(block[:rule], "RULE #{block[:rule]}")
                  end
          block.merge(label: label.freeze).freeze
        end.freeze
        next_token = stats[:next_token]&.then { |token| token.merge(label: names.fetch(token[:sym], "SYM #{token[:sym]}").freeze).freeze }
        sym = stats.dig(:event, :sym)
        stats.merge(blocks: blocks, next_token: next_token, symbol_label: names.fetch(sym, "SYM #{sym}").freeze).freeze
      end

      def relabel(scene, names)
        updated = build(scene.kind, label_data(scene.data, names))
        prefix = scene.subtitle[/\A>> x\d+  /].to_s
        Scene.new(**updated.to_h.merge(strength: scene.strength, subtitle: "#{prefix}#{updated.subtitle}".freeze))
      end

      def for_event(event, stats, names, previous_max_depth: 0)
        data = label_data(stats.merge(event: event.dup.freeze), names)
        kind = case event[:code]
               when "T" then :next
               when "S"
                 if stats[:tokens].positive? && (stats[:tokens] % 1000).zero?
                   :token_milestone
                 elsif stats[:depth] > 1 && stats[:max_depth] > previous_max_depth && (stats[:depth] & (stats[:depth] - 1)).zero?
                   :tower_milestone
                 else :shift
                 end
               when "R" then stats[:chain] >= 3 ? :chain : (event[:len].zero? ? :from_nothing : :reduce)
               when "E" then :syntax_break
               when "P" then :collapse
               when "X" then :recovery
               when "Q" then :repair_plan
               when "I" then :inserted
               when "C" then :auto_repair
               when "A" then stats[:comeback] ? :comeback : :stage_clear
               when "Z" then :aborted
               when "O" then :exhausted
               else :tower
               end
        bonus = stats.dig(:game, :bonus)
        if bonus && priority(bonus) >= priority(kind)
          data = data.merge(folded: build(kind, data).subtitle, multiplier: stats[:game][:multiplier]).freeze
          kind = bonus
        end
        build(kind, data)
      end

      def build(kind, stats)
        event = stats.fetch(:event, {})
        title, subtitle = case kind
                          when :tower then ["STACK TOWER", "PARSER READY"]
                          when :next then ["NEXT", stats.dig(:next_token, :label).to_s]
                          when :shift then ["SHIFT", "+ #{stats[:symbol_label] || 'NUMBER'}  * LANDING *"]
                          when :reduce then ["REDUCE", "RULE #{event[:rule]}  MERGE #{event[:len]} -> 1  +#{10 * event[:len].to_i}"]
                          when :chain
                            action = event[:len].to_i.zero? ? "FROM NOTHING" : "MERGE #{event[:len]} -> 1"
                            ["#{stats[:chain]} CHAIN!", "#{action}  +#{10 * event[:len].to_i}"]
                          when :from_nothing then ["FROM NOTHING", "EMPTY RULE #{event[:rule]}  +1 BLOCK"]
                          when :tower_milestone then ["TOWER #{stats[:max_depth]}F!", "NEW MAXIMUM DEPTH  * LANDING *"]
                          when :syntax_break then ["SYNTAX BREAK @#{event[:line]}:#{event[:col]}", "PARSER REPORTED A SYNTAX ERROR"]
                          when :collapse then ["COLLAPSE", "-#{event[:n]}F"]
                          when :recovery then ["RECOVERY", "ERROR BLOCK LANDED"]
                          when :repair_plan then ["AUTO REPAIR", "+#{event[:n]} TOKENS PLANNED"]
                          when :inserted then ["TOKEN INSERTED", "+ #{stats[:symbol_label] || "SYM #{event[:sym]}"} INSERTED"]
                          when :auto_repair then ["AUTO REPAIR!", "#{stats[:inserted]} TOKENS INSERTED"]
                          when :stage_clear then ["STAGE CLEAR!", totals(stats)]
                          when :comeback then ["COMEBACK!", totals(stats)]
                          when :aborted then ["ABORTED", totals(stats)]
                          when :exhausted then ["STACK EXHAUSTED", totals(stats)]
                          when :token_milestone
                            count = stats[:tokens].to_i
                            [count.positive? && (count % 1_000_000).zero? ? "#{count / 1_000_000}M TOKENS!!!" : "#{count / 1000}K TOKENS!", totals(stats)]
                          when :critical then ["CRITICAL!", "REDUCTION x#{stats.fetch(:multiplier, 4)}"]
                          when :jackpot then ["JACKPOT!!", "7 - 7 - 7    REDUCTION x16"]
                          when :llama_drop then ["LLAMA DROP!", Ranch.variant(stats.fetch(:id, 0) || 0)[:name]]
                          else raise ArgumentError, "unknown parse scene: #{kind}"
                          end
        strength = case priority(kind)
                   when 4, 5 then :huge
                   when 3 then :large
                   when 2
                     if kind == :chain && [8, 16, 32].include?(stats[:chain]) then :huge
                     elsif kind == :token_milestone || kind == :chain && stats[:chain].to_i >= 5 then :large
                     else :medium
                     end
                   else kind == :reduce && event[:len].to_i >= 4 ? :medium : :small
                   end
        subtitle += " / #{stats[:folded]}" if stats[:folded]
        if (game = stats[:game])
          subtitle += " / +#{game[:points]}  SCORE #{game[:score]}  COMBO #{game[:combo]}"
          subtitle += " / FEVER x#{Game::FEVER_MULTIPLIER}" if game[:fever]
        end
        subtitle += " / #{Career.summary(stats[:career])}" if stats[:career]
        Scene.new(kind: kind, strength: strength, title: safe(title).freeze, subtitle: safe(subtitle).freeze, data: stats.merge(play: true).freeze)
      end

      def totals(stats)
        "#{stats[:tokens]} TOKENS  #{stats[:reductions]} REDUCTIONS  MAX #{stats[:max_depth]}F  #{stats[:max_chain]} CHAIN"
      end

      def safe(text)
        text.to_s.encode("US-ASCII", invalid: :replace, undef: :replace, replace: "?").gsub(/[\x00-\x1f\x7f]/, "?")
      end
    end
  end
end
