# frozen_string_literal: true

require "monitor"
require "io/console"
require "io/wait"
require "dopairb/version"
require "dopairb/config"
require "dopairb/color"
require "dopairb/term"
require "dopairb/canvas"
require "dopairb/font"
require "dopairb/stage"
require "dopairb/sound"
require "dopairb/output_tap"

module Dopairb
  def self.debug(error) = Doparserb.debug(error)
end

module Doparserb
  class Engine
    SOUND_INTERVAL = 0.03
    SOUND_QUEUE_LIMIT = 4
    SOUND_MAX_DELAY = 0.15
    SOUND_PLAYER_LIMIT = 4
    SOUND_LOCK = Mutex.new

    module SoundPatches
      def key_for(name, stretch)
        return super unless SoundBank.custom?(name)
        "doparserb-#{VERSION}-#{SoundBank::CACHE_VERSION}-#{name}-#{SoundBank.step(name, stretch)}"
      end

      def render(name, stretch, key, directory = dir)
        return super unless SoundBank.custom?(name)
        samples, impact = SoundBank.render(name, stretch, synth: Dopairb::Sound::Synth)
        FileUtils.mkdir_p(directory)
        path = File.join(directory, "#{key}.wav")
        length = samples.length.fdiv(Dopairb::Sound::RATE)
        atomic_write(path, wav(samples))
        atomic_write("#{path}.meta", "#{impact} #{length}\n")
        [path, impact, length]
      end
    end

    Dopairb::Sound.singleton_class.prepend(SoundPatches)

    class EffectOutput
      def initialize(output, no_color:)
        @output = output
        @no_color = no_color
      end

      def write(text)
        @output.write(@no_color ? text.gsub(/\e\[[\d;]*m/, "") : text)
      end
    end

    module OutputHook
      def write(*args)
        Engine.program_output { super }
      end

      def syswrite(*args)
        Engine.program_output { super }
      end

      def write_nonblock(*args, **options)
        Engine.program_output { super }
      end
    end

    module WarningHook
      def warn(*args, **options)
        Engine.program_output { super }
      end
    end

    class << self
      attr_accessor :active

      def program_output
        Dopairb::Term::LOCK.synchronize do
          begin
            active&.yield_to_output
          rescue StandardError => error
            Doparserb.debug(error)
          end
          yield
        end
      end

      def install_hooks
        return if @hooks_installed
        [STDOUT, STDERR].each { |io| io.singleton_class.prepend(OutputHook) }
        Warning.singleton_class.prepend(WarningHook)
        @hooks_installed = true
      end
    end

    attr_reader :config

    def initialize(config, output: $stderr, input: $stdin, preserve_input: false)
      @config = config
      @output = output
      @input = input
      @preserve_input = preserve_input
      @cancelled = false
      @paused = false
    end

    def enabled? = !config.off? && @output.tty? && ENV["TERM"] != "dumb"

    def animated?
      enabled? && config.motion && @animation_owner && dimensions[1] >= 24 && dimensions[0] >= 7
    end

    def session
      return yield(self) unless enabled?
      @lock = TTYLock.new(output: @output)
      @owns_terminal = @lock.acquire
      @animation_owner = @owns_terminal
      @effect_io = @output.dup
      @effect_io.sync = true
      @writer = EffectOutput.new(@effect_io, no_color: config.color == :none)
      previous_active = self.class.active
      self.class.install_hooks
      self.class.active = self
      registered = true
      unless @owns_terminal
        return yield(self)
      end
      previous = [Dopairb::Term.out, Dopairb::Term.input, Dopairb::Term.interactive?]
      Dopairb::Term.out = @writer
      Dopairb::Term.input = @output
      Dopairb::Term.interactive = true
      if config.motion && @input.tty? && !@preserve_input
        @input.raw(intr: true) { yield(self) }
      else
        yield(self)
      end
    ensure
      stop_sound
      clear
      if previous
        Dopairb::Term.out, Dopairb::Term.input, Dopairb::Term.interactive = previous
      end
      self.class.active = previous_active if registered
      @effect_io&.close
      @effect_io = nil
      @writer = nil
      @lock&.close
      @owns_terminal = false
      @animation_owner = false
    end

    def cancelled?
      return false if @preserve_input
      if !@cancelled && @input.tty? && @input.wait_readable(0)
        @cancelled = true
        silence
      end
      @cancelled
    rescue IOError, SystemCallError
      false
    end

    def with_cancellation
      previous = @preserve_input
      @preserve_input = false
      if previous && @input.tty? && enabled? && (config.motion || config.trail == :badge)
        Dopairb::Term::LOCK.synchronize do
          yield_to_output
          @writer.write("\n")
        end
      end
      if @animation_owner && config.motion && @input.tty?
        @input.raw(intr: true) { yield }
      else
        yield
      end
    ensure
      @preserve_input = previous
    end

    def wait(seconds)
      deadline = now + seconds
      while now < deadline && !cancelled?
        sleep([deadline - now, 0.02].min.clamp(0, 0.02))
      end
      !cancelled?
    end

    def frame(kind, title:, subtitle: "", progress: 1.0, data: {})
      return unless animated? && !cancelled? && !@paused
      if !@scene_sound && (data[:play] || %i[title charging].include?(kind) && @live_sound_kind != kind)
        sound(kind, data)
      end
      @live_sound_kind = kind
      if data[:play]
        timestamp = now
        return if @stage&.open? && @play_frame_at && timestamp + 1e-9 < @play_frame_at
        @play_frame_at = timestamp + 0.025
      end
      rows, cols = dimensions
      height = kind == :charging ? 1 : [rows - 2, config.intensity == :low ? 6 : 10].min
      width = [cols - 1, 120].min
      lines = render(kind, title: title, subtitle: subtitle, progress: progress, data: data, width: width, height: height)
      Dopairb::Term::LOCK.synchronize do
        return if @paused
        flash = config.flash == :full && config.color != :none && progress.between?(0.45, 0.53)
        if flash != !!@inverted
          @writer.write(flash ? "\e[?5h" : "\e[?5l")
          @inverted = flash
        end
        if !@stage&.open? || @stage.height != height
          clear
          @stage = Dopairb::Stage.new(height).open
        end
        @stage.draw(lines)
      end
    end

    def scene(kind, title:, subtitle: "", duration:, data: {})
      previous_scene = @scene_sound
      return unless animated? && !cancelled?
      resume
      @scene_sound = true
      sound(kind, data)
      started = now
      deadline = started + duration
      loop do
        progress = duration.positive? ? ((now - started) / duration).clamp(0, 1) : 1.0
        frame(kind, title: title, subtitle: subtitle, progress: progress, data: data)
        break if now >= deadline || !wait([deadline - now, 0.025].min)
      end
    rescue StandardError => error
      Doparserb.debug(error)
    ensure
      @scene_sound = previous_scene
      clear
    end

    def clear
      Dopairb::Term::LOCK.synchronize do
        restore_flash
        @stage&.close
      end
    rescue StandardError => error
      Doparserb.debug(error)
    ensure
      @stage = nil
    end

    def yield_to_output
      silence
      return unless @writer
      Dopairb::Term::LOCK.synchronize do
        @owns_terminal ||= @lock.acquire(wait: true)
        restore_flash
        @stage&.yield_to_output
        @stage = nil
        @paused = true
      end
    end

    def resume
      Dopairb::Term::LOCK.synchronize { @paused = false }
    end

    def silence = stop_sound

    def badge(text, new_line: false)
      return unless enabled? && config.trail == :badge
      return unless @owns_terminal || (@owns_terminal = @lock.acquire(wait: true))
      clear
      text = crop(text, dimensions[1] - 1)
      Dopairb::Term::LOCK.synchronize { @writer.write("#{new_line ? "\n" : ""}#{text}\n") }
    end

    def render(kind, title:, subtitle:, progress:, data:, width:, height:)
      return [crop("#{title}  #{subtitle}", width)] if kind == :charging
      return render_ranch(kind, title, subtitle, progress, data, width, height) if %i[ranch llama_drop].include?(kind)
      return render_tower(kind, title, subtitle, progress, data, width, height) if data[:play]
      canvas = Dopairb::Canvas.new(width, height)
      color = palette(kind, progress)
      canvas.put_center(0, crop(title, width), color, bold: true)
      if config.flash != :off && progress.between?(0.45, 0.53) && config.color != :none
        canvas.fill_bg(Dopairb::Color.scale(color, 0.18))
      end
      draw_art(canvas, kind, progress, color, data)
      if %i[title flawless finale states record jackpot].include?(kind) && height >= 9
        word = case kind
               when :title then "DOPARSERB"
               when :states then (data[:states].to_i * progress).ceil.to_s
               when :finale then "CLEAR!"
               when :jackpot then "7 7 7"
               else title.delete("!")
               end
        draw_font(canvas, word, progress, color) if Dopairb::Font.width(word) <= width - 2
      end
      text = crop(subtitle, subtitle.length)
      offset = ([text.length - width * 2, 0].max * progress).floor
      footer = text[offset, width * 2].scan(/.{1,#{[width, 1].max}}/)
      footer.first(2).each_with_index { |line, index| canvas.put_center(height - 2 + index, line, color) }
      canvas.render(depth).map { |line| crop(line, width) }
    end

    private

    def render_ranch(kind, title, subtitle, progress, data, width, height)
      canvas = Dopairb::Canvas.new(width, height)
      canvas.put_center(0, crop(title, width), Dopairb::Color::GOLD[1], bold: true)
      ids = kind == :llama_drop ? [data.fetch(:id) { data.fetch(:llama_id, 0) }] : data.fetch(:ids, [])
      owned = data.fetch(:owned, ids)
      count = [ids.size, [width / 24, 1].max, 3].min
      unless count.zero?
        cell_width = width / count
        tick = data.fetch(:tick) { (progress * 20).floor }
        ids.rotate((progress * ids.size).floor % ids.size).first(count).each_with_index do |id, index|
          ascii = %w[▀ ▄ █].any? { |glyph| Dopairb::Term.glyph(glyph, "#") != glyph }
          lines = Ranch.render(id: id, width: cell_width, owned: owned.include?(id), tick: tick, ascii: ascii)
          color = owned.include?(id) ? [[240, 235, 220], [230, 165, 65], [225, 120, 155], [125, 155, 185]][id / 16] : [95, 95, 95]
          lines.first([height - 2, 0].max).each_with_index do |line, row|
            canvas.put(index * cell_width, row + 1, line, color)
          end
        end
      end
      canvas.put_center(height - 1, crop(subtitle, width), Dopairb::Color::GOLD[1])
      canvas.render(depth).map { |line| crop(line, width, trusted_pixels: true) }
    end

    def render_tower(kind, title, subtitle, progress, data, width, height)
      canvas = Dopairb::Canvas.new(width, height)
      fever = data.dig(:game, :fever)
      color = fever ? Dopairb::Color.rainbow(data[:game][:combo].fdiv(12) % 1) : palette(kind, progress)
      canvas.put(0, 0, crop("STACK TOWER", width), color, bold: true)
      preview_width = [width / 3, 20].min
      preview_left = width - preview_width
      canvas.put(preview_left, 0, "NEXT", color, bold: true)
      canvas.put(preview_left, 1, crop(data.dig(:next_token, :label) || "-", preview_width), color)
      canvas.put(0, 1, crop("DEPTH #{data[:depth]}F", preview_left - 1), color)
      hud = "CHAIN #{data[:chain]}"
      hud += "  COMBO #{data[:game][:combo]}#{fever ? '  FEVER!' : ''}" if data[:game]
      canvas.put(0, 2, crop(hud, width), color, bold: true)
      floor = height - 3
      blocks = data.fetch(:blocks, []).last([floor - 2, 0].max)
      block_width = [preview_left - 2, 28].min.clamp(4, [width, 4].max)
      blocks.reverse_each.with_index do |block, index|
        row = floor - blocks.size + index + 1
        label = crop(block[:label] || (block[:sym] ? "SYM #{block[:sym]}" : "RULE #{block[:rule]}"), block_width - 4)
        block_color = Dopairb::Color.rainbow((block[:sym] || block[:rule]).to_i.fdiv(11) % 1)
        canvas.put(1, row, crop("[ #{label.ljust(block_width - 4)} ]", width - 1), block_color, bold: true)
      end
      effect = case kind
               when :shift, :tower_milestone then "* + *"
               when :reduce, :chain then "-> * <-"
               when :from_nothing then "+ * +"
               when :syntax_break, :collapse then "/ ! \\"
               when :recovery then "[ERROR]"
               when :repair_plan, :inserted, :auto_repair then "+ -> []"
               when :stage_clear, :comeback then "* ^ *"
               when :critical then "/ x#{data.fetch(:multiplier, 4)} /"
               when :jackpot then "7 7 7"
               else ""
               end
      canvas.put(preview_left, 3, crop(effect, preview_width), color)
      canvas.put_center(height - 2, crop(title, width), color, bold: true)
      canvas.put_center(height - 1, crop(subtitle, width), color)
      canvas.render(depth).map { |line| crop(line, width) }
    end

    def restore_flash
      @writer.write("\e[?5l") if @inverted
    ensure
      @inverted = false
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def dimensions
      rows, cols = @output.winsize
      [rows.positive? ? rows : 24, cols.positive? ? cols : 80]
    rescue NoMethodError, IOError, SystemCallError
      [24, 80]
    end

    def depth = Dopairb::Term.depth(config)

    def crop(text, width, trusted_pixels: false)
      remaining = [width, 0].max
      text.to_s.scan(/\e\[[\d;]*m|./).filter_map do |part|
        if part.start_with?("\e[")
          part unless config.color == :none
        elsif remaining.positive?
          remaining -= 1
          if part.ascii_only? && part.ord.between?(32, 126)
            part
          elsif trusted_pixels && %w[▀ ▄ █].include?(part)
            Dopairb::Term.glyph(part, "#")
          else
            "?"
          end
        end
      end.join
    end

    def palette(kind, progress)
      return Dopairb::Color.rainbow(progress) if %i[flawless finale jackpot record stage_clear comeback].include?(kind)
      case kind
      when :grammar_break, :expect_mismatch, :validation_break, :boss, :syntax_break, :collapse, :aborted, :exhausted then Dopairb::Color::BLOOD[1]
      when :forge, :warning, :critical then Dopairb::Color::GOLD[1]
      when :evolve, :fusion, :new_ability, :repair_plan, :inserted, :auto_repair, :recovery then Dopairb::Color::NEON[1]
      else Dopairb::Color::ICE[1]
      end
    end

    def draw_font(canvas, text, progress, color)
      left = (canvas.w - Dopairb::Font.width(text)) / 2
      top = 2 - ((1 - progress) * 2).round
      Dopairb::Font.bitmap(text).each_with_index do |row, y|
        row.each_with_index { |pixel, x| canvas.put(left + x, top + y, "#", color) if pixel }
      end
    end

    def draw_art(canvas, kind, progress, color, data)
      middle = canvas.w / 2
      row = [3, canvas.h - 3].min
      tick = (progress * 20).to_i
      case kind
      when :title
        x = ((canvas.w - 9) * progress).to_i
        canvas.put(x, 6, " /|_/|", color)
        canvas.put(x, 7, "( oo )___", color)
      when :scan
        tokens = %w[%token ID NUMBER %% expr : term + expr ;]
        canvas.put(1, row, tokens.rotate(tick % tokens.size).join(" "), color)
        canvas.put((canvas.w * progress).to_i, row - 1, "*", color)
      when :loaded
        ["[ RULES #{data[:rules]} ]", "[ TERMS #{data[:terms]} ]", "[ NTERMS #{data[:nterms]} ]"].first(1 + (progress * 2).round).each_with_index do |line, index|
          canvas.put_center(row - 1 + index, line, color, bold: true)
        end
      when :evolve, :fusion, :split
        offset = kind == :split ? (progress * 12).to_i : ((1 - progress) * 12).to_i
        canvas.put(middle - offset - 6, row, "[RULE]", color)
        canvas.put(middle + offset, row, kind == :evolve ? "[EXPR]" : "[RULE]", color)
        canvas.put_center(row + 1, kind == :split ? "<-- + -->" : "--> * <--", color)
      when :lookahead
        3.times { |y| canvas.put_center(row - 1 + y, "[00] [01] [10] [11] [??]", color) }
        canvas.put((canvas.w * progress).to_i.clamp(0, canvas.w - 1), row, "|", [255, 255, 255])
      when :slash, :critical
        [canvas.w, 1].max.times do |x|
          y = row + ((x - middle) / 8.0).round
          canvas.put(x, y, "/", color) if x <= canvas.w * progress
        end
        canvas.put_center(row, "x#{data[:resolved_conflicts] || data[:multiplier] || 4}", color, bold: true)
      when :boss, :expect_mismatch
        [" /\\    /\\ ", "(  >  <  )", " \\  /\\  / "].each_with_index { |line, index| canvas.put_center(row - 1 + index, line, color) }
        hp = data[:sr_conflicts].to_i + data[:rr_conflicts].to_i
        canvas.put_center(row + 2, "HP #{hp} [#{'=' * (12 * (1 - progress)).ceil}#{' ' * (12 * progress).floor}]", color)
      when :forge, :extra
        ["   [==]", "     |    *", "  =========", "    /___\\"].each_with_index { |line, index| canvas.put_center(row - 1 + index, line, color) }
      when :warning
        ["   /!\\", "  / ! \\", " /_____\\"].each_with_index { |line, index| canvas.put_center(row - 1 + index, line, color) }
      when :new_ability
        canvas.put_center(row, "[ + ]  UNLOCKED  [ + ]", color, bold: true)
      when :grammar_break, :validation_break
        4.times { |y| canvas.put(middle + (y.even? ? -1 : 1), row - 1 + y, y.even? ? "/" : "\\", color) }
        canvas.put_center(row + 1, "<  !  >", color)
      else
        count = {low: 4, normal: 10, max: 16}.fetch(config.intensity, 4)
        count.times do |i|
          angle = i * Math::PI * 2 / count
          x = middle + Math.cos(angle) * progress * (canvas.w / 2 - 2)
          y = row + Math.sin(angle) * progress * 2
          canvas.put(x, y, i.even? ? "*" : "+", Dopairb::Color.rainbow(i.fdiv(count)))
        end
      end
    end

    def sound(kind, data = {})
      return if config.sound == :off
      return unless @writer && @animation_owner && !@paused && !cancelled?
      name, step = SoundBank.selection(kind, data)
      timestamp = now
      @last_sound ||= {}
      return if @last_sound[name] && timestamp - @last_sound[name] + 1e-9 < SOUND_INTERVAL
      @last_sound[name] = timestamp
      return ring_bell if config.sound == :bell

      unless @audio_queue
        return if @audio_thread&.alive?
        @sound_players ||= []
        @sound_player_lock ||= Mutex.new
        queue = @audio_queue = SizedQueue.new(SOUND_QUEUE_LIMIT)
        @audio_thread = Thread.new do
          Thread.current.report_on_exception = false
          while (job = queue.pop)
            dispatch_sound(queue, *job)
          end
        end
      end
      @audio_queue.push([name, step, timestamp], true)
    rescue ThreadError
      nil
    rescue StandardError => error
      Doparserb.debug(error)
    end

    def sound_backend = Dopairb::Sound

    def dispatch_sound(queue, name, step, timestamp)
      return if queue.closed? || now - timestamp > SOUND_MAX_DELAY
      backend = sound_backend
      kind, arguments = backend.backend
      return if queue.closed? || now - timestamp > SOUND_MAX_DELAY
      return ring_bell unless kind
      @sound_player_lock.synchronize do
        @sound_players.select! { |pid| sound_player_running?(pid) }
        return if @sound_players.length >= SOUND_PLAYER_LIMIT
      end
      path, = SOUND_LOCK.synchronize { backend.file(name, step) }
      return if queue.closed? || now - timestamp > SOUND_MAX_DELAY || @paused || cancelled?
      if kind == :log
        backend.log_play(arguments.first, name, 0, step)
        return
      end
      arguments = sound_player_arguments(kind, arguments, path)
      return if queue.closed? || now - timestamp > SOUND_MAX_DELAY || @paused || cancelled?
      pid = spawn_sound_player(arguments)
      @sound_player_lock.synchronize do
        queue.closed? ? stop_sound_player(pid) : @sound_players << pid
      end
    rescue StandardError => error
      Doparserb.debug(error)
    end

    def ring_bell
      Dopairb::Term::LOCK.synchronize do
        @writer.write("\a") if @writer && @animation_owner && !@paused && !cancelled?
      end
    end

    def stop_sound
      @audio_queue&.clear
      @audio_queue&.close
      @audio_queue = nil
      @sound_player_lock&.synchronize do
        @sound_players.each { |pid| stop_sound_player(pid) }
        @sound_players.clear
      end
    end

    def spawn_sound_player(arguments)
      Dopairb::OutputTap.quietly do
        Process.spawn(*arguments, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
      end
    end

    def sound_player_arguments(kind, arguments, path)
      return arguments + [path] unless kind == :slow
      path = Dopairb::OutputTap.quietly { IO.popen(["wslpath", "-w", path], &:read) }.strip
      arguments + ["(New-Object Media.SoundPlayer '#{path.gsub("'", "''")}').PlaySync()"]
    end

    def sound_player_running?(pid)
      !Process.waitpid(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      false
    end

    def stop_sound_player(pid)
      running = sound_player_running?(pid)
      return unless running
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    rescue SystemCallError => error
      Doparserb.debug(error)
    ensure
      if running
        begin
          Process.detach(pid)
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end
end
