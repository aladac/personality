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

    desc "init", "Initialize personality environment"
    option :yes, type: :boolean, default: false, aliases: "-y",
      desc: "Skip confirmation prompts"
    def init
      require_relative "init"
      Init.new(auto_yes: options[:yes]).run
    end

    def self.exit_on_failure?
      true
    end
  end
end
