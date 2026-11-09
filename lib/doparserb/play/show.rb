# frozen_string_literal: true

module Doparserb
  module Play
    class Show
      MAX_PENDING = 2048
      MAX_TOWERS = 128
      HIGHLIGHT_FRAMES = 12
      ANIMATION_DURATION = 0.35
      DEMO_DURATION = 0.55
      SCENE_DURATIONS = {
        shift: 0.65, reduce: 0.7, chain: 0.85, from_nothing: 0.7,
        recovery: 0.85, repair_plan: 0.85, inserted: 0.7, auto_repair: 0.85,
        tower_milestone: 0.9, token_milestone: 1.2,
        critical: 0.9, jackpot: 2.3, stage_clear: 1.2, comeback: 1.3, llama_drop: 1.6
      }.freeze
      TOTAL_FIELDS = %i[tokens reductions errors repairs inserted discarded].freeze

      attr_reader :folded_events

      def initialize(config:, engine: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, career: nil)
        @config, @engine, @clock = config, engine || Engine.new(config, preserve_input: true), clock
        @towers, @metadata, @names, @max_depths = {}, {}, {}, {}
        @queue = []
        @retired = TOTAL_FIELDS.to_h { |field| [field, 0] }.merge(max_depth: 0, max_chain: 0, approximate: false)
        @folded_events = 0
        @finished = @done = @output_open = false
        @career = career
      end

      def start = self
      def done? = @done
      def pending_count = @queue.length
      def tracked_parses = @towers.length

      def self.demo(config, engine: Engine.new(config))
        engine.session do
          Scenes::KINDS.each do |kind|
            break if engine.cancelled?
            stats = Scenes::DEMO_STATS
            stats = case kind
                    when :shift
                      stats.merge(blocks: stats[:blocks].reverse.freeze, symbol_label: "NUMBER", next_token: nil, chain: 0,
                                  event: {code: "S", sym: 2, state: 3, depth: 2}.freeze)
                    when :reduce
                      stats.merge(blocks: stats[:blocks].last(1).freeze, depth: 1, chain: 1,
                                  event: {code: "R", len: 2, rule: 1, state: 5, depth: 2}.freeze)
                    when :recovery
                      stats.merge(blocks: [{sym: 1, state: 5, label: "error"}.freeze].freeze, depth: 1, chain: 0,
                                  event: {code: "X", state: 5, depth: 1}.freeze)
                    else stats
                    end
            if (multiplier = {critical: 4, jackpot: 16}[kind])
              points = 20 * multiplier
              stats = stats.merge(multiplier: multiplier, game: {points: points, score: 1000 + points, combo: 8})
            end
            scene = Scenes.build(kind, stats)
            duration = SCENE_DURATIONS.fetch(kind, DEMO_DURATION) * config.duration
            engine.scene(kind, title: scene.title, subtitle: scene.subtitle, data: scene.data, duration: duration)
          end
          engine.badge("* DOPARSERB DEMO * ALL PARSE SCENES")
        end
      end

      def consume(event, metadata: nil)
        return if @finished
        @career ||= Career.new(interactive: @engine.respond_to?(:enabled?) && @engine.enabled?)
        award = @career.consume(event)
        key = event.values_at(:parser, :pid, :parse_id).freeze
        tower = (@towers[key] ||= Tower.new)
        tower.consume(event, metadata: metadata || @metadata[key])
        @last = tower
        return unless animated?
        metadata_available(event[:parser], event[:pid], metadata) if metadata && !@metadata[key].equal?(metadata)
        stats = tower.to_h.merge(game: award)
        scene = Scenes.for_event(event, stats, @names.fetch(key, {}), previous_max_depth: @max_depths.fetch(key, 0))
        @last_scene = scene
        @max_depths[key] = stats[:max_depth]
        @strongest = scene if !@strongest || Scenes.priority(scene.kind) >= Scenes.priority(@strongest.kind)
        @queue << scene
        if @queue.length > MAX_PENDING
          @folded_events += @queue.shift(MAX_PENDING / 2).length
        end
      rescue StandardError => error
        Doparserb.debug(error)
      ensure
        retire_oldest if @towers.length > MAX_TOWERS
      end

      def metadata_available(parser, pid, metadata)
        return unless metadata
        keys = @towers.keys.select { |key| key[0] == parser && key[1] == pid && !@metadata[key].equal?(metadata) }
        return if keys.empty?
        names = Scenes.labels(metadata)
        keys.each do |key|
          @metadata[key] = metadata
          @names[key] = names
        end
      rescue StandardError => error
        Doparserb.debug(error)
      end

      def tick(now: @clock.call)
        return if @done || @output_open && !@finished
        if @queue.empty? && !@finished
          animate_current(now)
          @next_at = nil if @next_at && now >= @next_at
          return
        end
        @next_at ||= now
        if !@queue.empty? && now >= @next_at
          @engine.resume
          count = @config.replay == :full ? 64 : 1
          count.times do
            break if @queue.empty? || now + 1e-9 < @next_at
            scene = @queue.shift
            interval = interval_for(scene)
            @animation_started = nil
            safely do
              names = @names[scene.data[:event].values_at(:parser, :pid, :parse_id)]
              scene = Scenes.relabel(scene, names) if names
              tween = @engine.respond_to?(:animate)
              @engine.frame(scene.kind, title: scene.title, subtitle: scene.subtitle, data: scene.data, progress: tween ? 0.0 : 1.0)
              if tween
                @animation_started = now
                duration = ANIMATION_DURATION * @config.duration
                duration = [duration, interval].max if @config.replay == :highlight
                @animation_duration = @queue.empty? && !@finished ? duration : [duration, interval].min
              end
            end
            @next_at += interval
          end
        end
        animate_current(now)
        complete if @finished && @queue.empty? && now >= @next_at
      rescue StandardError => error
        Doparserb.debug(error)
        @queue.clear
        @animation_started = nil
        complete if @finished
      end

      def yield_to_output(bytes = nil)
        @animation_started = nil
        safely { @engine.yield_to_output }
        @output_open = !bytes.end_with?("\n") if bytes && !bytes.empty?
        @next_at = nil
      end

      def cancel
        @animation_started = nil
        safely { @engine.silence if @engine.respond_to?(:silence) }
        @queue.clear
        @strongest = nil
        @last_scene = nil
        @next_at = nil
        safely { @engine.clear }
      end

      def finish
        return self if @finished
        @finished = true
        @result = @career&.finish
        decorate_ending if @result
        if @output_open || !animated?
          @queue.clear
          @animation_started = nil
        elsif @config.replay == :highlight
          prepare_highlight
        end
        @next_at = @clock.call if @config.replay != :full || !@next_at
        self
      end

      private

      def interval_for(scene)
        return @highlight_intervals.shift if @highlight_intervals
        return 1.0 / @config.speed if @config.replay == :full

        duration = if scene.strength == :huge
                     (SCENE_DURATIONS.fetch(scene.kind, DEMO_DURATION) / 2).clamp(0.55, 0.9)
                   elsif Scenes.priority(scene.kind) >= 3
                     0.55
                   else
                     0.14
                   end
        duration * @config.duration
      end

      def animate_current(now)
        return unless @animation_started
        progress = ((now - @animation_started) / @animation_duration).clamp(0.0, 1.0)
        return unless progress.positive?
        @engine.animate(progress: progress)
        @animation_started = nil if progress == 1.0
      rescue StandardError => error
        @animation_started = nil
        Doparserb.debug(error)
      end

      def animated?
        !@config.off? && @config.motion && @config.replay != :off && @engine.animated?
      end

      def decorate_ending
        scene = @queue.last || @last_scene
        return unless scene
        kind = @result[:llama] ? :llama_drop : scene.kind
        data = scene.data.merge(career: @result, id: @result[:llama], ending: @queue.empty?).freeze
        ending = Scenes.build(kind, data)
        @queue.empty? ? @queue << ending : @queue[-1] = ending
        @strongest = @queue.last if kind == :llama_drop || scene.equal?(@strongest)
      end

      def add_totals(totals, stats)
        TOTAL_FIELDS.each { |field| totals[field] += stats[field] }
        %i[max_depth max_chain].each { |field| totals[field] = [totals[field], stats[field]].max }
        totals[:approximate] ||= stats[:approximate]
      end

      def retire_oldest
        key, tower = @towers.find { |_, item| item.to_h[:outcome] } || @towers.first
        stats = tower.to_h
        add_totals(@retired, stats)
        @retired[:approximate] = true unless stats[:outcome]
        [@towers, @metadata, @names, @max_depths].each { |history| history.delete(key) }
      end

      def prepare_highlight
        original = @queue.length
        stride = [(@queue.length.fdiv(HIGHLIGHT_FRAMES)).ceil, 1].max
        @queue = @queue.each_slice(stride).map(&:last)
        @queue.delete(@strongest)
        @queue << @strongest if @strongest
        @folded_events += [original - @queue.length, 0].max
        speed = [stride, 1].max
        @queue.map! { |scene| Scenes::Scene.new(**scene.to_h.merge(subtitle: ">> x#{speed}  #{scene.subtitle}")) }
        weights = @queue.map { |scene| SCENE_DURATIONS.fetch(scene.kind, DEMO_DURATION) }
        if @queue.last && Scenes.priority(@queue.last.kind) >= 3
          weights[-1] = [weights.last, weights[0...-1].sum].max
        end
        budget = (1.5 * @config.duration).clamp(1.0, 2.0)
        total_weight = weights.sum
        @highlight_intervals = weights.map { |weight| budget * weight / total_weight }
      end

      def complete
        @done = true
        @animation_started = nil
        safely { @engine.clear }
        return if @config.off? || @config.trail != :badge || !@last
        totals = @retired.dup
        @towers.each_value { |tower| add_totals(totals, tower.to_h) }
        last = @last.to_h
        result = case last[:outcome]
                 when "A" then last[:comeback] ? "COMEBACK" : "STAGE CLEAR"
                 when "Z" then "ABORTED"
                 when "O" then "STACK EXHAUSTED"
                 else "PARSE FINISHED"
                 end
        text = "* #{result} * #{Scenes.totals(totals)}"
        text += "  #{Career.summary(@result)}" if @result
        text += "  #{@folded_events} FOLDED" if @folded_events.positive?
        text += "  APPROXIMATE (#{totals[:discarded]} LOST)" if totals[:approximate]
        safely { @engine.badge(text, new_line: @output_open) }
      end

      def safely
        yield
      rescue StandardError => error
        Doparserb.debug(error)
      end
    end
  end
end
