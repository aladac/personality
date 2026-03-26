# frozen_string_literal: true

require "open3"
require "fileutils"

module Personality
  module TTS
    VOICES_DIR = File.join(Dir.home, ".local", "share", "psn", "voices")
    DATA_DIR = File.join(Dir.home, ".local", "share", "personality", "data")
    DEFAULT_VOICE = "en_US-lessac-medium"

    PID_FILE = File.join(DATA_DIR, "tts.pid")
    WAV_FILE = File.join(DATA_DIR, "tts_current.wav")
    NATURAL_STOP_FLAG = File.join(DATA_DIR, "tts_natural_stop")

    PIPER_VOICES_BASE_URL = "https://huggingface.co/rhasspy/piper-voices/resolve/main"

    class << self
      # --- Synthesis & Playback ---

      def speak(text, voice: nil)
        stop_current
        voice ||= active_voice

        model_path = find_voice(voice)
        return {error: "Voice not found: #{voice}"} unless model_path

        piper_bin = find_piper
        return {error: "piper not installed"} unless piper_bin

        FileUtils.mkdir_p(DATA_DIR)

        # Synthesize to WAV
        stdout, stderr, status = Open3.capture3(
          piper_bin, "--model", model_path, "--output_file", WAV_FILE,
          stdin_data: text
        )
        return {error: "piper failed: #{stderr}"} unless status.success?

        # Play audio (macOS: afplay, Linux: aplay)
        player = player_command
        return {error: "No audio player found"} unless player

        pid = spawn(player, WAV_FILE, [:out, :err] => "/dev/null")
        save_pid(pid)

        {speaking: true, voice: voice, pid: pid}
      end

      def speak_and_wait(text, voice: nil)
        result = speak(text, voice: voice)
        return result if result[:error]

        Process.wait(result[:pid])
        clear_pid
        result.merge(speaking: false)
      rescue Errno::ECHILD
        clear_pid
        result
      end

      def stop_current
        return false unless File.exist?(PID_FILE)

        pid = File.read(PID_FILE).strip.to_i
        Process.kill("TERM", pid)
        clear_pid
        true
      rescue Errno::ESRCH, Errno::EPERM
        clear_pid
        false
      end

      # --- Interrupt Protocol ---

      def mark_natural_stop
        FileUtils.mkdir_p(DATA_DIR)
        FileUtils.touch(NATURAL_STOP_FLAG)
      end

      def interrupt_check
        if File.exist?(NATURAL_STOP_FLAG)
          File.delete(NATURAL_STOP_FLAG)
          {action: :continue, reason: "natural_stop"}
        else
          stopped = stop_current
          {action: :stopped, reason: "user_interrupt", was_playing: stopped}
        end
      end

      def clear_natural_stop_flag
        File.delete(NATURAL_STOP_FLAG) if File.exist?(NATURAL_STOP_FLAG)
      end

      # --- Voice Management ---

      def find_voice(name)
        path = File.join(VOICES_DIR, "#{name}.onnx")
        File.exist?(path) ? path : nil
      end

      def list_voices
        return [] unless Dir.exist?(VOICES_DIR)

        Dir.glob(File.join(VOICES_DIR, "*.onnx")).map do |path|
          name = File.basename(path, ".onnx")
          size_mb = File.size(path) / (1024.0 * 1024)
          {name: name, path: path, size_mb: size_mb.round(1)}
        end.sort_by { |v| v[:name].downcase }
      end

      def download_voice(voice_name)
        FileUtils.mkdir_p(VOICES_DIR)

        model_path = File.join(VOICES_DIR, "#{voice_name}.onnx")
        config_path = File.join(VOICES_DIR, "#{voice_name}.onnx.json")

        return {exists: true, voice: voice_name} if File.exist?(model_path)

        parts = voice_name.split("-")
        return {error: "Invalid voice format"} if parts.length < 2

        lang = parts[0]         # en_US
        lang_short = lang.split("_")[0]  # en
        name = parts[1]         # lessac
        quality = parts[2] || "medium"

        model_url = "#{PIPER_VOICES_BASE_URL}/#{lang_short}/#{lang}/#{name}/#{quality}/#{voice_name}.onnx"
        config_url = "#{PIPER_VOICES_BASE_URL}/#{lang_short}/#{lang}/#{name}/#{quality}/#{voice_name}.onnx.json"

        require "net/http"
        require "uri"

        download_file(model_url, model_path)
        download_file(config_url, config_path)

        size_mb = File.size(model_path) / (1024.0 * 1024)
        {installed: true, voice: voice_name, size_mb: size_mb.round(1)}
      rescue => e
        FileUtils.rm_f(model_path)
        FileUtils.rm_f(config_path)
        {error: "Download failed: #{e.message}"}
      end

      def active_voice
        ENV.fetch("PERSONALITY_VOICE", DEFAULT_VOICE)
      end

      private

      def find_piper
        # Check common locations
        [
          File.join(Dir.home, ".local", "bin", "piper"),
          `which piper 2>/dev/null`.strip
        ].find { |p| !p.empty? && File.executable?(p) }
      end

      def player_command
        if RUBY_PLATFORM.include?("darwin")
          "afplay"
        elsif system("which aplay > /dev/null 2>&1")
          "aplay"
        end
      end

      def save_pid(pid)
        File.write(PID_FILE, pid.to_s)
      end

      def clear_pid
        FileUtils.rm_f(PID_FILE)
        FileUtils.rm_f(WAV_FILE)
      end

      def download_file(url, dest)
        uri = URI.parse(url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request) do |response|
            raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

            File.open(dest, "wb") do |file|
              response.read_body { |chunk| file.write(chunk) }
            end
          end
        end
      end
    end
  end
end
