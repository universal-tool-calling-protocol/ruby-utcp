# frozen_string_literal: true

require_relative "lib/utcp/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-utcp"
  spec.version = UTCP::VERSION
  spec.authors = ["ruby-utcp contributors"]
  spec.email = ["maintainers@utcp.io"]

  spec.summary = "A Ruby implementation of the Universal Tool Calling Protocol"
  spec.description = "Discover, search, and call UTCP 1.1 tools over pluggable native protocols."
  spec.homepage = "https://www.utcp.io"
  spec.license = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/universal-tool-calling-protocol/ruby-utcp"
  spec.metadata["documentation_uri"] = "https://www.utcp.io/implementation"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "lib/**/*.rb", "examples/**/*.rb", "examples/**/*.py", "examples/**/*.txt",
      "proto/**/*.proto", "README.md", "LICENSE", "CHANGELOG.md", "Makefile"
    ]
  end
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", ">= 5.0", "< 7.0"
  spec.add_development_dependency "rake", ">= 12.0", "< 14.0"
end
