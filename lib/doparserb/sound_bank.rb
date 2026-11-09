# frozen_string_literal: true

module Doparserb
  module SoundBank
    CACHE_VERSION = 1
    MAX_CHAIN_STEP = 36
    CHAIN_BASE_HZ = 440.0
    SEMITONE = 2**(1.0 / 12)
    PATCHES = {
      dopa_shift: ->(s, _) { [s.tone(1320.0, 0.018, wave: :triangle, vol: 0.12, decay: 0.006), 0] },
      dopa_reduce: ->(s, _) {
        [s.mix(s.tone(330.0, 0.07, wave: :triangle, vol: 0.18, slide_to: 660),
               s.tone(990.0, 0.07, wave: :sine, vol: 0.08, slide_to: 660)), 0]
      },
      dopa_chain: ->(s, step) { [s.tone(CHAIN_BASE_HZ * SEMITONE**step, 0.085, wave: :triangle, vol: 0.18, decay: 0.04), 0] },
      dopa_states: ->(s, _) { [s.arp([440.0, 554.0, 659.0, 880.0, 1109.0, 1319.0], 0.025, wave: :triangle, vol: 0.12, decay: 0.01), 0] },
      dopa_slash: ->(s, _) {
        [s.mix(s.noise(0.13, vol: 0.2, decay: 0.04),
               s.tone(2100.0, 0.13, wave: :saw, vol: 0.12, slide_to: 700, decay: 0.05)), 0]
      },
      dopa_boss: ->(s, _) {
        [s.mix(s.tone(110.0, 0.35, wave: :saw, vol: 0.16, slide_to: 55),
               s.tone(116.0, 0.35, wave: :triangle, vol: 0.14, slide_to: 58), s.noise(0.12, vol: 0.2, decay: 0.04)), 0]
      },
      dopa_forge: ->(s, _) {
        [s.mix(s.noise(0.035, vol: 0.35, decay: 0.008),
               s.tone(1568.0, 0.28, wave: :sine, vol: 0.2, decay: 0.08),
               s.tone(2331.0, 0.2, wave: :sine, vol: 0.1, decay: 0.06)), 0]
      },
      dopa_repair: ->(s, _) { [s.arp([523.0, 659.0, 784.0, 1047.0], 0.06, wave: :sine, vol: 0.2, decay: 0.05), 0] },
      dopa_clear: ->(s, _) {
        [s.seq(s.arp([392.0, 523.0, 659.0, 784.0], 0.06, wave: :triangle, vol: 0.16, decay: 0.05),
               s.mix(*[523.0, 659.0, 784.0, 1047.0].map { |frequency| s.tone(frequency, 0.3, wave: :triangle, vol: 0.07) })), 0.24]
      }
    }.freeze

    module_function

    def custom?(name) = PATCHES.key?(name)

    def step(name, value)
      # shortcut: cap chain pitch at three octaves; extend only with a new audible register and cache bound.
      name == :dopa_chain ? value.to_i.clamp(0, MAX_CHAIN_STEP) : 0
    end

    def render(name, value, synth:)
      PATCHES.fetch(name).call(synth, step(name, value))
    end

    def selection(kind, data = {})
      name = case kind
             when :next, :shift then :dopa_shift
             when :reduce, :from_nothing, :fusion, :evolve then :dopa_reduce
             when :chain then :dopa_chain
             when :states, :charging, :tower_milestone, :token_milestone then :dopa_states
             when :slash then :dopa_slash
             when :boss then :dopa_boss
             when :forge, :extra then :dopa_forge
             when :repair_plan, :inserted, :auto_repair, :recovery then :dopa_repair
             when :stage_clear, :comeback, :finale, :flawless then :dopa_clear
             when :title, :tower then :intro
             when :critical then :crit
             when :jackpot then :jackpot
             when :llama_drop, :achievement, :new_ability then :levelup
             when :grammar_break, :expect_mismatch, :validation_break, :syntax_break, :aborted, :exhausted then :error
             when :collapse then :crack
             when :scan, :lookahead then :lock
             when :ranch then :nice
             else :banner
             end
      [name, step(name, data[:chain].to_i - 1)]
    end
  end
end
