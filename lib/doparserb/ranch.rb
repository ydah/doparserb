# frozen_string_literal: true

module Doparserb
  class Ranch
    COATS = %w[Snow Amber Rose Slate].freeze
    ACCESSORIES = %w[Scarf Bell Cap Ribbon].freeze
    BACKGROUNDS = %w[Meadow Dunes Rain Stars].freeze
    VARIANTS = 64.times.map do |id|
      coat, accessory, background = COATS[id / 16], ACCESSORIES[id / 4 % 4], BACKGROUNDS[id % 4]
      {id: id, name: "#{coat} #{accessory} of #{background}".freeze,
       coat: coat, accessory: accessory, background: background}.freeze
    end.freeze

    def self.variants = VARIANTS

    def self.variant(id)
      raise ArgumentError, "llama id must be an integer in 0...64" unless id.is_a?(Integer) && (0...64).cover?(id)
      VARIANTS[id]
    end

    def self.render(id:, width:, owned: true, tick: 0, ascii: true)
      llama = variant(id)
      raise ArgumentError, "width must be a positive integer" unless width.is_a?(Integer) && width.positive?
      width = [width, 120].min
      offset = (width - 20).positive? ? tick.to_i % (width - 19) : 0
      pixels = Array.new(14) { Array.new(width, 0) }
      paint = lambda do |xs, ys, value = 1|
        ys.each do |y|
          xs.each do |x|
            target = x + offset
            pixels[y][target] = value if target >= 0 && target < width
          end
        end
      end
      [[3..3, 0..2], [6..6, 0..2], [3..8, 2..4], [4..6, 5..9],
       [4..17, 7..10], [17..18, 6..7]].each { |xs, ys| paint.call(xs, ys) }
      step = tick.to_i.odd? ? 1 : 0
      paint.call((5 - step)..(6 - step), 11..13)
      paint.call((14 + step)..(15 + step), 11..13)
      if owned
        paint.call(6..6, 3..3, 0)
        case id / 4 % 4
        when 0
          paint.call(3..7, 5..5, 2)
          paint.call(7..8, 6..7, 2)
        when 1
          paint.call(7..7, 5..6, 2)
          paint.call(7..9, 7..8, 2)
        when 2
          paint.call(3..7, 1..1, 2)
          paint.call(2..8, 2..2, 2)
        when 3
          paint.call(10..13, 6..7, 2)
          paint.call(11..12, 8..8, 2)
        end
      end
      body = owned ? %w[# @ % O][id / 16] : "?"
      accessory = %w[* o = +][id / 4 % 4]
      rows = 7.times.map do |row|
        width.times.map do |x|
          top, bottom = pixels[row * 2][x], pixels[row * 2 + 1][x]
          if top.positive? || bottom.positive?
            if ascii
              top == 2 || bottom == 2 ? accessory : body
            else
              top.positive? ? (bottom.positive? ? "█" : "▀") : "▄"
            end
          elsif owned
            case id % 4
            when 0 then row == 6 && x % 5 == 0 ? "," : " "
            when 1 then row == 6 ? "~" : " "
            when 2 then row < 3 && (x + row * 3) % 9 == 0 ? "/" : " "
            when 3 then row < 3 && (x * 3 + row) % 11 == 0 ? "+" : " "
            end
          else
            " "
          end
        end.join.rstrip
      end
      label = format("#%02d %s", id, owned ? llama[:name] : "UNKNOWN LLAMA")
      [label[0, width], *rows]
    end

    def initialize(config:, engine: nil)
      @config = config
      @engine = engine || Engine.new(config)
    end

    def show(owned:, tour: false)
      owned = owned.map { |id| self.class.variant(id).fetch(:id) }.uniq.sort.freeze
      @engine.session do
        if @engine.animated?
          if tour
            self.class.variants.each do |llama|
              break if @engine.cancelled?
              @engine.scene(:ranch, title: "LLAMA RANCH TOUR", duration: 0.1 * @config.duration,
                data: {ids: [llama[:id]], owned: owned})
            end
          elsif !owned.empty?
            @engine.scene(:ranch, title: "LLAMA RANCH", duration: 2.0 * @config.duration,
              data: {ids: owned, owned: owned})
          end
        end
        @engine.badge("LLAMA RANCH | #{owned.size}/64 COLLECTED")
      end
    end
  end
end
