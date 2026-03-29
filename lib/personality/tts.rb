# frozen_string_literal: true

require "open3"
require "fileutils"
require "net/http"
require "json"

module Personality
  module TTS
    VOICES_DIR = File.join(Dir.home, ".local", "share", "psn", "voices")
    DATA_DIR = File.join(Dir.home, ".local", "share", "personality", "data")
    DEFAULT_VOICE = "bt7274"

    PID_FILE = File.join(DATA_DIR, "tts.pid")
    WAV_FILE = File.join(DATA_DIR, "tts_current.wav")
    NATURAL_STOP_FLAG = File.join(DATA_DIR, "tts_natural_stop")

    # XTTS configuration
    XTTS_HOST = ENV.fetch("XTTS_HOST", "junkpile")
    XTTS_PORT = ENV.fetch("XTTS_PORT", "5002")
    XTTS_URL = "http://#{XTTS_HOST}:#{XTTS_PORT}"

    # Backend selection: "auto" selects based on language (pl=xtts, en=piper)
    BACKEND = ENV.fetch("TTS_BACKEND", "auto") # "piper", "xtts", or "auto"

    PIPER_VOICES_BASE_URL = "https://huggingface.co/rhasspy/piper-voices/resolve/main"

    # Audio padding (matches XTTS server)
    PADDING_MS = 250

    class << self
      # --- Synthesis & Playback ---

      def speak(text, voice: nil, language: nil)
        stop_current
        voice ||= active_voice
        language ||= detect_language(text)

        FileUtils.mkdir_p(DATA_DIR)

        # Select backend: auto mode uses XTTS for Polish, piper for English
        backend = select_backend(language)

        result = if backend == "xtts"
          synthesize_xtts(text, voice: voice, language: language)
        else
          synthesize_piper(text, voice: voice)
        end

        return result if result[:error]

        # Play audio (macOS: afplay, Linux: aplay)
        player = player_command
        return {error: "No audio player found"} unless player

        pid = spawn(player, WAV_FILE, [:out, :err] => "/dev/null")
        save_pid(pid)

        {speaking: true, voice: voice, pid: pid, backend: backend}
      end

      def speak_and_wait(text, voice: nil, language: nil)
        result = speak(text, voice: voice, language: language)
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
        # For XTTS, check if speaker embedding exists
        if BACKEND == "xtts"
          # XTTS voices are speaker embeddings on junkpile
          return name if xtts_voice_available?(name)
          return nil
        end

        # Piper: check for .onnx file
        path = File.join(VOICES_DIR, "#{name}.onnx")
        File.exist?(path) ? path : nil
      end

      def list_voices
        if BACKEND == "xtts"
          list_xtts_voices
        else
          list_piper_voices
        end
      end

      def download_voice(voice_name)
        if BACKEND == "xtts"
          {error: "XTTS voices are pre-installed on #{XTTS_HOST}"}
        else
          download_piper_voice(voice_name)
        end
      end

      def active_voice
        ENV.fetch("PERSONALITY_VOICE", DEFAULT_VOICE)
      end

      def backend
        BACKEND
      end

      private

      # --- XTTS Backend ---

      def synthesize_xtts(text, voice:, language:)
        uri = URI.parse("#{XTTS_URL}/synthesize")

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({text: text, language: language})

        response = Net::HTTP.start(uri.host, uri.port, read_timeout: 30) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          return {error: "XTTS synthesis failed: #{response.code} #{response.body}"}
        end

        File.open(WAV_FILE, "wb") { |f| f.write(response.body) }
        {synthesized: true}
      rescue Errno::ECONNREFUSED
        {error: "XTTS server not running on #{XTTS_HOST}:#{XTTS_PORT}"}
      rescue Net::ReadTimeout
        {error: "XTTS synthesis timed out"}
      end

      def xtts_voice_available?(name)
        # bt7274 is the only trained voice currently
        name == "bt7274"
      end

      def list_xtts_voices
        # Check if server is healthy
        uri = URI.parse("#{XTTS_URL}/health")
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          [{name: "bt7274", backend: "xtts", server: "#{XTTS_HOST}:#{XTTS_PORT}"}]
        else
          []
        end
      rescue Errno::ECONNREFUSED
        []
      end

      # --- Piper Backend ---

      def synthesize_piper(text, voice:)
        model_path = find_voice(voice)
        return {error: "Voice not found: #{voice}"} unless model_path

        piper_bin = find_piper
        return {error: "piper not installed"} unless piper_bin

        raw_wav = "#{WAV_FILE}.raw"
        _, stderr, status = Open3.capture3(
          piper_bin, "--model", model_path, "--output_file", raw_wav,
          stdin_data: text
        )

        return {error: "piper failed: #{stderr}"} unless status.success?

        # Add 250ms silence at start (matches XTTS padding)
        add_silence_padding(raw_wav, WAV_FILE)

        {synthesized: true}
      end

      def add_silence_padding(input_wav, output_wav)
        sox_bin = `which sox 2>/dev/null`.strip
        padding_sec = PADDING_MS / 1000.0

        if !sox_bin.empty? && File.executable?(sox_bin)
          # Use sox to pad silence at start
          system(sox_bin, input_wav, output_wav, "pad", padding_sec.to_s, "0",
            [:out, :err] => "/dev/null")
          FileUtils.rm_f(input_wav)
        else
          # Fallback: just rename (no padding)
          FileUtils.mv(input_wav, output_wav)
        end
      end

      def find_piper
        [
          File.join(Dir.home, ".local", "bin", "piper"),
          `which piper 2>/dev/null`.strip
        ].find { |p| !p.empty? && File.executable?(p) }
      end

      def list_piper_voices
        return [] unless Dir.exist?(VOICES_DIR)

        Dir.glob(File.join(VOICES_DIR, "*.onnx")).map do |path|
          name = File.basename(path, ".onnx")
          size_mb = File.size(path) / (1024.0 * 1024)
          {name: name, path: path, size_mb: size_mb.round(1), backend: "piper"}
        end.sort_by { |v| v[:name].downcase }
      end

      def download_piper_voice(voice_name)
        FileUtils.mkdir_p(VOICES_DIR)

        model_path = File.join(VOICES_DIR, "#{voice_name}.onnx")
        config_path = File.join(VOICES_DIR, "#{voice_name}.onnx.json")

        return {exists: true, voice: voice_name} if File.exist?(model_path)

        parts = voice_name.split("-")
        return {error: "Invalid voice format"} if parts.length < 2

        lang = parts[0]
        lang_short = lang.split("_")[0]
        name = parts[1]
        quality = parts[2] || "medium"

        model_url = "#{PIPER_VOICES_BASE_URL}/#{lang_short}/#{lang}/#{name}/#{quality}/#{voice_name}.onnx"
        config_url = "#{PIPER_VOICES_BASE_URL}/#{lang_short}/#{lang}/#{name}/#{quality}/#{voice_name}.onnx.json"

        download_file(model_url, model_path)
        download_file(config_url, config_path)

        size_mb = File.size(model_path) / (1024.0 * 1024)
        {installed: true, voice: voice_name, size_mb: size_mb.round(1)}
      rescue => e
        FileUtils.rm_f(model_path)
        FileUtils.rm_f(config_path)
        {error: "Download failed: #{e.message}"}
      end

      # --- Utilities ---

      def detect_language(text)
        # Simple heuristic: check for Polish characters
        polish_chars = /[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]/
        text.match?(polish_chars) ? "pl" : "en"
      end

      def player_command
        if RUBY_PLATFORM.include?("darwin")
          "afplay"
        elsif system("which aplay > /dev/null 2>&1")
          "aplay"
        end
      end

      def select_backend(language)
        return BACKEND unless BACKEND == "auto"

        # Polish uses XTTS (trained voice), English uses piper (fast)
        language == "pl" ? "xtts" : "piper"
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
