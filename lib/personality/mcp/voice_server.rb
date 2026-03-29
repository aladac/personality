# frozen_string_literal: true

require "mcp"
require "mcp/transports/stdio"
require "json"
require "open3"
require "tempfile"
require "shellwords"

module Personality
  module MCP
    class VoiceServer
      # Moto G52 phone configuration - ADB over WiFi
      PHONE_IP = "192.168.88.155"
      PHONE_PORT = "5555"
      PHONE_ADB = "#{PHONE_IP}:#{PHONE_PORT}"
      TERMUX_HOME = "/data/data/com.termux/files/home"

      # Junkpile server configuration (192.168.88.165 for WiFi access)
      JUNKPILE_SSH = "j"
      JUNKPILE_IP = "192.168.88.165"
      WHISPER_PATH = "~/.local/bin/whisper"
      CLAUDE_PATH = "/home/linuxbrew/.linuxbrew/bin/claude"

      def self.run
        new.start
      end

      def initialize
        @server = ::MCP::Server.new(
          name: "voice",
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

      def tool_response(result)
        ::MCP::Tool::Response.new([{type: "text", text: JSON.generate(result)}])
      end

      def register_tools
        register_voice_record
        register_voice_transcribe
        register_voice_ask
        register_voice_listen
        register_voice_status
      end

      # === Voice Record Tool ===
      # Records audio from the Moto G52 phone via Termux

      def register_voice_record
        @server.define_tool(
          name: "voice_record",
          description: "Record audio from the Moto G52 phone via Termux. Returns path to the recorded WAV file on junkpile.",
          input_schema: {
            type: "object",
            properties: {
              duration: {type: "integer", description: "Recording duration in seconds (default: 8, max: 60)"},
              output_path: {type: "string", description: "Output path on junkpile (default: /tmp/phone_voice.wav)"}
            }
          }
        ) do |server_context:, **opts|
          duration = [opts[:duration] || 8, 60].min
          output_path = opts[:output_path] || "/tmp/phone_voice.wav"

          result = record_from_phone(duration: duration, output_path: output_path)
          tool_response(result)
        end
      end

      # === Voice Transcribe Tool ===
      # Transcribes audio using Whisper on junkpile

      def register_voice_transcribe
        @server.define_tool(
          name: "voice_transcribe",
          description: "Transcribe audio file using Whisper STT on junkpile. Returns the transcribed text.",
          input_schema: {
            type: "object",
            properties: {
              audio_path: {type: "string", description: "Path to audio file on junkpile"},
              model: {type: "string", description: "Whisper model to use (default: small). Options: tiny, base, small, medium, large"},
              language: {type: "string", description: "Language code (default: en)"}
            },
            required: %w[audio_path]
          }
        ) do |audio_path:, server_context:, **opts|
          model = opts[:model] || "small"
          language = opts[:language] || "en"

          result = transcribe_audio(audio_path: audio_path, model: model, language: language)
          tool_response(result)
        end
      end

      # === Voice Ask Tool ===
      # Full pipeline: record -> transcribe -> Claude -> TTS response

      def register_voice_ask
        @server.define_tool(
          name: "voice_ask",
          description: "Full voice pipeline: record audio from phone, transcribe with Whisper, send to Claude, and speak the response. Returns the transcript and response.",
          input_schema: {
            type: "object",
            properties: {
              duration: {type: "integer", description: "Recording duration in seconds (default: 8)"},
              model: {type: "string", description: "Whisper model (default: small)"},
              speak_response: {type: "boolean", description: "Speak the response via TTS (default: true)"},
              voice: {type: "string", description: "TTS voice to use (default: bt7274)"}
            }
          }
        ) do |server_context:, **opts|
          duration = opts[:duration] || 8
          model = opts[:model] || "small"
          speak_response = opts.fetch(:speak_response, true)
          voice = opts[:voice] || "bt7274"

          result = voice_ask_pipeline(
            duration: duration,
            model: model,
            speak_response: speak_response,
            voice: voice
          )
          tool_response(result)
        end
      end

      # === Voice Listen Tool ===
      # Starts continuous wake word listening (placeholder for future)

      def register_voice_listen
        @server.define_tool(
          name: "voice_listen",
          description: "Start continuous wake word listening on the phone (using Vosk). Currently returns status of the listener service.",
          input_schema: {
            type: "object",
            properties: {
              wake_word: {type: "string", description: "Wake word to listen for (default: hey b t)"},
              action: {type: "string", enum: %w[start stop status], description: "Action: start, stop, or status (default: status)"}
            }
          }
        ) do |server_context:, **opts|
          action = opts[:action] || "status"
          wake_word = opts[:wake_word] || "hey b t"

          result = manage_wake_listener(action: action, wake_word: wake_word)
          tool_response(result)
        end
      end

      # === Voice Status Tool ===
      # Check connectivity and status of voice components

      def register_voice_status
        @server.define_tool(
          name: "voice_status",
          description: "Check status of voice pipeline components: phone connectivity, junkpile availability, Whisper installation.",
          input_schema: {type: "object", properties: {}}
        ) do |server_context:, **|
          result = check_voice_status
          tool_response(result)
        end
      end

      # === Implementation Methods ===

      def record_from_phone(duration:, output_path:)
        # Record on phone using termux-microphone-record via ADB
        phone_audio = "#{TERMUX_HOME}/voice_cmd.wav"
        local_audio = "/tmp/voice_cmd_local.wav"

        # Ensure ADB is connected
        connect_output, _ = Open3.capture2("adb connect #{PHONE_ADB} 2>&1")

        # Step 1: Record audio on phone via ADB + run-as
        record_cmd = "adb -s #{PHONE_ADB} shell 'run-as com.termux #{TERMUX_HOME}/../usr/bin/termux-microphone-record -f #{phone_audio} -l #{duration}' 2>&1"
        record_output, record_status = Open3.capture2(record_cmd)

        unless record_status.success?
          return {
            success: false,
            error: "Failed to record on phone",
            details: record_output.strip
          }
        end

        # Step 2: Pull audio from phone via ADB
        pull_cmd = "adb -s #{PHONE_ADB} shell 'run-as com.termux cat #{phone_audio}' > #{local_audio} 2>/dev/null"
        pull_output, pull_status = Open3.capture2(pull_cmd)

        unless pull_status.success? && File.exist?(local_audio) && File.size(local_audio) > 0
          return {
            success: false,
            error: "Failed to pull audio from phone",
            details: "File size: #{File.exist?(local_audio) ? File.size(local_audio) : 'N/A'}"
          }
        end

        # Step 3: Transfer to junkpile
        scp_cmd = "scp -q #{local_audio} #{JUNKPILE_SSH}:#{output_path} 2>&1"
        scp_output, scp_status = Open3.capture2(scp_cmd)

        unless scp_status.success?
          return {
            success: false,
            error: "Failed to transfer audio to junkpile",
            details: scp_output.strip
          }
        end

        # Step 4: Cleanup
        File.delete(local_audio) if File.exist?(local_audio)
        Open3.capture2("adb -s #{PHONE_ADB} shell 'run-as com.termux rm -f #{phone_audio}' 2>&1")

        {
          success: true,
          duration: duration,
          output_path: output_path,
          message: "Recorded #{duration}s of audio"
        }
      end

      def transcribe_audio(audio_path:, model:, language:)
        # Convert audio to proper format and transcribe with Whisper
        converted_path = "/tmp/voice_converted.wav"

        # Build the transcription command
        cmd = <<~BASH
          export PATH=~/.local/bin:$PATH
          ffmpeg -i #{Shellwords.escape(audio_path)} -ar 16000 -ac 1 #{converted_path} -y 2>/dev/null
          #{WHISPER_PATH} #{converted_path} --model #{model} --language #{language} --output_format txt --output_dir /tmp 2>/dev/null
          cat /tmp/voice_converted.txt 2>/dev/null | tr '\\n' ' ' | xargs
        BASH

        ssh_cmd = "ssh #{JUNKPILE_SSH} #{Shellwords.escape("bash -c #{Shellwords.escape(cmd)}")} 2>&1"
        output, status = Open3.capture2(ssh_cmd)

        transcript = output.strip

        if transcript.empty?
          return {
            success: false,
            error: "Transcription returned empty result",
            audio_path: audio_path
          }
        end

        {
          success: true,
          transcript: transcript,
          model: model,
          language: language,
          audio_path: audio_path
        }
      end

      def voice_ask_pipeline(duration:, model:, speak_response:, voice:)
        # Step 1: Record
        audio_path = "/tmp/phone_voice.wav"
        record_result = record_from_phone(duration: duration, output_path: audio_path)

        unless record_result[:success]
          return record_result.merge(stage: "record")
        end

        # Step 2: Transcribe
        transcribe_result = transcribe_audio(audio_path: audio_path, model: model, language: "en")

        unless transcribe_result[:success]
          return transcribe_result.merge(stage: "transcribe")
        end

        transcript = transcribe_result[:transcript]

        # Step 3: Get Claude response on junkpile
        prompt = "Voice command from user: #{transcript}\nRespond concisely (1-2 sentences max)."

        claude_cmd = <<~BASH
          export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
          #{CLAUDE_PATH} --print --output-format stream-json --verbose #{Shellwords.escape(prompt)} 2>/dev/null | grep '"type":"assistant"' | head -1 | jq -r '.message.content[0].text // empty'
        BASH

        ssh_cmd = "ssh #{JUNKPILE_SSH} #{Shellwords.escape("bash -c #{Shellwords.escape(claude_cmd)}")} 2>&1"
        response, status = Open3.capture2(ssh_cmd)
        response = response.strip

        if response.empty?
          return {
            success: false,
            error: "Claude returned empty response",
            transcript: transcript,
            stage: "claude"
          }
        end

        # Step 4: Speak response (if enabled)
        if speak_response
          # Use local TTS via psn
          tts_result = speak_text(text: response, voice: voice)
        end

        {
          success: true,
          transcript: transcript,
          response: response,
          spoke_response: speak_response,
          voice: voice,
          duration: duration,
          model: model
        }
      end

      def speak_text(text:, voice:)
        # Call local piper TTS
        require_relative "../tts"
        Personality::TTS.speak(text, voice: voice)
      rescue => e
        {error: e.message}
      end

      def manage_wake_listener(action:, wake_word:)
        case action
        when "start"
          # Future: Start Vosk wake word listener on phone
          {
            success: false,
            message: "Wake word listener not yet implemented. Use voice_record for manual recording.",
            wake_word: wake_word
          }
        when "stop"
          {
            success: false,
            message: "Wake word listener not yet implemented"
          }
        when "status"
          # Check if wake listener process is running via ADB
          check_cmd = "adb -s #{PHONE_ADB} shell 'run-as com.termux pgrep -f vosk_wake || echo not_running' 2>&1"
          output, _ = Open3.capture2(check_cmd)

          running = !output.include?("not_running")

          {
            status: running ? "running" : "stopped",
            wake_word: wake_word,
            message: running ? "Wake word listener is active" : "Wake word listener is not running"
          }
        else
          {error: "Unknown action: #{action}"}
        end
      end

      def check_voice_status
        status = {}

        # Check phone connectivity via ADB
        adb_check = "adb connect #{PHONE_ADB} 2>&1 && adb -s #{PHONE_ADB} shell echo ok 2>&1"
        phone_output, phone_status = Open3.capture2(adb_check)
        status[:phone] = {
          host: PHONE_ADB,
          method: "adb_wifi",
          connected: phone_output.include?("ok")
        }

        # Check junkpile connectivity
        junkpile_check = "ssh -o ConnectTimeout=3 #{JUNKPILE_SSH} 'echo ok' 2>&1"
        junkpile_output, junkpile_status = Open3.capture2(junkpile_check)
        status[:junkpile] = {
          ssh_alias: JUNKPILE_SSH,
          connected: junkpile_output.strip == "ok"
        }

        # Check Whisper installation on junkpile
        if status[:junkpile][:connected]
          whisper_check = "ssh #{JUNKPILE_SSH} 'test -x #{WHISPER_PATH} && echo ok' 2>&1"
          whisper_output, _ = Open3.capture2(whisper_check)
          status[:whisper] = {
            path: WHISPER_PATH,
            installed: whisper_output.strip == "ok"
          }

          # Check Claude CLI on junkpile
          claude_check = "ssh #{JUNKPILE_SSH} 'test -x #{CLAUDE_PATH} && echo ok' 2>&1"
          claude_output, _ = Open3.capture2(claude_check)
          status[:claude] = {
            path: CLAUDE_PATH,
            installed: claude_output.strip == "ok"
          }
        end

        # Overall status
        all_ok = status[:phone][:connected] &&
                 status[:junkpile][:connected] &&
                 status.dig(:whisper, :installed) &&
                 status.dig(:claude, :installed)

        status[:ready] = all_ok
        status[:message] = all_ok ? "Voice pipeline ready" : "Some components unavailable"

        status
      end
    end
  end
end
