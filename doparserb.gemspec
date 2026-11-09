# frozen_string_literal: true

require_relative "lib/doparserb/version"

Gem::Specification.new do |spec|
  spec.name = "doparserb"
  spec.version = Doparserb::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "A parser generator with terminal shows for building and running parsers"
  spec.description = "Doparserb extends lrama with generation and parsing shows while preserving parser behavior."
  spec.homepage = "https://github.com/ydah/doparserb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.files = Dir["lib/**/*.{rb,erb}", "exe/*", "README.md", "LICENSE.txt", "spec.md"]
  spec.bindir = "exe"
  spec.executables = ["doparserb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "lrama", "~> 0.8.0"
  spec.add_dependency "dopairb", ">= 0.5"
end
