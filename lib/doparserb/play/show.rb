# frozen_string_literal: true

module Doparserb
  module Play
    class Show
      MAX_PENDING = 2048
      MAX_TOWERS = 128
      HIGHLIGHT_FRAMES = 12
      ANIMATION_DURATION = 0.35
      DEMO_DURATION = 0.55
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
            scene = Scenes.build(kind, Scenes::DEMO_STATS)
            engine.scene(kind, title: scene.title, subtitle: scene.subtitle, data: scene.data, duration: DEMO_DURATION * config.duration)
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
            interval = @interval || (@config.replay == :full ? 1.0 / @config.speed : 0.025)
            @animation_started = nil
            safely do
              names = @names[scene.data[:event].values_at(:parser, :pid, :parse_id)]
              scene = Scenes.relabel(scene, names) if names
              tween = @engine.respond_to?(:animate)
              @engine.frame(scene.kind, title: scene.title, subtitle: scene.subtitle, data: scene.data, progress: tween ? 0.0 : 1.0)
              if tween
                @animation_started = now
                duration = ANIMATION_DURATION * @config.duration
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
        @interval = (1.5 * @config.duration).clamp(1.0, 2.0) / [@queue.length, 1].max
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
