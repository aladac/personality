# frozen_string_literal: true

require "personality/init"
require "tmpdir"

RSpec.describe Personality::Init do
  subject(:init) { described_class.new(auto_yes: true) }

  before do
    # Suppress output
    allow($stdout).to receive(:write)
    allow($stdout).to receive(:print)
    allow($stderr).to receive(:write)
  end

  describe "#run" do
    it "completes without raising" do
      # Stub all external commands to avoid side effects
      allow(init).to receive(:run_command).and_return(true)
      allow(init).to receive(:command_exists?).and_return(true)
      allow(init).to receive(:command_version).and_return("1.0.0")
      allow(init).to receive(:find_executable).and_return("/usr/bin/uv")
      allow(init).to receive(:model_installed?).and_return(true)
      allow(init).to receive(:ensure_ollama_running)

      # Stub database creation
      stub_const("Personality::Init::DB_PATH", File.join(Dir.tmpdir, "psn_test_#{$$}.db"))

      expect { init.run }.not_to raise_error

      # Cleanup
      FileUtils.rm_f(Personality::Init::DB_PATH)
    end
  end

  describe "#confirm?" do
    context "with auto_yes" do
      it "returns true without prompting" do
        expect(init.send(:confirm?, "Install?")).to be true
      end
    end

    context "without auto_yes" do
      subject(:init) { described_class.new(auto_yes: false) }

      it "returns true for y input" do
        allow($stdin).to receive(:gets).and_return("y\n")
        expect(init.send(:confirm?, "Install?")).to be true
      end

      it "returns true for empty input" do
        allow($stdin).to receive(:gets).and_return("\n")
        expect(init.send(:confirm?, "Install?")).to be true
      end

      it "returns false for n input" do
        allow($stdin).to receive(:gets).and_return("n\n")
        expect(init.send(:confirm?, "Install?")).to be false
      end
    end
  end

  describe "#command_exists?" do
    it "returns true for an existing command" do
      expect(init.send(:command_exists?, "ruby")).to be true
    end

    it "returns false for a nonexistent command" do
      expect(init.send(:command_exists?, "definitely_not_a_command_xyz")).to be false
    end
  end

  describe "#command_version" do
    it "returns version string for a valid command" do
      result = init.send(:command_version, "ruby", "--version")
      expect(result).to match(/ruby/i)
    end

    it "returns nil for a nonexistent command" do
      result = init.send(:command_version, "definitely_not_a_command_xyz", "--version")
      expect(result).to be_nil
    end
  end

  describe "#brew_available?" do
    it "returns a boolean" do
      expect(init.send(:brew_available?)).to be(true).or be(false)
    end
  end

  describe "setup_database" do
    let(:tmp_db) { File.join(Dir.tmpdir, "psn_init_test_#{$$}_#{rand(10000)}.db") }

    after do
      Personality::DB.reset!
      FileUtils.rm_f(tmp_db)
    end

    it "creates database and schema in a temp path" do
      stub_const("Personality::DB::DB_PATH", tmp_db)
      stub_const("Personality::Init::DB_PATH", tmp_db)

      label, status = init.send(:setup_database)

      expect(label).to eq("sqlite-vec database")
      expect(status).to eq(:installed)
      expect(File.exist?(tmp_db)).to be true

      # Verify v2 schema
      db = Personality::DB.connection(path: tmp_db)
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { |r| r["name"] || r[0] }
      expect(tables).to include("carts", "memories", "schema_version")
    end

    it "reports exists when database already present" do
      FileUtils.touch(tmp_db)
      stub_const("Personality::Init::DB_PATH", tmp_db)

      _, status = init.send(:setup_database)
      expect(status).to eq(:exists)
    end
  end
end
