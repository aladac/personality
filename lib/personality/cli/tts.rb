# frozen_string_literal: true

require "thor"

module Personality
  class CLI < Thor
    class Tts < Thor
      desc "speak TEXT", "Speak text aloud"
      option :voice, type: :string, aliases: "-v", desc: "Voice model name"
      option :language, type: :string, aliases: "-l", desc: "Language code (en, pl)"
      def speak(text)
        require_relative "../tts"
        require "pastel"

        result = Personality::TTS.speak_and_wait(text, voice: options[:voice], language: options[:language])
        if result[:error]
          puts Pastel.new.red(result[:error])
          exit 1
        end
      end

      desc "stop", "Stop currently playing TTS"
      def stop
        require_relative "../tts"
        require "pastel"

        pastel = Pastel.new
        if Personality::TTS.stop_current
          puts pastel.green("TTS stopped")
        else
          puts pastel.dim("No TTS playing")
        end
      end

      desc "mark-natural-stop", "Mark natural agent stop (Stop hook)"
      def mark_natural_stop
        require_relative "../tts"
        Personality::TTS.mark_natural_stop
      end

      desc "interrupt-check", "Check and handle TTS interrupt (UserPromptSubmit hook)"
      def interrupt_check
        require_relative "../tts"
        require "pastel"

        pastel = Pastel.new
        result = Personality::TTS.interrupt_check
        case result[:action]
        when :continue
          puts pastel.dim("Natural stop — TTS continues")
        when :stopped
          if result[:was_playing]
            puts pastel.green("User interrupt — TTS stopped")
          else
            puts pastel.dim("No TTS playing")
          end
        end
      end

      desc "voices", "List installed voice models"
      def voices
        require_relative "../tts"
        require "pastel"
        require "tty-table"

        voices = Personality::TTS.list_voices
        pastel = Pastel.new

        if voices.empty?
          puts pastel.dim("No voices installed")
          puts "\nDownload a voice:"
          puts "  psn tts download en_US-lessac-medium"
          return
        end

        table = TTY::Table.new(
          header: %w[Name Size],
          rows: voices.map { |v| [v[:name], "#{v[:size_mb]} MB"] }
        )
        puts table.render(:unicode, padding: [0, 1])
        puts pastel.dim("\nVoices dir: #{Personality::TTS::VOICES_DIR}")
      end

      desc "download VOICE", "Download a piper voice from HuggingFace"
      def download(voice_name)
        require_relative "../tts"
        require "pastel"
        require "tty-spinner"

        pastel = Pastel.new
        spinner = TTY::Spinner.new("  :spinner Downloading #{voice_name}...", format: :dots)
        spinner.auto_spin

        result = Personality::TTS.download_voice(voice_name)

        if result[:error]
          spinner.error(pastel.red("failed"))
          puts "  #{pastel.red(result[:error])}"
          exit 1
        elsif result[:exists]
          spinner.success(pastel.yellow("already installed"))
        else
          spinner.success(pastel.green("done (#{result[:size_mb]} MB)"))
        end
      end

      desc "test", "Test a voice with sample text"
      option :voice, type: :string, aliases: "-v", desc: "Voice to test"
      def test
        require_relative "../tts"
        require "pastel"

        voice = options[:voice]
        result = Personality::TTS.speak_and_wait("Hello! This is a test of the text to speech system.", voice: voice)
        if result[:error]
          puts Pastel.new.red(result[:error])
          exit 1
        end
      end

      desc "current", "Show active voice"
      def current
        require_relative "../tts"
        require "pastel"

        pastel = Pastel.new
        voice = Personality::TTS.active_voice
        backend = Personality::TTS.backend

        puts "#{pastel.bold("Backend:")} #{backend}"
        puts "#{pastel.bold("Voice:")} #{voice}"
        if Personality::TTS.find_voice(voice)
          puts "#{pastel.green("✓")} Available"
        else
          if backend == "xtts"
            puts "#{pastel.yellow("!")} Voice not found on XTTS host"
          else
            puts "#{pastel.yellow("!")} Not installed — run: psn tts download #{voice}"
          end
        end
      end

      desc "backend", "Show TTS backend info"
      def backend
        require_relative "../tts"
        require "pastel"

        pastel = Pastel.new
        backend = Personality::TTS.backend

        puts "#{pastel.bold("Backend:")} #{backend}"
        if backend == "xtts"
          puts "#{pastel.bold("Host:")} #{Personality::TTS::XTTS_HOST}"
          puts "#{pastel.bold("Project:")} #{Personality::TTS::XTTS_PROJECT}"
          puts pastel.dim("\nSet TTS_BACKEND=piper to use local piper")
        else
          puts "#{pastel.bold("Voices dir:")} #{Personality::TTS::VOICES_DIR}"
          puts pastel.dim("\nSet TTS_BACKEND=xtts to use XTTS on junkpile")
        end
      end

      def self.exit_on_failure?
        true
      end
    end
  end
end
