# frozen_string_literal: true

module Doparserb
  Event = Data.define(:kind, :strength, :info) do
    def initialize(kind:, strength: :small, info: {})
      super(kind: kind, strength: strength, info: info.freeze)
    end
  end
end
