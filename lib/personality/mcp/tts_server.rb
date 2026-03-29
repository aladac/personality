# frozen_string_literal: true

require "mcp"
require "mcp/transports/stdio"
require "json"
require_relative "../tts"

module Personality
  module MCP
    class TtsServer
      def self.run
        new.start
      end

      def initialize
        @server = ::MCP::Server.new(
          name: "speech",
          version: Personality::VERSION
        )
        @server.server_context = {}
        register_tools
      end

      def start
        transport = ::MCP::Transports::StdioTransport.new(@server)
        transport.open
      end

      private

      def register_tools
        register_speak
        register_stop
        register_voices
        register_current
        register_download
        register_test
      end

      def register_speak
        @server.define_tool(
          name: "speak",
          description: "Speak text aloud using TTS. Synthesizes and plays audio in the background unless wait=true.",
          input_schema: {
            type: "object",
            properties: {
              text: {type: "string", description: "Text to speak aloud"},
              voice: {type: "string", description: "Voice model name (optional, uses active voice if omitted)"},
              language: {type: "string", description: "Language code (e.g. 'en', 'pl'). Auto-detected if omitted."},
              wait: {type: "boolean", description: "Wait for playback to complete before returning (default: false)"}
            },
            required: %w[text]
          }
        ) do |text:, server_context:, **opts|
          result = if opts[:wait]
            Personality::TTS.speak_and_wait(text, voice: opts[:voice], language: opts[:language])
          else
            Personality::TTS.speak(text, voice: opts[:voice], language: opts[:language])
          end
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end
      end

      def register_stop
        @server.define_tool(
          name: "stop",
          description: "Stop currently playing TTS audio.",
          input_schema: {type: "object", properties: {}}
        ) do |server_context:, **|
          stopped = Personality::TTS.stop_current
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate({stopped: stopped})}])
        end
      end

      def register_voices
        @server.define_tool(
          name: "voices",
          description: "List all installed TTS voice models.",
          input_schema: {type: "object", properties: {}}
        ) do |server_context:, **|
          voices = Personality::TTS.list_voices
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate({voices: voices, count: voices.size})}])
        end
      end

      def register_current
        @server.define_tool(
          name: "current",
          description: "Show the currently active TTS voice and whether it is installed.",
          input_schema: {type: "object", properties: {}}
        ) do |server_context:, **|
          voice = Personality::TTS.active_voice
          installed = !Personality::TTS.find_voice(voice).nil?
          backend = Personality::TTS.backend
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate({voice: voice, installed: installed, backend: backend})}])
        end
      end

      def register_download
        @server.define_tool(
          name: "download",
          description: "Download a piper TTS voice model from HuggingFace.",
          input_schema: {
            type: "object",
            properties: {
              voice: {type: "string", description: "Voice name to download (e.g. en_US-lessac-medium)"}
            },
            required: %w[voice]
          }
        ) do |voice:, server_context:, **|
          result = Personality::TTS.download_voice(voice)
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end
      end

      def register_test
        @server.define_tool(
          name: "test",
          description: "Test a TTS voice with sample text. Speaks and waits for completion.",
          input_schema: {
            type: "object",
            properties: {
              voice: {type: "string", description: "Voice to test (optional, uses active voice if omitted)"}
            }
          }
        ) do |server_context:, **opts|
          result = Personality::TTS.speak_and_wait("Hello! This is a test of the text to speech system.", voice: opts[:voice])
          ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
        end
      end
    end
  end
end
