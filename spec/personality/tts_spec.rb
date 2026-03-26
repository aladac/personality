# frozen_string_literal: true

require "personality/tts"
require "tmpdir"

RSpec.describe Personality::TTS do
  let(:tmp_data) { File.join(Dir.tmpdir, "psn_tts_test_#{$$}_#{rand(10000)}") }

  before do
    stub_const("Personality::TTS::DATA_DIR", tmp_data)
    stub_const("Personality::TTS::PID_FILE", File.join(tmp_data, "tts.pid"))
    stub_const("Personality::TTS::WAV_FILE", File.join(tmp_data, "tts_current.wav"))
    stub_const("Personality::TTS::NATURAL_STOP_FLAG", File.join(tmp_data, "tts_natural_stop"))
  end

  after do
    FileUtils.rm_rf(tmp_data)
  end

  describe ".find_voice" do
    it "returns path for installed voice" do
      path = described_class.find_voice("bt7274")
      expect(path).to eq(File.join(described_class::VOICES_DIR, "bt7274.onnx"))
    end

    it "returns nil for nonexistent voice" do
      expect(described_class.find_voice("nonexistent_voice_xyz")).to be_nil
    end
  end

  describe ".list_voices" do
    it "returns array of voice hashes" do
      voices = described_class.list_voices
      expect(voices).to be_an(Array)
      expect(voices.length).to be > 0

      voice = voices.first
      expect(voice).to have_key(:name)
      expect(voice).to have_key(:path)
      expect(voice).to have_key(:size_mb)
    end

    it "includes bt7274 voice" do
      names = described_class.list_voices.map { |v| v[:name] }
      expect(names).to include("bt7274")
    end
  end

  describe ".active_voice" do
    it "returns default when env not set" do
      allow(ENV).to receive(:fetch).with("PERSONALITY_VOICE", "en_US-lessac-medium").and_return("en_US-lessac-medium")
      expect(described_class.active_voice).to eq("en_US-lessac-medium")
    end

    it "uses PERSONALITY_VOICE env var" do
      allow(ENV).to receive(:fetch).with("PERSONALITY_VOICE", "en_US-lessac-medium").and_return("bt7274")
      expect(described_class.active_voice).to eq("bt7274")
    end
  end

  describe "interrupt protocol" do
    describe ".mark_natural_stop" do
      it "creates the flag file" do
        described_class.mark_natural_stop
        expect(File.exist?(described_class::NATURAL_STOP_FLAG)).to be true
      end
    end

    describe ".interrupt_check" do
      context "when natural stop flag is set" do
        before { described_class.mark_natural_stop }

        it "returns continue action" do
          result = described_class.interrupt_check
          expect(result[:action]).to eq(:continue)
          expect(result[:reason]).to eq("natural_stop")
        end

        it "removes the flag" do
          described_class.interrupt_check
          expect(File.exist?(described_class::NATURAL_STOP_FLAG)).to be false
        end
      end

      context "when natural stop flag is absent" do
        it "returns stopped action" do
          result = described_class.interrupt_check
          expect(result[:action]).to eq(:stopped)
          expect(result[:reason]).to eq("user_interrupt")
        end
      end
    end

    describe ".clear_natural_stop_flag" do
      it "removes the flag if present" do
        described_class.mark_natural_stop
        described_class.clear_natural_stop_flag
        expect(File.exist?(described_class::NATURAL_STOP_FLAG)).to be false
      end

      it "does not raise if flag absent" do
        expect { described_class.clear_natural_stop_flag }.not_to raise_error
      end
    end
  end

  describe ".stop_current" do
    it "returns false when no PID file" do
      expect(described_class.stop_current).to be false
    end

    it "returns false for stale PID" do
      FileUtils.mkdir_p(tmp_data)
      File.write(described_class::PID_FILE, "999999999")
      expect(described_class.stop_current).to be false
    end
  end

  describe ".speak" do
    it "returns error when piper not found" do
      allow(described_class).to receive(:find_piper).and_return(nil)
      result = described_class.speak("hello", voice: "bt7274")
      expect(result[:error]).to match(/piper not installed/)
    end

    it "returns error for nonexistent voice" do
      result = described_class.speak("hello", voice: "nonexistent_xyz")
      expect(result[:error]).to match(/Voice not found/)
    end
  end

  describe ".download_voice" do
    it "reports existing voice" do
      result = described_class.download_voice("bt7274")
      expect(result[:exists]).to be true
    end

    it "rejects invalid format" do
      result = described_class.download_voice("invalidname")
      expect(result[:error]).to match(/Invalid voice format/)
    end
  end
end
