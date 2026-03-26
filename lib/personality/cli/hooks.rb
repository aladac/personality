# frozen_string_literal: true

require "thor"

module Personality
  class CLI < Thor
    class Hooks < Thor
      desc "pre-tool-use", "PreToolUse hook — log and allow"
      def pre_tool_use
        require_relative "../hooks"
        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("PreToolUse", data)
      end

      desc "post-tool-use", "PostToolUse hook — log"
      def post_tool_use
        require_relative "../hooks"
        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("PostToolUse", data)
      end

      desc "stop", "Stop hook — log"
      def stop
        require_relative "../hooks"
        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("Stop", data)
      end

      desc "subagent-stop", "SubagentStop hook — log"
      def subagent_stop
        require_relative "../hooks"
        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("SubagentStop", data)
      end

      desc "session-start", "SessionStart hook — log, load persona, output intro"
      def session_start
        require_relative "../hooks"
        require_relative "../cart"
        require_relative "../db"

        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("SessionStart", data)

        begin
          Personality::DB.migrate!
          cart = Personality::Cart.active

          if cart[:name] || cart[:tagline]
            name = cart[:name] || cart[:tag]
            puts "**Active Persona:** #{name}"
            puts cart[:tagline] if cart[:tagline]
            puts
          end
        rescue
          # Silently continue if cart loading fails
        end
      end

      desc "session-end", "SessionEnd hook — log"
      def session_end
        require_relative "../hooks"
        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("SessionEnd", data)
      end

      desc "user-prompt-submit", "UserPromptSubmit hook — log and allow"
      def user_prompt_submit
        require_relative "../hooks"
        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("UserPromptSubmit", data)
      end

      desc "pre-compact", "PreCompact hook — log"
      def pre_compact
        require_relative "../hooks"
        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("PreCompact", data)
      end

      desc "notification", "Notification hook — log and speak via TTS"
      def notification
        require_relative "../hooks"
        require_relative "../tts"

        data = Personality::Hooks.read_stdin_json
        Personality::Hooks.log("Notification", data)

        return unless data

        message = data["message"]
        return if message.nil? || message.empty?

        # Prepend project name for context
        cwd = data["cwd"] || Dir.pwd
        project = File.basename(cwd)
        speech = "#{project}: #{message}"

        Personality::TTS.stop_current
        Personality::TTS.speak(speech)
      rescue
        # Silently continue if TTS fails
      end

      desc "install", "Generate hooks.json for Claude Code"
      option :output, type: :string, aliases: "-o", default: "hooks.json",
        desc: "Output file path"
      def install
        require_relative "../hooks"
        output = options[:output]
        File.write(output, Personality::Hooks.generate_hooks_json)
        puts "Generated #{output}"
      end

      def self.exit_on_failure?
        true
      end
    end
  end
end
