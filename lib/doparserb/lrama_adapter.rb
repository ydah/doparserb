# frozen_string_literal: true

require "lrama"

module Doparserb
  module LramaAdapter
    def self.install
      return if @installed
      Lrama::Lexer.prepend(Lexer)
      Lrama::States.prepend(States)
      Lrama::Tracer.prepend(Tracer)
      Lrama::Logger.prepend(Logger)
      Lrama::Warnings.prepend(Warnings)
      Lrama::Output.prepend(Output)
      Lrama::Grammar::Inline::Resolver.prepend(Inline)
      @installed = true
    end

    module Lexer
      def initialize(*)
        super
        @doparserb = Thread.current[:doparserb_command]
      end

      def next_token
        token = super
        @doparserb.count_token(token.first) if token && @doparserb
        token
      end
    end

    module States
      def report_duration(name)
        command = Thread.current[:doparserb_command]
        return super unless command
        before = states.length if name == :split_states
        command.emit(:phase_start, name: name)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = super
        command.emit(:phase_end, name: name, duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        command.emit(:lookahead, strength: :medium) if name == :compute_look_ahead_sets
        command.emit(:split, strength: :large, count: states.length - before) if before && states.length > before
        result
      end

      def validate!(logger)
        command = Thread.current[:doparserb_command]
        command.failure_kind = :expect_mismatch if command
        super
      end
    end

    module Tracer
      def trace_state_list_append(count, state)
        result = super
        Thread.current[:doparserb_command]&.emit(:states, count: count)
        result
      end
    end

    module Logger
      def warn(message)
        result = super
        Thread.current[:doparserb_command]&.emit(:warning, strength: :medium)
        result
      end

      def error(message)
        result = super
        Thread.current[:doparserb_command]&.emit(:error, strength: :large)
        result
      end
    end

    module Warnings
      def warn(*)
        result = super
        Thread.current[:doparserb_command]&.emit(:warnings_complete)
        result
      end
    end

    module Inline
      def resolve
        builders = super
        Thread.current[:doparserb_command]&.count_inline unless builders.empty?
        builders
      end
    end

    module Output
      def render
        command = Thread.current[:doparserb_command]
        result = if command&.runtime?
          Runtime::Weaver.new(File.read(template_file)).with_template do |path|
            @doparserb_template = path
            super
          end
        else
          super
        end
        command&.count_output(@out)
        result
      ensure
        @doparserb_template = nil
      end

      def doparserb_metadata
        Thread.current[:doparserb_command].runtime_metadata
      end

      def doparserb_parser_id
        Thread.current[:doparserb_command].runtime_parser_id
      end

      private

      def template_file
        @doparserb_template || super
      end
    end
  end

  class Command < Lrama::Command
    attr_writer :failure_kind, :before_output
    attr_reader :runtime_metadata, :runtime_parser_id

    def initialize(argv, events: nil, runtime: "on", meta: "embed")
      @events = events
      @runtime = runtime == "on"
      @meta = meta
      @token_types = Hash.new(0)
      @inline_expansions = 0
      @failure_kind = :validation_break
      LramaAdapter.install if events || @runtime
      super(argv)
    rescue SystemExit => error
      emit_failure(error) unless error.success?
      close_events
      raise
    end

    def run
      return super unless @events || @runtime
      previous = Thread.current[:doparserb_command]
      Thread.current[:doparserb_command] = self
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      emit(:start, grammar: @options.grammar_file, output: @options.outfile, stdin: @options.y.equal?(STDIN))
      result = super
      File.write("#{@options.outfile}.dopa.json", @metadata.json) if @runtime && @meta == "sidecar"
      emit(:complete, strength: :huge, success: true,
            duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      result
    rescue SystemExit, StandardError => error
      emit_failure(error) unless error.is_a?(SystemExit) && error.success?
      raise
    ensure
      if @events || @runtime
        Thread.current[:doparserb_command] = previous
        close_events
      end
    end

    def runtime?
      @runtime
    end

    def count_token(kind)
      @token_types[kind] += 1 unless @observer_failed
    rescue StandardError => error
      disable_observer(error)
    end

    def count_inline
      @inline_expansions += 1
    end

    def count_output(output)
      return if @observer_failed
      source = output.string
      lines = source.count("\n")
      lines += 1 unless source.empty? || source.end_with?("\n")
      @output_statistics = {output_bytes: source.bytesize, output_lines: lines}
    rescue StandardError => error
      disable_observer(error)
    end

    def emit(kind, strength: :small, **info)
      @events.emit(kind, strength: strength, **info) if @events && !@observer_failed
    rescue StandardError => error
      disable_observer(error)
    end

    private

    def observe
      yield if @events && !@observer_failed
    rescue StandardError => error
      disable_observer(error)
    end

    def disable_observer(error)
      @observer_failed = true
      Doparserb.debug(error)
    end

    def close_events
      @events&.close
    rescue StandardError => error
      Doparserb.debug(error)
    end

    def emit_failure(error)
      emit(@failure_kind, strength: :large, status: error.is_a?(SystemExit) ? error.status : 1, message: error.message)
    end

    def scan_complete
      return if @scan_complete
      observe do
        types = @token_types.transform_keys(&:to_s)
        emit(:scan, tokens: types.values.sum, token_types: types)
        @scan_complete = true
      end
    end

    def build_grammar(text)
      @failure_kind = :grammar_break
      grammar = super
      scan_complete
      observe do
        parameterized = grammar.parameterized_resolver.created_lhs_list.length
        features = []
        features << "ielr" if grammar.ielr_defined?
        features << "inline" if @inline_expansions.positive?
        features << "parameterized" if parameterized.positive?
        features << "repair" if @options.error_recovery
        emit(:loaded, strength: :medium, rules: grammar.rules.length, terms: grammar.terms.length,
              nterms: grammar.nterms.length, parameterized: parameterized,
              inline_expansions: @inline_expansions, features: features)
        emit(:evolve, strength: :medium, count: parameterized) if parameterized.positive?
        emit(:fusion, strength: :medium, count: @inline_expansions) if @inline_expansions.positive?
      end
      grammar
    ensure
      scan_complete
    end

    def prepare_grammar(grammar)
      @failure_kind = :validation_break
      super
    end

    def compute_status(grammar)
      @failure_kind = :validation_break
      result = super
      observe do
        states, = result
        sr = states.sr_conflicts_count
        rr = states.rr_conflicts_count
        resolved = states.states.sum { |state| state.resolved_conflicts.length }
        expected = !grammar.expect.nil? && grammar.expect == sr && rr.zero?
        emit(:conflicts, states: states.states.length, sr_conflicts: sr, rr_conflicts: rr,
              resolved_conflicts: resolved, expect: grammar.expect, expect_matched: expected)
        emit(:slash, strength: resolved >= 32 ? :large : :medium, count: resolved) if resolved.positive?
        emit(:boss, strength: :large, sr: sr, rr: rr, tamed: expected) if sr + rr > 0
        emit(:flawless, strength: :huge, expected: expected, sr: sr, rr: rr) if (sr.zero? && rr.zero?) || expected
      end
      result
    end

    def render_output(context, grammar)
      @failure_kind = :validation_break
      if @runtime
        @metadata = Runtime::Meta.new(
          grammar: @options.grammar_file, generator: "doparserb #{VERSION} / lrama #{Lrama::VERSION}",
          symbols: grammar.symbols.sort_by(&:number).map { |symbol| {id: symbol.number, name: symbol.display_name, term: symbol.term?} },
          rules: grammar.rules.map { |rule| {id: rule.id + 1, lhs: rule.lhs.number, rhs: rule.rhs.map(&:number), text: rule.as_comment} },
          states: context.yynstates
        )
        @runtime_metadata = @meta == "sidecar" ? @metadata.stub_json : @metadata.json
        @runtime_parser_id = @metadata.parser_id
      end
      yield_before_output(@options.outfile, @options.header_file)
      result = super
      observe do
        emit(:forge, strength: :large, output: @options.outfile, **@output_statistics)
        emit(:extra, kind: :header) if @options.header_file
      end
      result
    end

    def render_reports(states)
      yield_before_output(@options.report_file)
      result = super
      emit(:extra, kind: :report)
      result
    end

    def render_diagram(grammar)
      yield_before_output(@options.diagram_file) if @options.diagram
      result = super
      emit(:extra, kind: :diagram) if @options.diagram
      result
    end

    def yield_before_output(*paths)
      return unless @before_output
      paths.compact.each do |path|
        next if File.stat(path).file?
        @before_output.call
        break
      rescue Errno::ENOENT, Errno::ENOTDIR
        next
      end
    rescue StandardError => error
      Doparserb.debug(error)
    end
  end
end
