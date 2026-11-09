# frozen_string_literal: true

module Doparserb
  module Gen
    class Show
      attr_reader :collector

      def initialize(bus, config:, collector: Collector.new, trace: false, engine: nil, preserve_input: false, career: nil)
        @bus = bus
        @config = config
        @collector = collector
        @trace = trace
        @preserve_input = preserve_input
        @engine = engine || Engine.new(config, preserve_input: preserve_input)
        @career = career
        @phase = "GRAMMAR"
      end

      def start
        @ready = Queue.new
        @finished = Queue.new
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          begin
            @engine.session do
              @ready << true
              collect_live
              visible = @finished.pop
              record_career
              if visible && (@collector.to_h[:success] || @collector.to_h[:failure])
                @preserve_input ? @engine.with_cancellation { present } : present
              end
            end
          rescue StandardError => error
            Doparserb.debug(error)
            @ready << true
            @collector.collect(@bus)
            record_career
          end
        end
        @ready.pop
        self
      end

      def finish(present: true)
        @finished << present if @finished
        @thread&.join
        self
      rescue StandardError => error
        Doparserb.debug(error)
        self
      end

      def self.demo(config)
        engine = Engine.new(config)
        engine.session do
          Scenes::KINDS.each do |kind|
            break if engine.cancelled?
            scene = Scenes.build(kind, Scenes::DEMO_STATS)
            engine.scene(scene.kind, title: scene.title, subtitle: scene.subtitle,
                         data: scene.data, duration: 0.6 * config.duration)
          end
          engine.badge("* DOPARSERB DEMO * ALL GENERATION SCENES")
        end
      rescue StandardError => error
        Doparserb.debug(error)
      end

      private

      def collect_live
        started = nil
        intro = 0
        loop do
          events = @bus.drain
          events.each do |event|
            @collector.consume(event)
            if event.kind == :start && !started
              started = now
              if @config.intro? && @engine.animated? && !@preserve_input
                intro = 0.6 if @config.intro != :daily || career.intro?
              end
            end
            @phase = event.info[:name].to_s.upcase.tr("_", " ") if event.kind == :phase_start
          end
          elapsed = started ? now - started : 0
          done = @bus.closed? && events.empty?
          break if done && (!started || elapsed >= intro || @engine.cancelled? || @collector.to_h[:failure])
          if started && !@preserve_input && @engine.animated? && !@engine.cancelled?
            if elapsed < intro
              scene = Scenes.build(:title, @collector.to_h)
              subtitle = if elapsed > 0.25 && !done && !@trace
                           "CHARGING  STATES #{@collector.to_h[:states]}   #{@phase}"
                         else
                           scene.subtitle
                         end
              safely { @engine.frame(:title, title: scene.title, subtitle: subtitle, progress: elapsed / intro) }
            elsif elapsed > 0.25 && !done && !@trace
              stats = @collector.to_h
              subtitle = if elapsed >= 3
                           "ELAPSED #{format('%.1f', elapsed)}s   STATES #{stats[:states]}   #{@phase}"
                         else
                           "STATES #{stats[:states]}   #{@phase}"
                         end
              if elapsed < 3 || !@meter_drawn || elapsed - @meter_drawn >= 0.25
                safely { @engine.frame(:charging, title: "CHARGING", subtitle: subtitle, progress: elapsed >= 3 ? 1.0 : elapsed % 1) }
                @meter_drawn = elapsed
              end
            end
          end
          sleep 0.02
        end
        @engine.clear
      end

      def present
        stats = @collector.to_h
        scenes = Scenes.reel(stats)
        budget = stats[:failure] ? [0.8 * @config.duration, 0.95].min : 2.5 * @config.duration
        budget = [budget, 0.75].min if @config.quick?
        deadline = now + budget
        scenes.each_with_index do |scene, index|
          break if @engine.cancelled?
          remaining = deadline - now
          break unless remaining.positive?
          safely do
            @engine.scene(scene.kind, title: scene.title, subtitle: scene.subtitle, data: scene.data,
                          duration: remaining / (scenes.length - index))
          end
        end
        safely { @engine.badge(badge(stats)) }
      end

      def career
        @career ||= Career.new(interactive: @engine.respond_to?(:enabled?) && @engine.enabled?)
      end

      def record_career
        stats = @collector.to_h
        return unless stats[:success] || stats[:failure]
        safely { stats.merge!(career.generation(stats) || {}) }
      end

      def badge(stats)
        label = if stats[:failure]
                  Scenes.build(stats[:failure][:kind], stats).title
                elsif stats[:sr_conflicts].to_i.zero? && stats[:rr_conflicts].to_i.zero? || stats[:expect_matched]
                  "FLAWLESS!!"
                else
                  "FORGED"
                end
        grammar = File.basename(stats[:grammar].to_s)
        output = File.basename(stats[:output].to_s)
        text = "* #{label} * #{grammar} -> #{output}  STATES #{stats[:states]}"
        text += "  #{Career.summary(stats)}" if stats[:score]
        text
      end

      def safely
        yield
      rescue StandardError => error
        Doparserb.debug(error)
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
