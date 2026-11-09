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
require "dopairb/fx"
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
    ART_GLYPHS = /[\u2580-\u259f\u2800-\u28ff]/
    INK = [9, 14, 30].freeze
    CYAN = [61, 232, 255].freeze
    PINK = [255, 79, 163].freeze
    GOLD = [255, 212, 92].freeze
    MINT = [112, 242, 176].freeze
    VIOLET = [155, 123, 255].freeze
    PLAY_IMPACT = {shift: 0.58, reduce: 0.52, chain: 0.52, from_nothing: 0.52,
                   recovery: 0.62, repair_plan: 0.62, inserted: 0.62, auto_repair: 0.62}.freeze
    REEL_STOPS = [0.20, 0.38, 0.58].freeze

    # Braille is Unicode-neutral; ambiguous block widths retain the upstream fallback.
    original_width = Dopairb::Term.method(:char_width)
    Dopairb::Term.singleton_class.remove_method(:char_width)
    Dopairb::Term.define_singleton_method(:char_width) do |char|
      !defined?(Reline::Unicode) && char.match?(/[\u2800-\u28ff]/) ? 1 : original_width.call(char)
    end
    Dopairb::Term.reset_glyphs

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
      @animation_frame = {kind: kind, title: title, subtitle: subtitle, data: data} if data[:play]
      paint_frame(kind: kind, title: title, subtitle: subtitle, progress: progress, data: data, audio: true)
    end

    def animate(progress:)
      return unless @animation_frame
      paint_frame(**@animation_frame, progress: progress, audio: false)
    end

    def paint_frame(kind:, title:, subtitle: "", progress: 1.0, data: {}, audio: false)
      return unless animated? && !cancelled? && !@paused
      if audio && !@scene_sound && (data[:play] || %i[title charging].include?(kind) && @live_sound_kind != kind)
        @impact_sound = nil
        if data[:play] && PLAY_IMPACT.key?(kind)
          @impact_sound = [kind, data]
        else
          sound(kind, data)
        end
      end
      if @impact_sound && progress >= PLAY_IMPACT.fetch(@impact_sound.first)
        sound(*@impact_sound)
        @impact_sound = nil
      end
      @live_sound_kind = kind
      if data[:play]
        timestamp = now
        return if @stage&.open? && @play_frame_at && timestamp + 1e-9 < @play_frame_at
        @play_frame_at = timestamp + 0.025
      end
      rows, cols = dimensions
      height = kind == :charging ? 1 : [rows - 2, config.intensity == :low ? 6 : data[:play] ? 16 : 18].min
      width = [cols - 1, 120].min
      lines = render(kind, title: title, subtitle: subtitle, progress: progress, data: data, width: width, height: height)
      Dopairb::Term::LOCK.synchronize do
        return if @paused
        impact = data[:play] ? play_impact(kind) : 0.45
        flash = config.flash == :full && config.color != :none && progress.between?(impact, impact + 0.08)
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
      @impact_sound = nil
      impact = data[:play] ? PLAY_IMPACT.fetch(kind, 0) : 0
      sounded = false
      started = now
      deadline = started + duration
      loop do
        progress = duration.positive? ? ((now - started) / duration).clamp(0, 1) : 1.0
        if !sounded && progress >= impact
          sound(kind, data)
          sounded = true
        end
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

    def silence
      @impact_sound = nil
      stop_sound
    end

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
      backdrop(canvas, kind, progress)
      word = case kind
             when :title then "DOPARSERB"
             when :states then (data[:states].to_i * Dopairb::Fx.ease_out(progress)).ceil.to_s
             when :finale then data[:rank] ? "RANK #{data[:rank]}" : "CLEAR!"
             when :flawless then "FLAWLESS"
             when :grammar_break then "BREAK"
             when :expect_mismatch then "EXPECT"
             when :new_ability then "UNLOCK"
             when :achievement then "UNLOCKED"
             when :jackpot then "JACKPOT"
             when :boss then "BOSS"
             else title.delete("!")
             end
      draw_art(canvas, kind, progress, data, height >= 14 ? 8 : 3)
      headline(canvas, word, progress, y: 2, color: palette(kind, progress)) if height >= 14 && width >= 40
      header(canvas, title, kind, progress)
      footer(canvas, subtitle, progress)
      finish_canvas(canvas)
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
      impact = play_impact(kind)
      backdrop(canvas, kind, progress, impact: impact)
      fever = data.dig(:game, :fever)
      color = fever ? Dopairb::Color.rainbow(data[:game][:combo].fdiv(12) % 1) : palette(kind, progress)
      preview_width = [width / 3, 24].min
      preview_left = width - preview_width
      hud = "CHAIN #{data[:chain]}"
      hud += "  COMBO #{data[:game][:combo]}#{fever ? '  FEVER!' : ''}" if data[:game]
      floor = height - 3
      blocks = data.fetch(:blocks, []).last([floor - 3, 1].max)
      block_width = [width >= 64 ? width / 2 - 5 : preview_left - 2, 30].min.clamp(4, [width, 4].max)
      left = width >= 64 ? 3 : 1
      canvas.put(left, floor, "=" * block_width, VIOLET)
      panel_left = width >= 64 ? width / 2 : preview_left
      panel_width = width - panel_left
      hit = Dopairb::Fx.phase(progress, impact, 1)
      if progress >= impact && !%i[next tower].include?(kind)
        burst(canvas, left + block_width / 2, [floor - blocks.size, 4].max, hit, color: color)
      end
      if width >= 64 && height >= 12
        play_panel(canvas, kind, progress, data, panel_left, panel_width, color)
      else
        canvas.put(panel_left, 4, crop(kind.to_s.upcase.tr("_", " "), panel_width), color, bold: true)
      end
      blocks.reverse_each.with_index do |block, index|
        row = floor - blocks.size + index
        row -= ((1 - Dopairb::Fx.ease_in([progress / impact, 1].min)) * 3).round if index.zero? && kind == :shift
        row = [row, 3].max
        label = crop(block[:label] || (block[:sym] ? "SYM #{block[:sym]}" : "RULE #{block[:rule]}"), block_width - 4)
        block_color = Dopairb::Color.rainbow((block[:sym] || block[:rule]).to_i.fdiv(11) % 1, 0.65)
        displacement = %i[reduce chain].include?(kind) && index.zero? ? ((1 - Dopairb::Fx.ease_out(progress)) * 4).round : 0
        canvas.put(left + displacement, row, "[ #{label.ljust(block_width - 4)} ]",
                   [250, 250, 255], bg: Dopairb::Color.scale(block_color, 0.5), bold: true)
        canvas.put(left + displacement, row, ">", block_color, bold: true)
        canvas.put(left + block_width - 1 + displacement, row, "<", block_color, bold: true)
      end
      3.times { |row| canvas.put(0, row, " " * width, nil, bg: INK) }
      canvas.put(0, 0, "STACK TOWER", GOLD, bold: true)
      canvas.put(preview_left, 0, "NEXT", CYAN, bold: true)
      canvas.put(preview_left, 1, crop(data.dig(:next_token, :label) || "-", preview_width), MINT, bold: true)
      canvas.put(0, 1, crop("DEPTH #{data[:depth]}F", preview_left - 1), color)
      canvas.put(0, 2, crop(hud, width >= 64 ? preview_left - 1 : width), PINK, bold: true)
      if width >= 64
        chain = data[:chain].to_i
        target = Game::CHAIN_BONUSES.keys.find { |step| step > chain }
        fill = target ? (chain.fdiv(target) * 6).floor : 6
        meter = "#{target ? "CHAIN ->#{target}" : 'CHAIN MAX'} [#{'=' * fill}#{'.' * (6 - fill)}]"
        canvas.put(preview_left, 2, meter, target ? VIOLET : GOLD, bold: true)
      end
      2.times { |row| canvas.put(0, height - 2 + row, " " * width, nil, bg: INK) }
      if kind == :jackpot && progress < REEL_STOPS.last
        title = progress < REEL_STOPS[1] ? "BONUS CHANCE" : "LAST REEL..."
        subtitle = "HOLD...  HOLD..."
      elsif kind == :critical && progress < 0.22
        title, subtitle = "CHARGE...", ""
      elsif PLAY_IMPACT.key?(kind) && progress < impact
        subtitle = case kind
                   when :shift then "TOKEN IN FLIGHT"
                   when :reduce, :chain, :from_nothing then "RULE #{data.dig(:event, :rule)}   #{data.dig(:event, :len)} BLOCKS -> ?"
                   else "RECONNECTING PARSER STACK"
                   end
      end
      canvas.put_center(height - 2, crop(title, width), color, bold: true)
      canvas.put_center(height - 1, crop(subtitle, width), CYAN)
      finish_canvas(canvas)
    end

    def play_impact(kind)
      return REEL_STOPS.last if kind == :jackpot
      return 0.22 if kind == :critical
      PLAY_IMPACT.fetch(kind, 0.35)
    end

    def play_panel(canvas, kind, progress, data, left, width, color)
      center = left + width / 2
      floor = canvas.h - 3
      target = [floor - 4, 4].max
      impact = play_impact(kind)
      hit = Dopairb::Fx.phase(progress, impact, 1)
      case kind
      when :next
        token_capsule(canvas, center, target, data.dig(:next_token, :label) || "TOKEN", CYAN)
        panel_caption(canvas, left, width, "NEXT / LOOKAHEAD", CYAN)
      when :shift
        falling = Dopairb::Fx.ease_in(Dopairb::Fx.phase(progress, 0.18, impact))
        y = (4 + (target - 4) * falling).round
        label = data[:symbol_label] || data.dig(:next_token, :label) || data[:blocks].last&.dig(:label) || "TOKEN"
        caption = progress < 0.18 ? "SHIFT / READY" : progress < impact ? "SHIFT / DROP" : "SHIFT / LANDED"
        if progress < impact
          (4...y).each do |row|
            canvas.put(center - 10, row, ":", Dopairb::Color.scale(CYAN, 0.5))
            canvas.put(center + 10, row, "|", CYAN)
          end
        else
          burst(canvas, center, floor - 1, hit, color: CYAN)
        end
        canvas.put(center - 12, floor, "__\\___________/__________", VIOLET)
        token_capsule(canvas, center, y, label, CYAN, squash: progress.between?(impact, impact + 0.12))
        panel_caption(canvas, left, width, caption, CYAN)
      when :reduce, :chain, :from_nothing
        count = data.dig(:event, :len).to_i
        if progress < impact
          spread = (width / 2 - 8) * (1 - Dopairb::Fx.ease_in(progress / impact))
          shown = count.clamp(1, 3)
          shown.times do |index|
            offset = shown == 1 ? 0 : (index.fdiv(shown - 1) * 2 - 1) * spread
            token_capsule(canvas, center + offset.round, target, count.zero? ? "EMPTY" : "RHS #{index + 1}",
                          [CYAN, PINK, VIOLET][index], size: 10)
          end
          canvas.put(center - 8, 5, ">>>   FUSE   <<<", GOLD, bold: true)
        else
          burst(canvas, center, target + 1, hit, color: GOLD)
          label = data[:blocks].last&.dig(:label) || "RULE #{data.dig(:event, :rule)}"
          token_capsule(canvas, center, target, label, GOLD)
          if kind == :chain
            headline(canvas, "#{data[:chain]} CHAIN", hit, y: 4, left: left, width: width, half: true, color: GOLD)
          else
            gain = data.dig(:game, :points) || 10 * count
            canvas.put(center - 8, 6, "#{count} -> 1   +#{(gain * Dopairb::Fx.ease_out(hit)).round}", GOLD, bold: true)
          end
        end
        panel_caption(canvas, left, width, progress < impact ? "REDUCE / COLLIDE" : "REDUCE / FUSED", GOLD)
      when :recovery, :repair_plan, :inserted, :auto_repair
        closed = Dopairb::Fx.ease_out(Dopairb::Fx.phase(progress, 0.18, impact))
        y = (4 + (target - 4) * closed).round
        span = ((1 - closed) * 5).round
        canvas.put(center - 15, floor - 1, progress < impact ? "========//          \\\\========" : "==============================", MINT)
        (4...y).each { |row| canvas.put(center, row, "||", CYAN) }
        canvas.put(center - 10 - span, y + 1, ">>", MINT, bold: true)
        canvas.put(center + 9 + span, y + 1, "<<", MINT, bold: true)
        label = case kind
                when :recovery then "error"
                when :repair_plan then "+#{data.dig(:event, :n)} TOKENS"
                when :inserted then data[:symbol_label] || "TOKEN"
                else "PATCH"
                end
        burst(canvas, center, floor - 1, hit, color: MINT) if progress >= impact
        token_capsule(canvas, center, y, label, MINT)
        if progress >= impact
          canvas.put(center - 14 + (hit * 28).round, floor, "*", [255, 255, 255], bold: true)
        end
        panel_caption(canvas, left, width, progress < impact ? "RECOVERY / CATCH" : "RECOVERY / REJOIN", MINT)
      when :jackpot
        jackpot_panel(canvas, progress, data, left, width)
      when :critical
        if progress < 0.22
          head = left + width * progress / 0.22
          7.times { |row| canvas.put(head - row * 2, 4 + row, "\\\\", [255, 255, 255], bold: true) }
        else
          phase = Dopairb::Fx.phase(progress, 0.22, 1)
          burst(canvas, center, 7, phase, color: PINK)
          headline(canvas, "X#{data[:multiplier] || 4}", phase, y: 5, left: left, width: width, color: PINK)
          canvas.put(center - 7, floor - 1, "+#{((data.dig(:game, :points) || 0) * Dopairb::Fx.ease_out(phase)).round}  CRITICAL", GOLD, bold: true)
        end
        panel_caption(canvas, left, width, progress < 0.22 ? "CHARGE..." : "CRITICAL!!", PINK)
      else
        celebration = %i[stage_clear comeback token_milestone].include?(kind)
        if celebration && progress >= 0.28
          3.times { |index| burst(canvas, canvas.w * (index + 1) / 4, 5 + index % 2, (hit + index * 0.2) % 1, color: [GOLD, PINK, CYAN][index]) }
        end
        label = case kind
                when :stage_clear then "CLEAR"
                when :comeback then "BACK!"
                when :syntax_break, :collapse, :exhausted, :aborted then "BREAK"
                when :tower_milestone then "#{data[:max_depth]}F"
                when :token_milestone then "#{data[:tokens].to_i / 1000}K"
                else kind.to_s.upcase.tr("_", " ")
                end
        headline(canvas, label, progress, y: 4, left: left, width: width, half: true, color: color)
        draw_sprite(canvas, celebration ? :trophy : :boss, center, 9, progress, limit: canvas.h - 11)
      end
    end

    def panel_caption(canvas, left, width, text, color)
      canvas.put(left, 3, " " * width, nil, bg: INK)
      canvas.put(left + (width - text.length) / 2, 3, text, color, bold: true)
    end

    def token_capsule(canvas, center, y, label, color, size: 16, squash: false)
      label = crop(label, size - 2).center(size - 2)
      rows = if squash
               [".#{'=' * size}.", "| #{label} |", "'#{'=' * size}'"]
             else
               [" .#{'-' * size}.", "/#{'_' * size}/|", "| #{label} ||", "|#{'_' * size}|/"]
             end
      left = center - (size + 3) / 2
      rows.each_with_index do |line, row|
        canvas.put(left, y + row, line, row == 2 || squash ? [255, 255, 255] : color,
                   bg: Dopairb::Color.scale(color, row == 2 ? 0.25 : 0.10), bold: true)
      end
    end

    def jackpot_panel(canvas, progress, data, left, width)
      won = progress >= REEL_STOPS.last
      phase = Dopairb::Fx.phase(progress, REEL_STOPS.last, 1)
      if won
        24.times do |index|
          x = (index * 17 + 3) % canvas.w
          y = 4 + ((index * 3 + phase * 12) % [canvas.h - 7, 1].max)
          canvas.put(x, y, index.even? ? "$" : "o", [GOLD, PINK, CYAN][index % 3], bold: true)
        end
        burst(canvas, left + width / 2, 7, phase, color: GOLD)
      end
      if canvas.h >= 16 && progress < 0.78
        origin = left + (width - 31) / 2
        33.times do |index|
          color = (index + (progress * 24).to_i).even? ? GOLD : VIOLET
          canvas.put(origin - 1 + index, 4, "o", color, bold: true)
          canvas.put(origin - 1 + index, 10, "o", color, bold: true)
        end
        REEL_STOPS.each_with_index do |stop, index|
          stopped = progress >= stop
          symbol = stopped ? "7" : %w[3 8 2 5 9][((progress * 32).floor + index * 2) % 5]
          x = origin + index * 11
          5.times { |row| canvas.put(x, 5 + row, " " * 9, nil, bg: [235, 230, 220]) }
          ink = stopped ? [210, 30, 80] : [105, 95, 120]
          Dopairb::Fx.big_text(canvas, symbol, x + 2, 5, ->(*) { ink }, bg_fn: ->(*) { ink })
        end
      elsif won && canvas.h >= 16
        headline(canvas, "777", phase, y: 5, left: left, width: width, color: GOLD)
      else
        reels = REEL_STOPS.map.with_index { |stop, index| "[#{progress >= stop ? 7 : (progress * 30 + index).to_i % 10}]" }.join(" ")
        canvas.put(left + (width - reels.length) / 2, 5, reels, GOLD, bold: true)
      end
      caption = won ? "JACKPOT!! x#{data[:multiplier] || 16}" : progress >= REEL_STOPS[1] ? "LAST REEL..." : "BONUS CHANCE"
      panel_caption(canvas, left, width, caption, won ? GOLD : VIOLET)
      if won
        gain = ((data.dig(:game, :points) || 0) * Dopairb::Fx.ease_out(phase)).round
        canvas.put(left + width / 2 - 3, canvas.h - 4, "+#{gain}", GOLD, bold: true)
      end
    end

    def backdrop(canvas, kind, progress, impact: 0.45)
      color = palette(kind, progress)
      canvas.h.times do |row|
        canvas.fill_bg(Dopairb::Color.mix(INK, color, 0.04 + row.fdiv([canvas.h, 1].max) * 0.07), 0, row, canvas.w, 1)
      end
      count = config.intensity == :low || PLAY_IMPACT.key?(kind) || kind == :next ? 4 : 18
      Dopairb::Fx.sparkles(canvas, progress, kind.to_s.bytes.sum, count,
                           palette: [CYAN, PINK, GOLD, VIOLET], area: [0, 2, canvas.w, [canvas.h - 4, 1].max])
      if config.flash != :off && progress.between?(impact, impact + 0.08) && config.color != :none
        canvas.tint_bg(color, 0.2)
      end
    end

    def header(canvas, title, kind, progress)
      canvas.put(0, 0, " " * canvas.w, nil, bg: INK)
      text = crop(title, canvas.w - 4)
      canvas.put_center(0, text, GOLD, bold: true)
      canvas.put(0, 0, ">>", palette(kind, progress))
      canvas.put(canvas.w - 2, 0, "<<", PINK)
    end

    def footer(canvas, subtitle, progress)
      text = crop(subtitle, subtitle.to_s.length)
      offset = ([text.length - canvas.w * 2, 0].max * progress).floor
      lines = text[offset, canvas.w * 2].scan(/.{1,#{canvas.w}}/)
      2.times { |row| canvas.put(0, canvas.h - 2 + row, " " * canvas.w, nil, bg: INK) }
      lines.first(2).each_with_index do |line, index|
        canvas.put_center(canvas.h - 2 + index, line, index.zero? ? GOLD : CYAN)
      end
    end

    def gradient_text(canvas, x, y, text, progress = 0)
      text.each_char.with_index do |char, index|
        canvas.put(x + index, y, char, Dopairb::Color.rainbow(index.fdiv([text.size, 1].max) * 0.6 + progress * 0.15), bold: true)
      end
    end

    def headline(canvas, text, progress, y:, color:, left: 0, width: canvas.w, half: false)
      text = crop(text, width)
      scale = half ? 1 : Dopairb::Fx.best_scale(text, width - 4)
      pixel_width = Dopairb::Font.width(text)
      return unless scale && pixel_width * scale <= width - 2
      x = left + (width - pixel_width * scale) / 2
      y -= ((1 - Dopairb::Fx.ease_out([progress * 3, 1].min)) * 2).round
      ink = ->(_x, row, fraction) { Dopairb::Color.mix(Dopairb::Color.rainbow(fraction * 0.65 + progress * 0.1), color, row * 0.05) }
      background = ->(col, row) { ink.call(col, row, col.fdiv([pixel_width - 1, 1].max)) } unless config.color == :none
      if half
        return if Dopairb::Fx.half_text(canvas, text, x, y, ink)
        Dopairb::Fx.big_text(canvas, text, x, y, ink, bg_fn: background)
      else
        if config.color != :none
          shadow = ->(*) { Dopairb::Color.scale(color, 0.25) }
          Dopairb::Fx.big_text(canvas, text, x + 1, y + 1, shadow, scale: scale, bg_fn: shadow)
        end
        Dopairb::Fx.big_text(canvas, text, x, y, ink, scale: scale,
                            reveal: [progress * 4, 1].min, bg_fn: background)
      end
    end

    def draw_sprite(canvas, name, center, y, progress, limit: canvas.h - y - 2)
      rows = Art::SPRITES.fetch(name)
      compact = Art::COMPACT_SPRITES[name]
      rows = compact if rows.size > limit && compact && compact.size <= limit
      if limit < rows.size
        return if limit < 3
        rows = Array.new(limit) { |index| rows[(index * (rows.size - 1).fdiv(limit - 1)).round] }
      end
      left = center - rows.map(&:length).max / 2
      rows.each_with_index do |line, row|
        line.each_char.with_index do |char, col|
          next if char == " "
          color = if "*+o".include?(char)
                    GOLD
                  elsif "[]=".include?(char)
                    CYAN
                  else
                    Dopairb::Color.mix(PINK, MINT, (row.fdiv(rows.size) + progress * 0.3) % 1)
                  end
          canvas.put(left + col, y + row, char, color, bold: true)
        end
      end
    end

    def burst(canvas, x, y, progress, color: GOLD)
      age = Dopairb::Fx.phase(progress, 0.25, 1)
      Dopairb::Fx.shockwave(canvas, x, y, age * 0.48, speed: 24, palette: [[255, 255, 255], color, VIOLET], life: 0.6)
      12.times do |index|
        angle = index * Math::PI / 6
        distance = 1 + age * 13
        canvas.put(x + Math.cos(angle) * distance, y + Math.sin(angle) * distance * 0.25,
                   index.even? ? "*" : "+", Dopairb::Color.mix(color, PINK, index.fdiv(12)))
      end
    end

    def finish_canvas(canvas)
      canvas.render(depth).map { |line| crop(line, canvas.w, trusted_pixels: true) }
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
          part if trusted_pixels && config.color != :none
        elsif remaining.positive?
          remaining -= 1
          if part.ascii_only? && part.ord.between?(32, 126)
            part
          elsif trusted_pixels && ART_GLYPHS.match?(part)
            Dopairb::Term.glyph(part, "#")
          elsif trusted_pixels && %w[✦ ✧].include?(part)
            part == "✦" ? "*" : "+"
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

    def draw_art(canvas, kind, progress, data, row)
      middle = canvas.w / 2
      tick = (progress * 20).to_i
      room = canvas.h - row - 2
      case kind
      when :title
        offset = ((progress - 0.5) * [canvas.w / 3, 24].min).round
        draw_sprite(canvas, :llama, middle + offset, row, progress)
        if canvas.w >= 64
          gradient_text(canvas, 4, row + 2, "{ grammar }", progress)
          gradient_text(canvas, canvas.w - 15, row + 2, "< parser.c >", progress + 0.3)
          canvas.line(16, row + 3, middle + offset - 9, row + 3, CYAN)
          canvas.line(middle + offset + 9, row + 3, canvas.w - 16, row + 3, PINK)
        end
        canvas.put(1, canvas.h - 3, "~" * (canvas.w - 2), VIOLET)
      when :scan
        tokens = %w[%token ID NUMBER %% expr : term + expr ; %left]
        [room, 5].min.times do |index|
          line = tokens.rotate((tick + index * 3) % tokens.size).join(" ")
          line.chars.first(canvas.w - 4).each_with_index do |char, col|
            canvas.put(col + 2, row + index, char, Dopairb::Color.mix(CYAN, VIOLET, index.fdiv(5)))
          end
        end
        beam = (progress * (canvas.w - 5)).round + 2
        [room, 5].min.times { |index| canvas.put(beam, row + index, "|", GOLD, bg: Dopairb::Color.scale(PINK, 0.4), bold: true) }
        canvas.put_center(canvas.h - 3, "[ TOKEN STREAM >>> SYMBOL TABLE ]", MINT, bold: true)
      when :loaded
        draw_sprite(canvas, :book, canvas.w >= 70 ? canvas.w / 3 : middle, row, progress)
        if canvas.w >= 70
          ["RULES #{data[:rules]}", "TOKENS #{data[:terms]}", "NONTERMS #{data[:nterms]}"].each_with_index do |label, index|
            x = canvas.w / 2 + 6 + ((1 - Dopairb::Fx.ease_out(progress)) * 8).round
            canvas.put(x, row + index * 2, crop("[ #{label} ]", canvas.w - x), [GOLD, CYAN, PINK][index], bold: true)
          end
        end
      when :evolve, :fusion, :split
        spread = (kind == :split ? progress : 1 - progress) * [canvas.w / 4, 20].min
        ["+-------+", "| RULE  |", "+-------+"].each_with_index do |line, index|
          canvas.put(middle - spread - 9, row + index, line, CYAN, bold: true)
          canvas.put(middle + spread, row + index, line.sub("RULE", kind == :evolve ? "EXPR" : "RULE"), PINK, bold: true)
        end
        burst(canvas, middle, row + 2, progress, color: MINT)
        canvas.put_center(canvas.h - 3, kind == :split ? "<-- DISTINCT STATES -->" : ">>> RULES COMBINE <<<", GOLD, bold: true)
      when :states
        columns = [[canvas.w / 8, 3].max, 12].min
        cells = columns * [room, 5].min
        cells.times do |index|
          next if index > cells * progress
          x = (canvas.w - columns * 7) / 2 + index % columns * 7
          y = row + index / columns
          canvas.put(x, y, "[#{format('%03d', index)}]", Dopairb::Color.rainbow(index.fdiv([cells, 1].max) * 0.7), bold: true)
        end
        burst(canvas, middle, row + 2, progress, color: GOLD) if progress > 0.55
      when :lookahead
        [room, 5].min.times do |index|
          canvas.put_center(row + index, "[00]  [01]  [10]  [11]", [CYAN, VIOLET, PINK, GOLD, MINT][index])
        end
        canvas.line(middle, row + 2, middle + Math.cos(progress * Math::PI * 2) * 18,
                    row + 2 + Math.sin(progress * Math::PI * 2) * 2, GOLD)
        canvas.ring(middle, row + 2, 10, MINT)
      when :slash, :critical
        draw_sprite(canvas, :boss, middle + (progress > 0.5 ? (progress * 3).round : 0), row, progress)
        canvas.w.times do |x|
          next if x > canvas.w * [progress * 2, 1].min
          y = row + room / 2 - (x - middle).fdiv(10)
          canvas.put(x, y, "/", [255, 255, 255], bold: true)
          canvas.put(x, y + 1, "/", PINK)
        end
        burst(canvas, middle, row + room / 2, progress, color: PINK)
        canvas.put_center(canvas.h - 3, "x#{data[:resolved_conflicts] || data[:multiplier] || 4}  >>> RESOLVED <<<", GOLD, bold: true)
      when :boss, :expect_mismatch
        draw_sprite(canvas, :boss, middle + (Math.sin(progress * Math::PI * 4) * 2).round, row, progress, limit: room - 1)
        hp = data[:sr_conflicts].to_i + data[:rr_conflicts].to_i
        canvas.put_center(canvas.h - 3, "HP #{hp} [#{'=' * (12 * (1 - progress)).ceil}#{' ' * (12 * progress).floor}]", PINK, bold: true)
      when :forge, :extra
        burst(canvas, middle + 4, row + 3, progress, color: GOLD) if progress >= 0.3
        draw_sprite(canvas, :anvil, middle, row, progress)
        hammer_y = row + (Dopairb::Fx.ease_in([progress * 2, 1].min) * 3).round - 2
        draw_sprite(canvas, :hammer, middle + 12, hammer_y, progress)
        if canvas.w >= 70
          canvas.put(3, row + 3, crop(File.basename(data[:output].to_s), 18), MINT, bold: true)
          canvas.put(3, row + 4, "#{data[:output_lines]} LINES", CYAN)
        end
      when :warning
        [room, 6].min.times do |index|
          line = index == 5 ? "/____________\\" : "#{' ' * (5 - index)} /#{' ' * index}!#{' ' * index}\\"
          canvas.put_center(row + index, line, index.even? ? GOLD : PINK, bold: true)
        end
      when :new_ability, :achievement, :record, :flawless, :finale
        draw_sprite(canvas, :trophy, middle, row, progress)
        3.times { |index| burst(canvas, canvas.w * (index + 1) / 4, row + 2, (progress + index * 0.2) % 1, color: [CYAN, PINK, GOLD][index]) }
        if canvas.w >= 76 && data[:score]
          canvas.put(3, row + 2, "+#{(data[:score] * Dopairb::Fx.ease_out(progress)).to_i} XP", GOLD, bold: true)
          canvas.put(canvas.w - 17, row + 2, crop("LV #{data[:level]}  #{data[:rank]}", 16), MINT, bold: true)
        end
      when :jackpot
        12.times do |index|
          x = (index * 17 + 3) % canvas.w
          y = row + ((index * 3 + progress * 10) % [room, 1].max)
          canvas.put(x, y, index.even? ? "$" : "o", [GOLD, PINK, CYAN][index % 3], bold: true)
        end
        sprite_width = Art::SPRITES[:slots].map(&:length).max
        left = middle - sprite_width / 2
        [room, 8].min.times { |index| canvas.put(left, row + index, " " * sprite_width) }
        draw_sprite(canvas, :slots, middle, row, progress)
        if room >= 8
          [4, 11, 18].each_with_index do |column, index|
            digit = progress >= 0.5 + index * 0.18 ? 7 : (tick * (index + 2)) % 10
            canvas.put(left + column, row + 3, digit.to_s, [GOLD, PINK, CYAN][index], bold: true)
          end
        end
      when :grammar_break, :validation_break
        draw_sprite(canvas, :book, middle, row, progress)
        [room, 7].min.times do |index|
          x = middle + (index.even? ? -1 : 1) * (1 + progress * 3).round
          canvas.put(x, row + index, index.even? ? "/ /" : "\\ \\", PINK, bold: true)
        end
      else
        burst(canvas, middle, row + room / 2, progress)
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
