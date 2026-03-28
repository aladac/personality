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
    XTTS_PROJECT = "~/Projects/bt7274"
    XTTS_VENV = "#{XTTS_PROJECT}/.venv/bin/python"
    XTTS_SPEAKER = "#{XTTS_PROJECT}/finetune_output/bt7274_polish_speaker.pth"
    XTTS_REFERENCE = "#{XTTS_PROJECT}/bt_voices/diag_sp_spoke1pre_BE361_10_01_mcor_bt.wav"

    # Backend selection
    BACKEND = ENV.fetch("TTS_BACKEND", "xtts") # "piper" or "xtts"

    PIPER_VOICES_BASE_URL = "https://huggingface.co/rhasspy/piper-voices/resolve/main"

    class << self
      # --- Synthesis & Playback ---

      def speak(text, voice: nil, language: nil)
        stop_current
        voice ||= active_voice
        language ||= detect_language(text)

        FileUtils.mkdir_p(DATA_DIR)

        result = if BACKEND == "xtts"
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

        {speaking: true, voice: voice, pid: pid, backend: BACKEND}
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
        # Escape text for shell
        escaped_text = text.gsub("'", "'\\''")

        # Build Python command for XTTS synthesis
        python_script = <<~PYTHON
          import sys
          import torch
          from TTS.api import TTS

          text = '''#{escaped_text}'''
          language = '#{language}'

          tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to("cuda")
          model = tts.synthesizer.tts_model

          # Try to load speaker embedding, fall back to reference audio
          try:
              speaker = torch.load("#{XTTS_SPEAKER}")
              out = model.inference(
                  text=text,
                  language=language,
                  gpt_cond_latent=speaker["gpt_cond_latent"],
                  speaker_embedding=speaker["speaker_embedding"],
                  temperature=0.7
              )
          except:
              # Fall back to reference audio
              tts.tts_to_file(
                  text=text,
                  file_path="/tmp/xtts_output.wav",
                  speaker_wav="#{XTTS_REFERENCE}",
                  language=language
              )
              sys.exit(0)

          import torchaudio
          torchaudio.save("/tmp/xtts_output.wav", torch.tensor(out["wav"]).unsqueeze(0), 24000)
        PYTHON

        # Execute on remote host
        ssh_cmd = [
          "ssh", XTTS_HOST,
          "cd #{XTTS_PROJECT} && source .venv/bin/activate && python3 -c '#{python_script.gsub("'", "'\\''")}'"
        ]

        _, stderr, status = Open3.capture3(*ssh_cmd)

        unless status.success?
          return {error: "XTTS synthesis failed: #{stderr}"}
        end

        # Copy WAV back
        scp_cmd = ["scp", "#{XTTS_HOST}:/tmp/xtts_output.wav", WAV_FILE]
        _, stderr, status = Open3.capture3(*scp_cmd)

        unless status.success?
          return {error: "Failed to copy audio: #{stderr}"}
        end

        {synthesized: true}
      end

      def xtts_voice_available?(name)
        # Check if speaker embedding exists on junkpile
        cmd = "ssh #{XTTS_HOST} 'test -f #{XTTS_PROJECT}/finetune_output/#{name}_speaker.pth && echo yes || echo no'"
        result, = Open3.capture2(cmd)

        # bt7274 is the default voice with special path
        return true if name == "bt7274"

        result.strip == "yes"
      end

      def list_xtts_voices
        # List available speaker embeddings
        cmd = "ssh #{XTTS_HOST} 'ls #{XTTS_PROJECT}/finetune_output/*_speaker.pth 2>/dev/null || true'"
        result, = Open3.capture2(cmd)

        voices = result.lines.map do |line|
          name = File.basename(line.strip, "_speaker.pth")
          name = "bt7274" if name == "bt7274_polish"
          {name: name, path: line.strip, backend: "xtts"}
        end

        # Always include bt7274 if embedding exists
        if voices.empty?
          [{name: "bt7274", path: XTTS_SPEAKER, backend: "xtts"}]
        else
          voices.uniq { |v| v[:name] }
        end
      end

      # --- Piper Backend ---

      def synthesize_piper(text, voice:)
        model_path = find_voice(voice)
        return {error: "Voice not found: #{voice}"} unless model_path

        piper_bin = find_piper
        return {error: "piper not installed"} unless piper_bin

        _, stderr, status = Open3.capture3(
          piper_bin, "--model", model_path, "--output_file", WAV_FILE,
          stdin_data: text
        )

        return {error: "piper failed: #{stderr}"} unless status.success?

        {synthesized: true}
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
