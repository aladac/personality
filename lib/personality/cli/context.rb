# frozen_string_literal: true

require "thor"

module Personality
  class CLI < Thor
    class Context < Thor
      desc "track-read", "Track a file read (PostToolUse hook, reads JSON from stdin)"
      def track_read
        require_relative "../context"
        require_relative "../hooks"

        data = Personality::Hooks.read_stdin_json
        return unless data

        file_path = data.dig("tool_input", "file_path")
        return unless file_path

        session_id = data["session_id"]
        Personality::Context.track_read(file_path, session_id: session_id)
      end

      desc "check FILE", "Check if a file is in session context"
      def check(file_path)
        require_relative "../context"
        require "pastel"

        pastel = Pastel.new
        if Personality::Context.check(file_path)
          puts "#{pastel.green("✓")} #{file_path} is in context"
        else
          puts "#{pastel.dim("✗")} #{file_path} not in context"
          exit 1
        end
      end

      desc "list", "List all files in current session context"
      def list
        require_relative "../context"
        require "pastel"

        pastel = Pastel.new
        files = Personality::Context.list

        if files.empty?
          puts pastel.dim("No files in context")
        else
          puts "#{pastel.bold("Files in context")} (#{files.length})"
          files.each { |f| puts "  #{f}" }
        end
      end

      desc "clear", "Clear session context"
      def clear
        require_relative "../context"
        require "pastel"

        Personality::Context.clear
        puts Pastel.new.green("Context cleared")
      end

      def self.exit_on_failure?
        true
      end
    end
  end
end
