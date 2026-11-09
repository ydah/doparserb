# frozen_string_literal: true

module Doparserb
  class CLI
    SUBCOMMANDS = %w[play demo ranch status watch].freeze
    VALUE_OPTIONS = %w[--skeleton --define --report --output --trace --profile --report-file].freeze
    HELP = <<~TEXT
      Usage: doparserb [lrama options] [doparserb options] FILE

      --dopa=calm|party|off         Select generation effects
      --dopa-set KEY=VALUE,...      Set effect preferences
      --dopa-runtime=on|off        Include C runtime hooks (default: on)
      --dopa-meta=embed|sidecar     Select metadata storage (default: embed)
      --dopa-help                  Show this help

      doparserb play [--replay=highlight|full|off] [--speed=N] -- COMMAND [ARGS...]
      doparserb watch FILE [lrama options]  Rebuild on save; Ctrl-C stops watching

      Use --help for lrama options and --version for the lrama version.
      Subcommands: play, demo, ranch, status, watch
    TEXT

    def initialize(argv)
      @arguments = argv.dup
      @options = {mode: nil, runtime: "on", meta: "embed", settings: [], debug_events: false}
    end

    def run
      @subcommand = @arguments.shift if SUBCOMMANDS.include?(@arguments.first)
      @argv = @subcommand == "play" ? extract_play_options : extract_options(@arguments)
      if @options[:help] || @subcommand == "watch" && @argv == ["--help"]
        $stdout.write(HELP)
        return 0
      end
      @config = Config.new(mode: @options[:mode], settings: @options[:settings])
      return Watch.new(@argv.first, config: @config).run { |observer| generate(observer: observer) } if @subcommand == "watch"
      return Play::Launcher.new(@argv, config: @config).run if @subcommand == "play"
      if @subcommand == "demo"
        Gen::Show.demo(@config)
        Play::Show.demo(@config)
        return 0
      end
      if %w[status ranch].include?(@subcommand)
        career_command
        return 0
      end
      raise Error, "#{@subcommand} is not available yet" if @subcommand

      generate
      0
    rescue Error => error
      $stderr.puts("doparserb: #{error.message}")
      1
    end

    private

    def career_command
      if @subcommand == "status"
        raise Error, "status takes no arguments" unless @argv.empty?
      else
        raise Error, "ranch accepts only tour" unless @argv.empty? || @argv == ["tour"]
      end
      engine = Engine.new(@config)
      profile = Profile.new(interactive: engine.enabled?)
      if @subcommand == "ranch"
        Ranch.new(config: @config, engine: engine).show(owned: profile.read["llamas"], tour: @argv == ["tour"])
      elsif !profile.enabled?
        $stdout.puts("Profile storage is disabled for this session.")
      else
        state = profile.read
        $stdout.puts("LV #{state['level']}  XP #{state['xp']}  DAILY STREAK #{state['daily_streak']}")
        $stdout.puts("BEST SCORE #{state['best_score']}  CHAIN #{state['best_chain']}  TOWER #{state['highest_tower']}F")
        $stdout.puts("LLAMAS #{state['llamas'].length}/#{Game::LLAMA_COUNT}  TOKENS #{state['tokens']}")
        state["achievements"].each { |name| $stdout.puts(name.gsub(/[\x00-\x1f\x7f]/, "?")) }
      end
    end

    def extract_play_options
      delimiter = @arguments.index("--")
      raise Error, "play requires -- followed by a command" unless delimiter && delimiter < @arguments.length - 1
      options = @arguments.take(delimiter)
      command = @arguments.drop(delimiter + 1)
      until options.empty?
        argument = options.shift
        name, value = argument.split("=", 2)
        if %w[--replay --speed].include?(name)
          value ||= options.shift
          raise Error, "missing value for #{name}" if value.nil?
          raise Error, "invalid value for #{name}: #{value}" if value.include?(",")
          @options[:settings] << "#{name.delete_prefix('--')}=#{value}"
        elsif %w[--dopa --dopa-set --dopa-help].include?(name)
          if name == "--dopa-help"
            raise Error, "#{name} does not take a value" if value
            @options[:help] = true
          else
            parse_option(name, value || options.shift)
          end
        else
          raise Error, "unknown play option: #{argument}"
        end
      end
      command
    end

    def generate(observer: nil)
      present = true
      collect = observer || @options[:debug_events] || !@config.off?
      bus = EventBus.new if collect
      if bus
        collector = Gen::Collector.new
        trace = @argv.any? { |arg| arg.start_with?("--trace", "--debug", "--verbose") || arg.match?(/\A-[^-]*[tv]/) }
        begin
          show = Gen::Show.new(bus, config: @config, collector: collector, trace: trace, preserve_input: @argv.include?("-")).start
        rescue StandardError => error
          Doparserb.debug(error)
        end
      end
      command = Command.new(@argv.dup, events: bus, runtime: @options[:runtime], meta: @options[:meta])
      if show
        command.before_output = -> { Engine.program_output {} }
        Engine.active&.resume
      end
      command.run
    rescue StandardError
      present = false
      raise
    ensure
      bus&.close
      show&.finish(present: present)
      collector&.collect(bus) unless show
      begin
        observer&.call(collector.to_h)
      rescue StandardError => error
        Doparserb.debug(error)
      end
      if bus && @options[:debug_events]
        begin
          require "json"
          collector ||= Gen::Collector.new.collect(bus)
          $stderr.puts(JSON.generate(collector.to_h))
        rescue StandardError => error
          Doparserb.debug(error)
        end
      end
    end

    def extract_options(arguments)
      forwarded = []
      until arguments.empty?
        argument = arguments.shift
        if argument == "--"
          forwarded.concat([argument, *arguments])
          break
        elsif argument.start_with?("--dopa")
          name, value = argument.split("=", 2)
          if %w[--dopa-help --dopa-debug-events].include?(name)
            raise Error, "#{name} does not take a value" if value
            @options[name == "--dopa-help" ? :help : :debug_events] = true
          else
            value ||= arguments.shift
            parse_option(name, value)
          end
        else
          forwarded << argument
          forwarded << arguments.shift if takes_argument?(argument) && !arguments.empty?
        end
      end
      forwarded
    end

    def parse_option(name, value)
      raise Error, "missing value for #{name}" if value.nil?
      case name
      when "--dopa"
        raise Error, "invalid mode: #{value}" unless %w[calm party off].include?(value)
        @options[:mode] = value
      when "--dopa-runtime", "--dopa-meta"
        key = name.delete_prefix("--dopa-").to_sym
        choices = key == :runtime ? %w[on off] : %w[embed sidecar]
        raise Error, "invalid #{key}: #{value}" unless choices.include?(value)
        @options[key] = value
      when "--dopa-set"
        raise Error, "expected KEY=VALUE for --dopa-set" unless !value.empty? && value.split(",", -1).all? { |setting| setting.match?(/\A\w+=[^=,]+\z/) }
        @options[:settings] << value
      else
        raise Error, "unknown option: #{name}"
      end
    end

    def takes_argument?(argument)
      if argument.start_with?("--")
        !argument.include?("=") && VALUE_OPTIONS.count { |option| option.start_with?(argument) } == 1
      elsif argument.start_with?("-")
        short_options = argument.delete_prefix("-")
        index = short_options.index(/[SDroH]/)
        index && short_options[index] != "H" && index == short_options.length - 1
      end
    end
  end
end
