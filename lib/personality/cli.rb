# frozen_string_literal: true

require "thor"

module Personality
  class CLI < Thor
    desc "version", "Show version"
    def version
      puts "psn #{Personality::VERSION}"
    end

    desc "info", "Show personality info"
    def info
      puts "Personality - Infrastructure layer for Claude Code"
      puts "Version: #{Personality::VERSION}"
    end

    def self.exit_on_failure?
      true
    end
  end
end
