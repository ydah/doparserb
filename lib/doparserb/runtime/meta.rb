# frozen_string_literal: true

require "digest"
require "json"

module Doparserb
  module Runtime
    class Meta
      attr_reader :digest

      def initialize(data)
        @data = {v: 1, grammar: File.basename(data.fetch(:grammar)), generator: data.fetch(:generator),
                 symbols: data.fetch(:symbols), rules: data.fetch(:rules), states: data.fetch(:states)}
        @digest = Digest::SHA256.hexdigest(JSON.generate(@data))
        @data[:digest] = @digest
      end

      def json
        JSON.generate(@data)
      end

      def stub_json
        JSON.generate(@data.slice(:v, :grammar, :digest, :generator))
      end

      def parser_id
        @digest[0, 8]
      end

      def self.c_literal(string)
        '"' + string.bytes.map { |byte| format("\\%03o", byte) }.join + '"'
      end
    end
  end
end
