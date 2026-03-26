# frozen_string_literal: true

require "personality/context"
require "tmpdir"

RSpec.describe Personality::Context do
  let(:tmp_dir) { File.join(Dir.tmpdir, "psn_context_test_#{$$}_#{rand(10000)}") }
  let(:session_id) { "test-session-#{rand(10000)}" }

  before do
    stub_const("Personality::Context::TRACKING_DIR", tmp_dir)
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe ".track_read" do
    it "records a file path" do
      described_class.track_read("/foo/bar.rb", session_id: session_id)
      expect(described_class.check("/foo/bar.rb", session_id: session_id)).to be true
    end

    it "also records the resolved path" do
      described_class.track_read("./relative/file.rb", session_id: session_id)
      resolved = File.expand_path("./relative/file.rb")
      expect(described_class.check(resolved, session_id: session_id)).to be true
    end

    it "ignores nil file_path" do
      expect { described_class.track_read(nil, session_id: session_id) }.not_to raise_error
    end

    it "ignores empty file_path" do
      expect { described_class.track_read("", session_id: session_id) }.not_to raise_error
    end

    it "does not duplicate entries" do
      described_class.track_read("/foo/bar.rb", session_id: session_id)
      described_class.track_read("/foo/bar.rb", session_id: session_id)

      files = described_class.list(session_id: session_id)
      expect(files.count("/foo/bar.rb")).to eq(1)
    end
  end

  describe ".check" do
    it "returns false for untracked files" do
      expect(described_class.check("/not/tracked.rb", session_id: session_id)).to be false
    end

    it "matches by absolute path" do
      abs = File.expand_path("/tmp/test_file.rb")
      described_class.track_read(abs, session_id: session_id)
      expect(described_class.check(abs, session_id: session_id)).to be true
    end
  end

  describe ".list" do
    it "returns empty array for new session" do
      expect(described_class.list(session_id: session_id)).to eq([])
    end

    it "returns tracked files" do
      described_class.track_read("/a.rb", session_id: session_id)
      described_class.track_read("/b.rb", session_id: session_id)

      files = described_class.list(session_id: session_id)
      expect(files).to include("/a.rb", "/b.rb")
    end
  end

  describe ".clear" do
    it "removes all tracked files" do
      described_class.track_read("/a.rb", session_id: session_id)
      described_class.clear(session_id: session_id)
      expect(described_class.list(session_id: session_id)).to eq([])
    end

    it "does not raise for nonexistent session" do
      expect { described_class.clear(session_id: "nonexistent") }.not_to raise_error
    end
  end

  describe ".current_session_id" do
    it "returns CLAUDE_SESSION_ID from env" do
      allow(ENV).to receive(:fetch).with("CLAUDE_SESSION_ID", "default").and_return("abc123")
      expect(described_class.current_session_id).to eq("abc123")
    end

    it "returns 'default' when env not set" do
      allow(ENV).to receive(:fetch).with("CLAUDE_SESSION_ID", "default").and_call_original
      expect(described_class.current_session_id).to be_a(String)
    end
  end
end
