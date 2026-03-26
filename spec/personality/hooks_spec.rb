# frozen_string_literal: true

require "personality/hooks"
require "tmpdir"

RSpec.describe Personality::Hooks do
  let(:tmp_log) { File.join(Dir.tmpdir, "psn_hooks_test_#{$$}.jsonl") }
  let(:tmp_dir) { File.dirname(tmp_log) }

  before do
    stub_const("Personality::Hooks::LOG_FILE", tmp_log)
    stub_const("Personality::Hooks::LOG_DIR", tmp_dir)
    described_class.reset_config!
  end

  after do
    FileUtils.rm_f(tmp_log)
  end

  describe ".log" do
    it "writes a JSONL entry to the log file" do
      described_class.log("TestEvent")

      lines = File.readlines(tmp_log)
      expect(lines.length).to eq(1)

      entry = JSON.parse(lines.first)
      expect(entry["event"]).to eq("TestEvent")
      expect(entry["ts"]).to match(/\d{4}-\d{2}-\d{2}/)
      expect(entry).to have_key("cwd")
    end

    it "includes data fields in the entry" do
      described_class.log("TestEvent", {"tool_name" => "Read", "file_path" => "/foo/bar.rb"})

      entry = JSON.parse(File.readlines(tmp_log).first)
      expect(entry["tool_name"]).to eq("Read")
      expect(entry["file_path"]).to eq("/foo/bar.rb")
    end

    it "skips hook_event_name field" do
      described_class.log("TestEvent", {"hook_event_name" => "PreToolUse", "other" => "value"})

      entry = JSON.parse(File.readlines(tmp_log).first)
      expect(entry).not_to have_key("hook_event_name")
      expect(entry["other"]).to eq("value")
    end

    it "appends multiple entries" do
      described_class.log("Event1")
      described_class.log("Event2")

      lines = File.readlines(tmp_log)
      expect(lines.length).to eq(2)
    end
  end

  describe ".truncate" do
    it "returns short strings unchanged" do
      expect(described_class.truncate("hello")).to eq("hello")
    end

    it "truncates long strings with ellipsis" do
      long = "a" * 100
      result = described_class.truncate(long)
      expect(result.length).to eq(50)
      expect(result).to end_with("...")
    end

    it "respects custom max_length" do
      result = described_class.truncate("hello world", max_length: 8)
      expect(result).to eq("hello...")
    end
  end

  describe ".preserved_key?" do
    it "preserves known path fields" do
      expect(described_class.preserved_key?("file_path")).to be true
      expect(described_class.preserved_key?("cwd")).to be true
      expect(described_class.preserved_key?("transcript_path")).to be true
    end

    it "preserves fields ending in _path or _dir" do
      expect(described_class.preserved_key?("output_path")).to be true
      expect(described_class.preserved_key?("cache_dir")).to be true
    end

    it "does not preserve arbitrary fields" do
      expect(described_class.preserved_key?("content")).to be false
      expect(described_class.preserved_key?("message")).to be false
    end
  end

  describe ".process_value" do
    it "passes through nil, booleans, and numbers" do
      expect(described_class.process_value("k", nil)).to be_nil
      expect(described_class.process_value("k", true)).to be true
      expect(described_class.process_value("k", 42)).to eq(42)
      expect(described_class.process_value("k", 3.14)).to eq(3.14)
    end

    it "truncates regular string fields" do
      long = "x" * 100
      result = described_class.process_value("content", long)
      expect(result.length).to eq(50)
    end

    it "preserves path fields" do
      long_path = "/very/long/path/" + "a" * 100
      result = described_class.process_value("file_path", long_path)
      expect(result).to eq(long_path)
    end

    it "truncates arrays to 5 items" do
      arr = (1..10).to_a
      result = described_class.process_value("items", arr)
      expect(result.length).to eq(6) # 5 items + "...+5 more"
      expect(result.last).to eq("...+5 more")
    end

    it "recurses into hashes" do
      data = {"nested" => {"content" => "x" * 100}}
      result = described_class.process_value("top", data)
      expect(result["nested"]["content"].length).to eq(50)
    end
  end

  describe ".generate_hooks_json" do
    it "returns valid JSON" do
      json = described_class.generate_hooks_json
      parsed = JSON.parse(json)
      expect(parsed).to have_key("hooks")
    end

    it "includes all hook events" do
      parsed = JSON.parse(described_class.generate_hooks_json)
      events = parsed["hooks"].keys
      expect(events).to include(
        "PreToolUse", "PostToolUse", "Stop", "SubagentStop",
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreCompact", "Notification"
      )
    end
  end

  describe ".read_stdin_json" do
    it "returns nil when stdin is a tty" do
      allow($stdin).to receive(:tty?).and_return(true)
      expect(described_class.read_stdin_json).to be_nil
    end

    it "parses JSON from stdin" do
      allow($stdin).to receive(:tty?).and_return(false)
      allow($stdin).to receive(:read).and_return('{"key": "value"}')
      expect(described_class.read_stdin_json).to eq({"key" => "value"})
    end

    it "returns nil on invalid JSON" do
      allow($stdin).to receive(:tty?).and_return(false)
      allow($stdin).to receive(:read).and_return("not json")
      expect(described_class.read_stdin_json).to be_nil
    end
  end
end
