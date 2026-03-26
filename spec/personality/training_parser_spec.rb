# frozen_string_literal: true

require "personality"
require "personality/training_parser"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Personality::TrainingParser do
  let(:parser) { described_class.new }
  let(:tmpdir) { Dir.mktmpdir("psn_parser_test") }

  after { FileUtils.rm_rf(tmpdir) }

  def write_file(name, content)
    path = File.join(tmpdir, name)
    File.write(path, content)
    path
  end

  describe "#parse_file" do
    context "with YAML" do
      it "parses tag, version, format, and memories" do
        path = write_file("test.yml", <<~YAML)
          tag: testbot
          version: "1.0"
          memories:
            - subject: self.identity.name
              content: TestBot
        YAML

        doc = parser.parse_file(path)
        expect(doc.tag).to eq("testbot")
        expect(doc.version).to eq("1.0")
        expect(doc.format).to eq("yml")
        expect(doc.source).to eq(File.expand_path(path))
        expect(doc.memories.size).to eq(1)
        expect(doc.memories.first.subject).to eq("self.identity.name")
        expect(doc.memories.first.content).to eq("TestBot")
      end

      it "extracts legacy identity section" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          identity:
            name: Bot
            type: assistant
        YAML

        doc = parser.parse_file(path)
        subjects = doc.memories.map(&:subject)
        expect(subjects).to include("identity.name", "identity.type")
      end

      it "skips nil identity values" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          identity:
            name: Bot
            empty_field:
        YAML

        doc = parser.parse_file(path)
        subjects = doc.memories.map(&:subject)
        expect(subjects).to include("identity.name")
        expect(subjects).not_to include("identity.empty_field")
      end

      it "handles non-hash identity gracefully" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          identity: "just a string"
        YAML

        doc = parser.parse_file(path)
        expect(doc.memories).to eq([])
      end

      it "extracts preferences as hash" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          preferences:
            identity:
              name: Bot
            tts:
              voice: bt7274
        YAML

        doc = parser.parse_file(path)
        expect(doc.preferences).to be_a(Hash)
        expect(doc.preferences["identity"]["name"]).to eq("Bot")
      end

      it "treats non-hash preferences as empty" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          preferences: "not a hash"
        YAML

        doc = parser.parse_file(path)
        expect(doc.preferences).to eq({})
      end

      it "handles array content in memories" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          memories:
            - subject: self.identity.addressed_as
              content:
                - Pilot
                - Commander
        YAML

        doc = parser.parse_file(path)
        expect(doc.memories.first.content).to eq("Pilot, Commander")
      end

      it "skips non-hash memory entries" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          memories:
            - subject: valid
              content: data
            - just_a_string
        YAML

        doc = parser.parse_file(path)
        expect(doc.memories.size).to eq(1)
      end

      it "skips entries missing subject or content" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          memories:
            - subject: valid
              content: data
            - subject: no_content
            - content: no_subject
        YAML

        doc = parser.parse_file(path)
        expect(doc.memories.size).to eq(1)
      end

      it "skips memories with empty string content" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          memories:
            - subject: empty
              content: ""
            - subject: valid
              content: data
        YAML

        doc = parser.parse_file(path)
        expect(doc.memories.size).to eq(1)
        expect(doc.memories.first.subject).to eq("valid")
      end

      it "handles missing memories key" do
        path = write_file("test.yml", "tag: bot\n")
        doc = parser.parse_file(path)
        expect(doc.memories).to eq([])
      end

      it "handles non-array memories" do
        path = write_file("test.yml", <<~YAML)
          tag: bot
          memories: "not an array"
        YAML

        doc = parser.parse_file(path)
        expect(doc.memories).to eq([])
      end

      it "defaults tag and version to empty string" do
        path = write_file("test.yml", <<~YAML)
          memories:
            - subject: x
              content: y
        YAML

        doc = parser.parse_file(path)
        expect(doc.tag).to eq("")
        expect(doc.version).to eq("")
      end

      it "raises for non-hash YAML root" do
        path = write_file("test.yml", "- item1\n- item2\n")
        expect { parser.parse_file(path) }.to raise_error(ArgumentError, /YAML root must be a hash/)
      end

      it "parses .yaml extension" do
        path = write_file("test.yaml", "tag: yamlbot\nmemories: []\n")
        doc = parser.parse_file(path)
        expect(doc.tag).to eq("yamlbot")
        expect(doc.format).to eq("yaml")
      end
    end

    context "with JSON" do
      it "parses tag, version, and memories" do
        path = write_file("test.json", JSON.generate({
          tag: "jsonbot", version: "2.0",
          memories: [{subject: "self.name", content: "JsonBot"}]
        }))

        doc = parser.parse_file(path)
        expect(doc.tag).to eq("jsonbot")
        expect(doc.version).to eq("2.0")
        expect(doc.format).to eq("json")
        expect(doc.memories.size).to eq(1)
      end

      it "extracts top-level identity fields" do
        path = write_file("test.json", JSON.generate({
          name: "Bot", description: "A bot", personality: "friendly", purpose: "testing"
        }))

        doc = parser.parse_file(path)
        subjects = doc.memories.map(&:subject)
        expect(subjects).to include(
          "identity.name", "identity.description",
          "identity.personality", "identity.purpose"
        )
      end

      it "skips non-string identity fields" do
        path = write_file("test.json", JSON.generate({name: "Bot", description: 42}))
        doc = parser.parse_file(path)
        expect(doc.memories.size).to eq(1)
      end

      it "extracts knowledge graph" do
        path = write_file("test.json", JSON.generate({
          knowledge: [
            {"@type" => "fact", "description" => "Earth is round"},
            {"@type" => "rule", "value" => "Be kind"}
          ]
        }))

        doc = parser.parse_file(path)
        expect(doc.memories.size).to eq(2)
        expect(doc.memories[0].subject).to eq("fact")
        expect(doc.memories[0].content).to eq("Earth is round")
        expect(doc.memories[1].content).to eq("Be kind")
      end

      it "defaults knowledge @type to knowledge.general" do
        path = write_file("test.json", JSON.generate({
          knowledge: [{"description" => "something"}]
        }))

        doc = parser.parse_file(path)
        expect(doc.memories.first.subject).to eq("knowledge.general")
      end

      it "skips knowledge items without content" do
        path = write_file("test.json", JSON.generate({
          knowledge: [{"@type" => "empty"}, {"@type" => "ok", "description" => "data"}]
        }))

        doc = parser.parse_file(path)
        expect(doc.memories.size).to eq(1)
      end

      it "skips non-hash knowledge items" do
        path = write_file("test.json", JSON.generate({
          knowledge: ["string", {"@type" => "ok", "description" => "data"}]
        }))

        doc = parser.parse_file(path)
        expect(doc.memories.size).to eq(1)
      end

      it "handles non-array knowledge" do
        path = write_file("test.json", JSON.generate({knowledge: "not array"}))
        doc = parser.parse_file(path)
        expect(doc.memories).to eq([])
      end

      it "handles non-hash JSON preferences" do
        path = write_file("test.json", JSON.generate({tag: "bot", preferences: "str"}))
        doc = parser.parse_file(path)
        expect(doc.preferences).to eq({})
      end

      it "raises for non-object JSON root" do
        path = write_file("test.json", "[1, 2, 3]")
        expect { parser.parse_file(path) }.to raise_error(ArgumentError, /JSON root must be an object/)
      end

      it "parses .jsonld extension" do
        path = write_file("test.jsonld", JSON.generate({tag: "ldbot"}))
        doc = parser.parse_file(path)
        expect(doc.tag).to eq("ldbot")
        expect(doc.format).to eq("jsonld")
      end
    end

    it "raises for unsupported file format" do
      path = write_file("test.txt", "hello")
      expect { parser.parse_file(path) }.to raise_error(ArgumentError, /Unsupported file format/)
    end

    it "raises for nonexistent file" do
      expect { parser.parse_file("/nonexistent/file.yml") }.to raise_error(Errno::ENOENT)
    end
  end

  describe "#list_files" do
    it "returns empty for nonexistent directory" do
      expect(parser.list_files("/nonexistent")).to eq([])
    end

    it "finds yml, yaml, json, jsonld sorted by name" do
      write_file("beta.yml", "tag: b")
      write_file("alpha.yaml", "tag: a")
      write_file("gamma.json", "{}")
      write_file("delta.jsonld", "{}")
      write_file("readme.txt", "ignore")

      files = parser.list_files(tmpdir)
      basenames = files.map { |f| File.basename(f) }
      expect(basenames).to eq(%w[alpha.yaml beta.yml delta.jsonld gamma.json])
    end
  end

  describe "#validate" do
    it "returns valid for file with memories" do
      path = write_file("good.yml", <<~YAML)
        tag: bot
        memories:
          - subject: test
            content: data
      YAML

      valid, message = parser.validate(path)
      expect(valid).to be true
      expect(message).to include("1 memories")
      expect(message).to include("tag=bot")
    end

    it "returns invalid for empty memories" do
      path = write_file("empty.yml", "tag: bot\n")
      valid, message = parser.validate(path)
      expect(valid).to be false
      expect(message).to include("No memories")
    end

    it "returns invalid for bad file" do
      valid, message = parser.validate("/nonexistent.yml")
      expect(valid).to be false
    end
  end

  describe Personality::TrainingDocument do
    it "reports memory count" do
      doc = described_class.new(memories: [
        Personality::TrainingMemory.new(subject: "a", content: "b"),
        Personality::TrainingMemory.new(subject: "c", content: "d")
      ])
      expect(doc.count).to eq(2)
    end
  end
end
