# frozen_string_literal: true

require_relative "lib/personality/version"

Gem::Specification.new do |spec|
  spec.name = "personality"
  spec.version = Personality::VERSION
  spec.authors = ["aladac"]
  spec.email = ["adam@saiden.pl"]

  spec.summary = "Infrastructure layer for Claude Code"
  spec.description = "CLI toolkit providing memory, hooks, and MCP servers for Claude Code personality system"
  spec.homepage = "https://github.com/aladac/personality"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aladac/personality"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .standard.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # CLI
  spec.add_dependency "thor", "~> 1.5.0"

  # Database
  spec.add_dependency "sqlite3", "~> 2.9.2"
  spec.add_dependency "sqlite-vec", "~> 0.1.7"

  # LLM
  spec.add_dependency "llm.rb", "~> 4.8.0"

  # Terminal output
  spec.add_dependency "tty-table", "~> 0.12.0"
  spec.add_dependency "tty-spinner", "~> 0.9.3"
  spec.add_dependency "tty-progressbar", "~> 0.18.3"
  spec.add_dependency "pastel", "~> 0.8.0"

  # MCP
  spec.add_dependency "mcp", "~> 0.9.1"

  # Cartridge packaging
  spec.add_dependency "rubyzip", "~> 2.4.1"

  # Config
  spec.add_dependency "toml-rb", "~> 4.1.0"

  # Development
  spec.add_development_dependency "irb", "~> 1.17.0"
  spec.add_development_dependency "rake", "~> 13.3.1"
  spec.add_development_dependency "rspec", "~> 3.13.2"
  spec.add_development_dependency "simplecov", "~> 0.22.0"
  spec.add_development_dependency "standard", "~> 1.54.0"
end
