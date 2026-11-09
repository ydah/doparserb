# frozen_string_literal: true

require "erb"

module Doparserb
  module Runtime
    autoload :Anchors, "doparserb/runtime/anchors"
    autoload :Weaver, "doparserb/runtime/weaver"
    autoload :Meta, "doparserb/runtime/meta"

    def self.c_source(metadata_json, parser_id:)
      raise ArgumentError, "parser_id must contain eight lowercase hexadecimal digits" unless /\A[0-9a-f]{8}\z/.match?(parser_id)

      ERB.new(File.read(File.join(__dir__, "runtime/dopa_rt.c.erb")), trim_mode: "-")
        .result_with_hash(metadata_literal: Meta.c_literal(metadata_json), parser_id: parser_id)
    end
  end
end
